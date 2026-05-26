use crate::shared_memory::{
    now_nanos, PosixSharedMemoryWriter, SharedMemoryAudioWriter, SharedRingWriteStatus,
    MIXED_AUDIO_SHM_NAME,
};
use crate::{
    Engine, EngineError, MixedAudioEngineConfig, MixedAudioEngineHealth,
    MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

// Release builds intentionally use `panic = "abort"`. The C ABI guards below catch
// unwinds in debug/test builds, but production resilience comes from rejecting invalid
// inputs before unsafe access and keeping normal session operations panic-free.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionError {
    Engine(EngineError),
    InvalidConfig,
    SharedMemory,
    WriteRequestTooLarge,
}

impl From<EngineError> for SessionError {
    fn from(error: EngineError) -> Self {
        Self::Engine(error)
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MixedAudioSessionConfig {
    pub engine: MixedAudioEngineConfig,
    pub shared_memory_capacity_frames: u32,
    pub max_write_frames: u32,
}

impl Default for MixedAudioSessionConfig {
    fn default() -> Self {
        Self {
            engine: MixedAudioEngineConfig::default(),
            shared_memory_capacity_frames: 12_000,
            max_write_frames: 2_400,
        }
    }
}

pub struct MixedAudioSession<W: SharedMemoryAudioWriter> {
    engine: Engine,
    writer: W,
    mix_buffer: Vec<f32>,
    frame_index: u64,
    generation: u64,
    shared_ring_status: SharedRingWriteStatus,
}

impl<W: SharedMemoryAudioWriter> MixedAudioSession<W> {
    pub fn new_for_writer(
        engine_config: MixedAudioEngineConfig,
        writer: W,
        max_write_frames: u32,
    ) -> Result<Self, SessionError> {
        if max_write_frames == 0 {
            return Err(SessionError::InvalidConfig);
        }
        let engine = Engine::new(engine_config)?;
        Ok(Self {
            engine,
            writer,
            mix_buffer: vec![
                0.0;
                max_write_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize
            ],
            frame_index: 0,
            generation: 1,
            shared_ring_status: SharedRingWriteStatus::default(),
        })
    }

    pub fn push_system_interleaved_stereo(&mut self, samples: &[f32]) -> Result<u32, SessionError> {
        Ok(self.engine.push_system_interleaved_stereo(samples)?)
    }

    pub fn push_mic_mono(&mut self, samples: &[f32]) -> Result<u32, SessionError> {
        Ok(self.engine.push_mic_mono(samples)?)
    }

    pub fn mix_and_write(
        &mut self,
        requested_frames: u32,
        heartbeat_nanos: u64,
    ) -> Result<u32, SessionError> {
        let required_samples =
            requested_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        if required_samples > self.mix_buffer.len() {
            self.engine.record_callback_error();
            return Err(SessionError::WriteRequestTooLarge);
        }

        self.mix_buffer[..required_samples].fill(0.0);
        let mixed_frames = self
            .engine
            .mix_available(requested_frames, &mut self.mix_buffer[..required_samples])?;
        let mixed_samples = mixed_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        let health = self.engine.health();
        self.shared_ring_status = self.writer.write_audio_frames(
            self.frame_index,
            &self.mix_buffer[..mixed_samples],
            self.generation,
            heartbeat_nanos,
            health,
        );
        self.frame_index += mixed_frames as u64;
        Ok(mixed_frames)
    }

    pub fn mix_and_write_now(&mut self, requested_frames: u32) -> Result<u32, SessionError> {
        self.mix_and_write(requested_frames, now_nanos())
    }

    pub fn health(&self) -> MixedAudioEngineHealth {
        let mut health = self.engine.health();
        health.shared_ring_fill_frames = self.shared_ring_status.fill_frames;
        health.shared_ring_fill_error_frames = self.shared_ring_status.fill_error_frames;
        health.shared_ring_fill_error_abs_frames = self.shared_ring_status.fill_error_abs_frames;
        health.shared_ring_overrun_frames = self.shared_ring_status.overrun_count;
        health
    }

    pub fn reset_sources(&mut self) {
        self.engine.reset_sources();
    }

    pub fn writer(&self) -> &W {
        &self.writer
    }

    pub fn frame_index(&self) -> u64 {
        self.frame_index
    }
}

impl MixedAudioSession<PosixSharedMemoryWriter> {
    pub fn new_posix(config: MixedAudioSessionConfig) -> Result<Self, SessionError> {
        if config.shared_memory_capacity_frames == 0 || config.max_write_frames == 0 {
            return Err(SessionError::InvalidConfig);
        }
        let writer = PosixSharedMemoryWriter::create(
            MIXED_AUDIO_SHM_NAME,
            config.shared_memory_capacity_frames,
        )
        .map_err(|_| SessionError::SharedMemory)?;
        Self::new_for_writer(config.engine, writer, config.max_write_frames)
    }
}

#[repr(C)]
pub struct MixedAudioSessionHandle {
    session: MixedAudioSession<PosixSharedMemoryWriter>,
}

fn result_frames(result: Result<u32, SessionError>) -> u32 {
    result.unwrap_or(0)
}

#[no_mangle]
/// Creates a POSIX shared-memory-backed mixer session for the v1 app-to-HAL stream.
///
/// # Safety
///
/// The returned pointer must later be passed to `mixed_audio_session_destroy` exactly once. The
/// caller must not share the handle across threads without external synchronization.
pub unsafe extern "C" fn mixed_audio_session_create(
    config: MixedAudioSessionConfig,
) -> *mut MixedAudioSessionHandle {
    match catch_unwind(AssertUnwindSafe(|| MixedAudioSession::new_posix(config))) {
        Ok(Ok(session)) => Box::into_raw(Box::new(MixedAudioSessionHandle { session })),
        _ => ptr::null_mut(),
    }
}

#[no_mangle]
/// Destroys a session created by `mixed_audio_session_create`.
///
/// # Safety
///
/// `handle` must be either null or a live pointer returned by `mixed_audio_session_create`.
/// Passing the same non-null handle more than once is undefined behavior.
pub unsafe extern "C" fn mixed_audio_session_destroy(handle: *mut MixedAudioSessionHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(handle));
    }));
}

#[no_mangle]
/// Pushes interleaved stereo system-audio frames into the session.
///
/// # Safety
///
/// `handle` must be a live session pointer. `samples` must point to at least `frames * 2`
/// readable `f32` samples for the duration of the call.
pub unsafe extern "C" fn mixed_audio_session_push_system_interleaved_stereo(
    handle: *mut MixedAudioSessionHandle,
    samples: *const f32,
    frames: u32,
) -> u32 {
    if handle.is_null() || samples.is_null() {
        return 0;
    }
    let sample_count = frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        let samples = slice::from_raw_parts(samples, sample_count);
        result_frames(session.push_system_interleaved_stereo(samples))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Pushes mono microphone frames into the session.
///
/// # Safety
///
/// `handle` must be a live session pointer. `samples` must point to at least `frames` readable
/// `f32` samples for the duration of the call.
pub unsafe extern "C" fn mixed_audio_session_push_mic_mono(
    handle: *mut MixedAudioSessionHandle,
    samples: *const f32,
    frames: u32,
) -> u32 {
    if handle.is_null() || samples.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        let samples = slice::from_raw_parts(samples, frames as usize);
        result_frames(session.push_mic_mono(samples))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Mixes queued source frames and writes the result into `/mca.mix.v1`.
///
/// # Safety
///
/// `handle` must be a live session pointer.
pub unsafe extern "C" fn mixed_audio_session_mix_and_write(
    handle: *mut MixedAudioSessionHandle,
    frames: u32,
) -> u32 {
    if handle.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        result_frames(session.mix_and_write_now(frames))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Clears queued source frames without destroying the session or shared-memory writer.
///
/// # Safety
///
/// `handle` must be either null or a live session pointer.
pub unsafe extern "C" fn mixed_audio_session_reset_sources(
    handle: *mut MixedAudioSessionHandle,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        session.reset_sources();
        0
    }))
    .unwrap_or(-1)
}

#[no_mangle]
/// Copies the current session health snapshot into `out_health`.
///
/// # Safety
///
/// `handle` must be a live session pointer. `out_health` must point to writable storage for one
/// `MixedAudioEngineHealth`.
pub unsafe extern "C" fn mixed_audio_session_get_health(
    handle: *const MixedAudioSessionHandle,
    out_health: *mut MixedAudioEngineHealth,
) -> i32 {
    if handle.is_null() || out_health.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        *out_health = (*handle).session.health();
        0
    }))
    .unwrap_or(-1)
}
