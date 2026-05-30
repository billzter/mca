pub use crate::generated_shared_memory_abi::{
    MIXED_AUDIO_HEARTBEAT_STALE_NANOS, MIXED_AUDIO_OUTPUT_CHANNEL_COUNT,
    MIXED_AUDIO_OUTPUT_SAMPLE_RATE, MIXED_AUDIO_PHASE2_MARKER_LEFT,
    MIXED_AUDIO_PHASE2_MARKER_RIGHT, MIXED_AUDIO_SHM_MAGIC, MIXED_AUDIO_SHM_NAME,
    MIXED_AUDIO_SHM_VERSION, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
};
use crate::{
    MixedAudioEngineHealth, MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
    MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
};
use std::collections::HashSet;
use std::ffi::{c_char, c_int, c_void, CString};
use std::fs::{File, OpenOptions, Permissions};
use std::mem;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

const O_RDWR: c_int = 0x0002;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;
pub const MIXED_AUDIO_SHM_MODE: c_int = 0o666;
const PROT_READ: c_int = 0x01;
const PROT_WRITE: c_int = 0x02;
const MAP_SHARED: c_int = 0x0001;
const MAP_FAILED: *mut c_void = !0usize as *mut c_void;
const LOCK_EX: c_int = 0x02;
const LOCK_NB: c_int = 0x04;
const LOCK_UN: c_int = 0x08;
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 35;

pub trait SharedMemoryAudioWriter {
    fn current_generation(&self) -> u64;
    fn current_write_frame_index(&self) -> u64;
    fn current_heartbeat_nanos(&self) -> u64;
    fn clear_audio_and_heartbeat(&mut self);

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
    fn current_generation(&self) -> u64 {
        self.header().generation.load(Ordering::Acquire)
    }

    fn current_write_frame_index(&self) -> u64 {
        self.header().write_frame_index.load(Ordering::Acquire)
    }

    fn current_heartbeat_nanos(&self) -> u64 {
        self.header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire)
    }

    fn clear_audio_and_heartbeat(&mut self) {
        let frame_start = mem::size_of::<MixedAudioSharedMemoryHeader>();
        let frame_byte_count = self.capacity_frames as usize
            * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize
            * mem::size_of::<f32>();
        self.bytes_mut()[frame_start..frame_start + frame_byte_count].fill(0);
        self.header_mut()
            .producer_heartbeat_nanos
            .store(0, Ordering::Release);
    }

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
            health.system_drift_drop_frames
                + health.mic_drift_drop_frames
                + health.system_queue_overflow_frames
                + health.mic_queue_overflow_frames
                + status.overrun_count,
            Ordering::Relaxed,
        );
        header
            .clipped_frame_count
            .store(health.clipped_samples, Ordering::Relaxed);
        status
    }
}

pub struct PosixSharedMemoryWriter {
    mapping: *mut u8,
    byte_count: usize,
    capacity_frames: u32,
    production_lock: Option<ProductionSharedMemoryLock>,
}

pub(crate) struct ProductionSharedMemoryLock {
    path: String,
    file: File,
}

impl ProductionSharedMemoryLock {
    pub(crate) fn try_acquire_for_name(name: &str) -> Result<Option<Self>, String> {
        let path = production_lock_path_for_name(name);
        let mut held_paths = production_lock_registry()
            .lock()
            .map_err(|_| "production shared memory lock registry poisoned".to_string())?;
        if held_paths.contains(&path) {
            return Ok(None);
        }

        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("open production shared memory lock failed: {error}"))?;
        file.set_permissions(Permissions::from_mode(0o600))
            .map_err(|error| format!("set production shared memory lock mode failed: {error}"))?;
        let status = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if status != 0 {
            let error = errno();
            if error == EWOULDBLOCK || error == EAGAIN {
                return Ok(None);
            }
            return Err(format!(
                "acquire production shared memory lock failed errno={error}"
            ));
        }

        held_paths.insert(path.clone());
        Ok(Some(Self { path, file }))
    }
}

impl Drop for ProductionSharedMemoryLock {
    fn drop(&mut self) {
        unsafe {
            flock(self.file.as_raw_fd(), LOCK_UN);
        }
        if let Ok(mut held_paths) = production_lock_registry().lock() {
            held_paths.remove(&self.path);
        }
    }
}

impl SharedMemoryAudioWriter for PosixSharedMemoryWriter {
    fn current_generation(&self) -> u64 {
        self.header().generation.load(Ordering::Acquire)
    }

    fn current_write_frame_index(&self) -> u64 {
        self.header().write_frame_index.load(Ordering::Acquire)
    }

    fn current_heartbeat_nanos(&self) -> u64 {
        self.header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire)
    }

    fn clear_audio_and_heartbeat(&mut self) {
        self.clear_mapped_audio_and_heartbeat();
    }

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
        Self::create_with_options(name, capacity_frames, None, false)
    }

    pub(crate) fn create_with_options(
        name: &str,
        capacity_frames: u32,
        production_lock: Option<ProductionSharedMemoryLock>,
        unlink_after_map: bool,
    ) -> Result<Self, String> {
        if capacity_frames == 0 {
            return Err("capacity_frames must be nonzero".to_string());
        }

        let name = CString::new(name).map_err(|_| "shared memory name contains NUL".to_string())?;
        let byte_count = total_byte_count(capacity_frames);

        unsafe {
            if let Some(mut writer) = Self::adopt_existing(&name, byte_count, capacity_frames)? {
                writer.production_lock = production_lock;
                if unlink_after_map {
                    Self::unlink_cstring(&name)?;
                }
                return Ok(writer);
            }

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
                mapping: mapping as *mut u8,
                byte_count,
                capacity_frames,
                production_lock,
            };
            writer.initialize_header();
            if unlink_after_map {
                Self::unlink_cstring(&name)?;
            }
            Ok(writer)
        }
    }

    unsafe fn adopt_existing(
        name: &CString,
        byte_count: usize,
        capacity_frames: u32,
    ) -> Result<Option<Self>, String> {
        let existing_fd = shm_open(name.as_ptr(), O_RDWR, 0);
        if existing_fd < 0 {
            return Ok(None);
        }

        let existing_file = File::from_raw_fd(existing_fd);
        let existing_len = existing_file
            .metadata()
            .map_err(|error| format!("fstat existing shared memory failed: {error}"))?
            .len();
        if existing_len < byte_count as u64 {
            drop(existing_file);
            shm_unlink(name.as_ptr());
            return Ok(None);
        }

        let mapping = mmap(
            ptr::null_mut(),
            byte_count,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            existing_file.as_raw_fd(),
            0,
        );
        if mapping == MAP_FAILED {
            return Err(format!("mmap existing failed errno={}", errno()));
        }

        if !header_is_valid(
            mapping as *const MixedAudioSharedMemoryHeader,
            capacity_frames,
        ) {
            munmap(mapping, byte_count);
            drop(existing_file);
            shm_unlink(name.as_ptr());
            return Ok(None);
        }

        Ok(Some(Self {
            mapping: mapping as *mut u8,
            byte_count,
            capacity_frames,
            production_lock: None,
        }))
    }

    pub fn unlink_name(name: &str) -> Result<(), String> {
        let name = CString::new(name).map_err(|_| "shared memory name contains NUL".to_string())?;
        unsafe { Self::unlink_cstring(&name) }
    }

    unsafe fn unlink_cstring(name: &CString) -> Result<(), String> {
        if shm_unlink(name.as_ptr()) == 0 {
            Ok(())
        } else {
            let error = errno();
            if error == 2 {
                Ok(())
            } else {
                Err(format!("shm_unlink failed errno={error}"))
            }
        }
    }

    pub(crate) fn owns_production_lock(&self) -> bool {
        self.production_lock.is_some()
    }

    pub(crate) fn existing_producer_is_live(
        name: &str,
        capacity_frames: u32,
    ) -> Result<bool, String> {
        if capacity_frames == 0 {
            return Ok(false);
        }
        let name = CString::new(name).map_err(|_| "shared memory name contains NUL".to_string())?;
        let byte_count = total_byte_count(capacity_frames);

        unsafe {
            let existing_fd = shm_open(name.as_ptr(), O_RDWR, 0);
            if existing_fd < 0 {
                return Ok(false);
            }

            let existing_file = File::from_raw_fd(existing_fd);
            let existing_len = existing_file
                .metadata()
                .map_err(|error| format!("fstat existing shared memory failed: {error}"))?
                .len();
            if existing_len < byte_count as u64 {
                return Ok(false);
            }

            let mapping = mmap(
                ptr::null_mut(),
                byte_count,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                existing_file.as_raw_fd(),
                0,
            );
            if mapping == MAP_FAILED {
                return Err(format!("mmap existing failed errno={}", errno()));
            }

            let is_live = if header_is_valid(
                mapping as *const MixedAudioSharedMemoryHeader,
                capacity_frames,
            ) {
                let header = &*(mapping as *const MixedAudioSharedMemoryHeader);
                let heartbeat_nanos = header.producer_heartbeat_nanos.load(Ordering::Acquire);
                heartbeat_nanos != 0
                    && now_nanos().saturating_sub(heartbeat_nanos)
                        <= MIXED_AUDIO_HEARTBEAT_STALE_NANOS
            } else {
                false
            };
            munmap(mapping, byte_count);
            Ok(is_live)
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
                // If the producer laps the consumer, an overrun can race a HAL read of this
                // slot. That benign torn frame is preferable to locking the real-time path.
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
                    + health.system_queue_overflow_frames
                    + health.mic_queue_overflow_frames
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

    fn clear_mapped_audio_and_heartbeat(&mut self) {
        unsafe {
            ptr::write_bytes(
                self.frames_mut_ptr(),
                0,
                self.capacity_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize,
            );
            self.header_mut()
                .producer_heartbeat_nanos
                .store(0, Ordering::Release);
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

    fn header(&self) -> &MixedAudioSharedMemoryHeader {
        unsafe { &*(self.mapping as *const MixedAudioSharedMemoryHeader) }
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
        self.clear_mapped_audio_and_heartbeat();
        unsafe { munmap(self.mapping as *mut c_void, self.byte_count) };
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

fn header_is_valid(header: *const MixedAudioSharedMemoryHeader, capacity_frames: u32) -> bool {
    if header.is_null() {
        return false;
    }
    let header = unsafe { &*header };
    header.magic == MIXED_AUDIO_SHM_MAGIC
        && header.version == MIXED_AUDIO_SHM_VERSION
        && header.sample_rate == MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE
        && header.channel_count == MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS
        && header.capacity_frames == capacity_frames
        && header.target_shared_fill_frames == MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES
}

fn production_lock_registry() -> &'static Mutex<HashSet<String>> {
    static REGISTRY: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashSet::new()))
}

fn production_lock_path_for_name(name: &str) -> String {
    let sanitized_name: String = name
        .chars()
        .map(|character| match character {
            '/' | '\0' => '_',
            character => character,
        })
        .collect();
    std::env::temp_dir()
        .join(format!("{sanitized_name}.producer.lock"))
        .to_string_lossy()
        .into_owned()
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
    fn flock(fd: c_int, operation: c_int) -> c_int;
}

fn errno() -> c_int {
    unsafe { *__error() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn production_lock_uses_user_temp_directory_and_owner_only_mode() {
        let name = format!("/mca.mix.test.lock-path.{}", std::process::id());
        let lock = ProductionSharedMemoryLock::try_acquire_for_name(&name)
            .unwrap()
            .unwrap();
        let expected_prefix = std::env::temp_dir();
        assert!(lock
            .path
            .starts_with(expected_prefix.to_string_lossy().as_ref()));

        let mode = std::fs::metadata(&lock.path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
