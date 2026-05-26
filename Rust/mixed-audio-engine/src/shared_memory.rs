pub use crate::generated_shared_memory_abi::{
    MIXED_AUDIO_PHASE2_MARKER_LEFT, MIXED_AUDIO_PHASE2_MARKER_RIGHT, MIXED_AUDIO_SHM_MAGIC,
    MIXED_AUDIO_SHM_NAME, MIXED_AUDIO_SHM_VERSION, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
};
use crate::{
    MixedAudioEngineHealth, MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
    MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
};
use std::ffi::{c_char, c_int, c_void, CString};
use std::mem;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

const O_RDWR: c_int = 0x0002;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;
pub const MIXED_AUDIO_SHM_MODE: c_int = 0o666;
const PROT_READ: c_int = 0x01;
const PROT_WRITE: c_int = 0x02;
const MAP_SHARED: c_int = 0x0001;
const MAP_FAILED: *mut c_void = !0usize as *mut c_void;

pub trait SharedMemoryAudioWriter {
    fn write_audio_frames(
        &mut self,
        first_frame_index: u64,
        samples: &[f32],
        generation: u64,
        heartbeat_nanos: u64,
        health: MixedAudioEngineHealth,
    ) -> SharedRingWriteStatus;
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SharedRingWriteStatus {
    pub fill_frames: u32,
    pub fill_error_frames: i32,
    pub fill_error_abs_frames: u32,
    pub overrun_frames: u64,
    pub overrun_count: u64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SharedRingFillErrorStats {
    pub sample_count: u64,
    pub min_frames: i32,
    pub max_frames: i32,
    pub max_abs_frames: u32,
    pub mean_frames: f64,
    pub p95_abs_frames: u32,
    pub p99_abs_frames: u32,
}

impl SharedRingFillErrorStats {
    pub fn from_errors(fill_error_frames: &[i32]) -> Option<Self> {
        if fill_error_frames.is_empty() {
            return None;
        }

        let mut min_frames = i32::MAX;
        let mut max_frames = i32::MIN;
        let mut sum = 0_i128;
        let mut abs_errors = Vec::with_capacity(fill_error_frames.len());
        for error in fill_error_frames {
            min_frames = min_frames.min(*error);
            max_frames = max_frames.max(*error);
            sum += i128::from(*error);
            abs_errors.push(error.unsigned_abs());
        }
        abs_errors.sort_unstable();

        let sample_count = fill_error_frames.len() as u64;
        Some(Self {
            sample_count,
            min_frames,
            max_frames,
            max_abs_frames: *abs_errors.last().unwrap_or(&0),
            mean_frames: sum as f64 / sample_count as f64,
            p95_abs_frames: percentile_nearest_rank(&abs_errors, 95),
            p99_abs_frames: percentile_nearest_rank(&abs_errors, 99),
        })
    }
}

#[repr(C)]
#[derive(Debug, Default)]
pub struct MixedAudioSharedMemoryHeader {
    pub magic: u32,
    pub version: u32,
    pub sample_rate: u32,
    pub channel_count: u32,
    pub capacity_frames: u32,
    pub target_shared_fill_frames: u32,
    pub write_frame_index: AtomicU64,
    pub read_frame_index: AtomicU64,
    pub generation: AtomicU64,
    pub producer_heartbeat_nanos: AtomicU64,
    pub underrun_count: AtomicU64,
    pub overrun_count: AtomicU64,
    pub dropped_frame_count: AtomicU64,
    pub clipped_frame_count: AtomicU64,
}

pub struct SharedMemoryLayout {
    storage: Vec<u64>,
    byte_count: usize,
    capacity_frames: u32,
}

impl SharedMemoryLayout {
    pub fn new_for_test(capacity_frames: u32) -> Self {
        let byte_count = total_byte_count(capacity_frames);
        let word_count = byte_count.div_ceil(mem::size_of::<u64>());
        let mut layout = Self {
            storage: vec![0; word_count],
            byte_count,
            capacity_frames,
        };
        layout.initialize_header();
        layout
    }

    pub fn header(&self) -> &MixedAudioSharedMemoryHeader {
        unsafe { &*(self.bytes_ptr() as *const MixedAudioSharedMemoryHeader) }
    }

    pub fn frames(&self) -> &[f32] {
        let sample_count =
            self.capacity_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        unsafe {
            std::slice::from_raw_parts(
                self.bytes_ptr()
                    .add(mem::size_of::<MixedAudioSharedMemoryHeader>())
                    as *const f32,
                sample_count,
            )
        }
    }

    pub fn write_frames(
        &mut self,
        first_frame_index: u64,
        samples: &[f32],
        generation: u64,
        heartbeat_nanos: u64,
    ) -> SharedRingWriteStatus {
        let frame_count = samples.len() / MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        let capacity_frames = self.capacity_frames as u64;
        let frame_start = mem::size_of::<MixedAudioSharedMemoryHeader>();
        for frame in 0..frame_count {
            let slot = ((first_frame_index + frame as u64) % capacity_frames) as usize;
            let dst_sample = frame_start
                + slot * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize * mem::size_of::<f32>();
            let src_sample = frame * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
            let dst = &mut self.bytes_mut()[dst_sample..dst_sample + 2 * mem::size_of::<f32>()];
            dst[..4].copy_from_slice(&samples[src_sample].to_ne_bytes());
            dst[4..8].copy_from_slice(&samples[src_sample + 1].to_ne_bytes());
        }

        let header = self.header_mut();
        let write_frame_index = first_frame_index + frame_count as u64;
        let status = shared_ring_write_status(header, capacity_frames, write_frame_index);
        header.generation.store(generation, Ordering::Release);
        header
            .producer_heartbeat_nanos
            .store(heartbeat_nanos, Ordering::Release);
        header
            .write_frame_index
            .store(write_frame_index, Ordering::Release);
        status
    }

    pub fn increment_clipped_frames(&mut self, clipped_frames: u64) {
        self.header_mut()
            .clipped_frame_count
            .fetch_add(clipped_frames, Ordering::Relaxed);
    }

    fn initialize_header(&mut self) {
        let capacity_frames = self.capacity_frames;
        let header = self.header_mut();
        *header = MixedAudioSharedMemoryHeader {
            magic: MIXED_AUDIO_SHM_MAGIC,
            version: MIXED_AUDIO_SHM_VERSION,
            sample_rate: MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
            channel_count: MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
            capacity_frames,
            target_shared_fill_frames: MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
            generation: AtomicU64::new(1),
            ..MixedAudioSharedMemoryHeader::default()
        };
    }

    fn header_mut(&mut self) -> &mut MixedAudioSharedMemoryHeader {
        unsafe { &mut *(self.bytes_mut_ptr() as *mut MixedAudioSharedMemoryHeader) }
    }

    fn bytes_ptr(&self) -> *const u8 {
        self.storage.as_ptr() as *const u8
    }

    fn bytes_mut_ptr(&mut self) -> *mut u8 {
        self.storage.as_mut_ptr() as *mut u8
    }

    fn bytes_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.bytes_mut_ptr(), self.byte_count) }
    }
}

impl SharedMemoryAudioWriter for SharedMemoryLayout {
    fn write_audio_frames(
        &mut self,
        first_frame_index: u64,
        samples: &[f32],
        generation: u64,
        heartbeat_nanos: u64,
        health: MixedAudioEngineHealth,
    ) -> SharedRingWriteStatus {
        let status = self.write_frames(first_frame_index, samples, generation, heartbeat_nanos);
        let header = self.header_mut();
        header.underrun_count.store(
            health.system_underrun_frames + health.mic_underrun_frames,
            Ordering::Relaxed,
        );
        header.dropped_frame_count.store(
            health.system_drift_drop_frames + health.mic_drift_drop_frames + status.overrun_count,
            Ordering::Relaxed,
        );
        header
            .clipped_frame_count
            .store(health.clipped_samples, Ordering::Relaxed);
        status
    }
}

pub struct PosixSharedMemoryWriter {
    name: CString,
    mapping: *mut u8,
    byte_count: usize,
    capacity_frames: u32,
}

impl SharedMemoryAudioWriter for PosixSharedMemoryWriter {
    fn write_audio_frames(
        &mut self,
        first_frame_index: u64,
        samples: &[f32],
        generation: u64,
        heartbeat_nanos: u64,
        health: MixedAudioEngineHealth,
    ) -> SharedRingWriteStatus {
        self.write_frames(
            first_frame_index,
            samples,
            generation,
            heartbeat_nanos,
            health,
        )
    }
}

impl PosixSharedMemoryWriter {
    pub fn create(name: &str, capacity_frames: u32) -> Result<Self, String> {
        if capacity_frames == 0 {
            return Err("capacity_frames must be nonzero".to_string());
        }

        let name = CString::new(name).map_err(|_| "shared memory name contains NUL".to_string())?;
        let byte_count = total_byte_count(capacity_frames);

        unsafe {
            shm_unlink(name.as_ptr());
            let previous_umask = umask(0);
            let fd = shm_open(
                name.as_ptr(),
                O_CREAT | O_EXCL | O_RDWR,
                MIXED_AUDIO_SHM_MODE,
            );
            umask(previous_umask);
            if fd < 0 {
                return Err(format!("shm_open failed errno={}", errno()));
            }
            if ftruncate(fd, byte_count as i64) != 0 {
                let error = errno();
                close(fd);
                shm_unlink(name.as_ptr());
                return Err(format!("ftruncate failed errno={error}"));
            }
            let mapping = mmap(
                ptr::null_mut(),
                byte_count,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                fd,
                0,
            );
            close(fd);
            if mapping == MAP_FAILED {
                let error = errno();
                shm_unlink(name.as_ptr());
                return Err(format!("mmap failed errno={error}"));
            }
            ptr::write_bytes(mapping, 0, byte_count);

            let mut writer = Self {
                name,
                mapping: mapping as *mut u8,
                byte_count,
                capacity_frames,
            };
            writer.initialize_header();
            Ok(writer)
        }
    }

    pub fn write_frames(
        &mut self,
        first_frame_index: u64,
        samples: &[f32],
        generation: u64,
        heartbeat_nanos: u64,
        health: MixedAudioEngineHealth,
    ) -> SharedRingWriteStatus {
        let frame_count = samples.len() / MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        unsafe {
            let frames = self.frames_mut_ptr();
            for frame in 0..frame_count {
                let slot =
                    ((first_frame_index + frame as u64) % self.capacity_frames as u64) as usize;
                let dst = frames.add(slot * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize);
                let src = frame * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
                *dst = samples[src];
                *dst.add(1) = samples[src + 1];
            }

            let capacity_frames = self.capacity_frames as u64;
            let header = self.header_mut();
            let write_frame_index = first_frame_index + frame_count as u64;
            let status = shared_ring_write_status(header, capacity_frames, write_frame_index);
            header.generation.store(generation, Ordering::Release);
            header
                .producer_heartbeat_nanos
                .store(heartbeat_nanos, Ordering::Release);
            header.underrun_count.store(
                health.system_underrun_frames + health.mic_underrun_frames,
                Ordering::Relaxed,
            );
            header.dropped_frame_count.store(
                health.system_drift_drop_frames
                    + health.mic_drift_drop_frames
                    + status.overrun_count,
                Ordering::Relaxed,
            );
            header
                .clipped_frame_count
                .store(health.clipped_samples, Ordering::Relaxed);
            header
                .write_frame_index
                .store(write_frame_index, Ordering::Release);
            status
        }
    }

    fn initialize_header(&mut self) {
        let capacity_frames = self.capacity_frames;
        *self.header_mut() = MixedAudioSharedMemoryHeader {
            magic: MIXED_AUDIO_SHM_MAGIC,
            version: MIXED_AUDIO_SHM_VERSION,
            sample_rate: MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
            channel_count: MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
            capacity_frames,
            target_shared_fill_frames: MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
            generation: AtomicU64::new(1),
            ..MixedAudioSharedMemoryHeader::default()
        };
    }

    fn header_mut(&mut self) -> &mut MixedAudioSharedMemoryHeader {
        unsafe { &mut *(self.mapping as *mut MixedAudioSharedMemoryHeader) }
    }

    fn frames_mut_ptr(&mut self) -> *mut f32 {
        unsafe {
            self.mapping
                .add(mem::size_of::<MixedAudioSharedMemoryHeader>()) as *mut f32
        }
    }
}

impl Drop for PosixSharedMemoryWriter {
    fn drop(&mut self) {
        unsafe {
            munmap(self.mapping as *mut c_void, self.byte_count);
            shm_unlink(self.name.as_ptr());
        }
    }
}

pub fn total_byte_count(capacity_frames: u32) -> usize {
    mem::size_of::<MixedAudioSharedMemoryHeader>()
        + capacity_frames as usize
            * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize
            * mem::size_of::<f32>()
}

fn shared_ring_write_status(
    header: &MixedAudioSharedMemoryHeader,
    capacity_frames: u64,
    write_frame_index: u64,
) -> SharedRingWriteStatus {
    let read_frame_index = header.read_frame_index.load(Ordering::Acquire);
    let previous_write_frame_index = header.write_frame_index.load(Ordering::Acquire);
    let previous_fill_frames = previous_write_frame_index.saturating_sub(read_frame_index);
    let previous_overrun_frames = previous_fill_frames.saturating_sub(capacity_frames);
    let unread_backlog_frames = write_frame_index.saturating_sub(read_frame_index);
    let accumulated_overrun_frames = unread_backlog_frames.saturating_sub(capacity_frames);
    let overrun_frames = accumulated_overrun_frames.saturating_sub(previous_overrun_frames);
    let overrun_count = if overrun_frames > 0 {
        header
            .dropped_frame_count
            .fetch_add(overrun_frames, Ordering::Relaxed);
        header
            .overrun_count
            .fetch_add(overrun_frames, Ordering::Relaxed)
            .saturating_add(overrun_frames)
    } else {
        header.overrun_count.load(Ordering::Relaxed)
    };
    let fill_frames = unread_backlog_frames.min(capacity_frames);
    let fill_error = signed_frame_delta(fill_frames, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES as u64);

    SharedRingWriteStatus {
        fill_frames: u32::try_from(fill_frames).unwrap_or(u32::MAX),
        fill_error_frames: fill_error,
        fill_error_abs_frames: fill_error.unsigned_abs(),
        overrun_frames,
        overrun_count,
    }
}

fn signed_frame_delta(actual_frames: u64, target_frames: u64) -> i32 {
    let delta = i128::from(actual_frames) - i128::from(target_frames);
    if delta > i128::from(i32::MAX) {
        i32::MAX
    } else if delta < i128::from(i32::MIN) {
        i32::MIN
    } else {
        delta as i32
    }
}

fn percentile_nearest_rank(sorted_values: &[u32], percentile: usize) -> u32 {
    if sorted_values.is_empty() {
        return 0;
    }
    let rank = sorted_values
        .len()
        .saturating_mul(percentile)
        .div_ceil(100)
        .max(1);
    sorted_values[rank.saturating_sub(1).min(sorted_values.len() - 1)]
}

pub fn now_nanos() -> u64 {
    unsafe {
        let mut timebase = MachTimebaseInfo { numer: 0, denom: 0 };
        if mach_timebase_info(&mut timebase) != 0 || timebase.denom == 0 {
            return 0;
        }
        let host_time = mach_absolute_time();
        host_time
            .saturating_mul(timebase.numer as u64)
            .saturating_div(timebase.denom as u64)
    }
}

static SHOULD_STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_signal(_signal: c_int) {
    SHOULD_STOP.store(true, Ordering::SeqCst);
}

pub fn install_signal_handlers() {
    unsafe {
        signal(2, handle_signal);
        signal(15, handle_signal);
    }
}

pub fn should_stop() -> bool {
    SHOULD_STOP.load(Ordering::SeqCst)
}

#[repr(C)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

extern "C" {
    fn shm_open(name: *const c_char, oflag: c_int, ...) -> c_int;
    fn shm_unlink(name: *const c_char) -> c_int;
    fn ftruncate(fd: c_int, length: i64) -> c_int;
    fn mmap(
        addr: *mut c_void,
        len: usize,
        prot: c_int,
        flags: c_int,
        fd: c_int,
        offset: i64,
    ) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn umask(mask: u16) -> u16;
    fn __error() -> *mut c_int;
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> c_int;
    fn signal(sig: c_int, handler: extern "C" fn(c_int)) -> extern "C" fn(c_int);
}

fn errno() -> c_int {
    unsafe { *__error() }
}
