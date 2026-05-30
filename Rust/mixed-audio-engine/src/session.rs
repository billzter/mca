use crate::engine::SourceLevels;
use crate::shared_memory::{
    now_nanos, PosixSharedMemoryWriter, ProductionSharedMemoryLock, SharedMemoryAudioWriter,
    SharedRingWriteStatus, MIXED_AUDIO_HEARTBEAT_STALE_NANOS, MIXED_AUDIO_SHM_NAME,
};
use crate::{
    Engine, EngineError, MixedAudioEngineConfig, MixedAudioEngineHealth,
    MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::thread;
use std::time::{Duration, Instant};

pub const MIXED_AUDIO_TEST_SHM_NAME_ENV: &str = "MCA_TEST_SHARED_MEMORY_NAME";
const LEGACY_PRODUCER_LIVENESS_POLL_INTERVAL: Duration = Duration::from_millis(25);

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
        let frame_index = writer.current_write_frame_index();
        let generation = if frame_index == 0 && writer.current_heartbeat_nanos() == 0 {
            writer.current_generation().max(1)
        } else {
            writer.current_generation().saturating_add(1).max(1)
        };
        Ok(Self {
            engine,
            writer,
            mix_buffer: vec![
                0.0;
                max_write_frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize
            ],
            frame_index,
            generation,
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

    pub fn clear_shared_memory(&mut self) {
        self.writer.clear_audio_and_heartbeat();
        self.shared_ring_status = SharedRingWriteStatus::default();
    }

    pub fn set_levels(&mut self, system_gain: f32, mic_gain: f32) -> Result<(), SessionError> {
        Ok(self.engine.set_levels(system_gain, mic_gain)?)
    }

    pub fn set_mic_compression_enabled(&mut self, enabled: bool) -> Result<(), SessionError> {
        Ok(self.engine.set_mic_compression_enabled(enabled)?)
    }

    pub fn take_source_levels(&mut self) -> SourceLevels {
        self.engine.take_source_levels()
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
        let resolved_name = resolved_posix_shared_memory_name();
        create_posix_session_for_resolved_name(resolved_name, config).map(|(session, _)| session)
    }

    fn new_posix_writer(
        resolved_name: &ResolvedPosixSharedMemoryName,
        config: MixedAudioSessionConfig,
        production_lock: Option<ProductionSharedMemoryLock>,
    ) -> Result<Self, SessionError> {
        if config.shared_memory_capacity_frames == 0 || config.max_write_frames == 0 {
            return Err(SessionError::InvalidConfig);
        }
        let writer = PosixSharedMemoryWriter::create_with_options(
            resolved_name.name(),
            config.shared_memory_capacity_frames,
            production_lock,
            resolved_name.unlink_after_map(),
        )
        .map_err(|_| SessionError::SharedMemory)?;
        Self::new_for_writer(config.engine, writer, config.max_write_frames)
    }
}

#[repr(C)]
pub struct MixedAudioSessionHandle {
    session: MixedAudioSession<PosixSharedMemoryWriter>,
    shared_memory_name: String,
}

fn result_frames(result: Result<u32, SessionError>) -> u32 {
    result.unwrap_or(0)
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ResolvedPosixSharedMemoryName {
    Production(String),
    ExplicitTest(String),
    AutoXCTest(String),
    DebugFallback(String),
}

impl ResolvedPosixSharedMemoryName {
    fn production(name: String) -> Self {
        Self::Production(name)
    }

    fn name(&self) -> &str {
        match self {
            Self::Production(name)
            | Self::ExplicitTest(name)
            | Self::AutoXCTest(name)
            | Self::DebugFallback(name) => name,
        }
    }

    fn requires_production_lock(&self) -> bool {
        matches!(self, Self::Production(_))
    }

    fn unlink_after_map(&self) -> bool {
        matches!(self, Self::AutoXCTest(_) | Self::DebugFallback(_))
    }
}

enum PosixSessionCreateError {
    Session(SessionError),
    ProductionLockBusy,
}

fn resolved_posix_shared_memory_name() -> ResolvedPosixSharedMemoryName {
    #[cfg(debug_assertions)]
    {
        if let Ok(name) = std::env::var(MIXED_AUDIO_TEST_SHM_NAME_ENV) {
            if is_allowed_test_shared_memory_name(&name) {
                return ResolvedPosixSharedMemoryName::ExplicitTest(name);
            }
        }
        if is_xctest_hosted() {
            return ResolvedPosixSharedMemoryName::AutoXCTest(format!(
                "/mca.mix.test.{}",
                std::process::id()
            ));
        }
    }

    ResolvedPosixSharedMemoryName::production(MIXED_AUDIO_SHM_NAME.to_string())
}

#[cfg(debug_assertions)]
fn is_xctest_hosted() -> bool {
    std::env::var_os("XCTestConfigurationFilePath").is_some()
        || std::env::var_os("XCTestBundlePath").is_some()
}

#[cfg(debug_assertions)]
fn is_allowed_test_shared_memory_name(name: &str) -> bool {
    !name.as_bytes().contains(&0)
        && (name.starts_with("/mca.mix.test.") || name.starts_with("/mca.mix.debug."))
}

fn create_posix_session_with_resolved_name(
    config: MixedAudioSessionConfig,
) -> Result<(MixedAudioSession<PosixSharedMemoryWriter>, String), SessionError> {
    let resolved_name = resolved_posix_shared_memory_name();
    create_posix_session_for_resolved_name(resolved_name, config)
}

fn create_posix_session_for_resolved_name(
    resolved_name: ResolvedPosixSharedMemoryName,
    config: MixedAudioSessionConfig,
) -> Result<(MixedAudioSession<PosixSharedMemoryWriter>, String), SessionError> {
    match try_create_posix_session_for_resolved_name(resolved_name.clone(), config) {
        Ok(session) => Ok(session),
        Err(PosixSessionCreateError::ProductionLockBusy) => {
            create_debug_fallback_posix_session(config)
        }
        Err(PosixSessionCreateError::Session(error)) => Err(error),
    }
}

#[cfg(debug_assertions)]
fn create_debug_fallback_posix_session(
    config: MixedAudioSessionConfig,
) -> Result<(MixedAudioSession<PosixSharedMemoryWriter>, String), SessionError> {
    let resolved_name =
        ResolvedPosixSharedMemoryName::DebugFallback(debug_fallback_shared_memory_name());
    try_create_posix_session_for_resolved_name(resolved_name, config).map_err(|error| match error {
        PosixSessionCreateError::Session(error) => error,
        PosixSessionCreateError::ProductionLockBusy => SessionError::SharedMemory,
    })
}

#[cfg(not(debug_assertions))]
fn create_debug_fallback_posix_session(
    _config: MixedAudioSessionConfig,
) -> Result<(MixedAudioSession<PosixSharedMemoryWriter>, String), SessionError> {
    Err(SessionError::SharedMemory)
}

fn try_create_posix_session_for_resolved_name(
    resolved_name: ResolvedPosixSharedMemoryName,
    config: MixedAudioSessionConfig,
) -> Result<(MixedAudioSession<PosixSharedMemoryWriter>, String), PosixSessionCreateError> {
    if config.shared_memory_capacity_frames == 0 || config.max_write_frames == 0 {
        return Err(PosixSessionCreateError::Session(
            SessionError::InvalidConfig,
        ));
    }
    let production_lock = if resolved_name.requires_production_lock() {
        match ProductionSharedMemoryLock::try_acquire_for_name(resolved_name.name())
            .map_err(|_| PosixSessionCreateError::Session(SessionError::SharedMemory))?
        {
            Some(lock) => Some(lock),
            None => return Err(PosixSessionCreateError::ProductionLockBusy),
        }
    } else {
        None
    };
    if resolved_name.requires_production_lock()
        && wait_for_existing_producer_to_go_stale(
            resolved_name.name(),
            config.shared_memory_capacity_frames,
        )
        .map_err(|_| PosixSessionCreateError::Session(SessionError::SharedMemory))?
    {
        return Err(PosixSessionCreateError::ProductionLockBusy);
    }
    let session = MixedAudioSession::new_posix_writer(&resolved_name, config, production_lock)
        .map_err(PosixSessionCreateError::Session)?;
    let name = resolved_name.name().to_string();
    Ok((session, name))
}

#[cfg(debug_assertions)]
fn debug_fallback_shared_memory_name() -> String {
    format!("/mca.mix.debug.{}", std::process::id())
}

fn wait_for_existing_producer_to_go_stale(
    name: &str,
    capacity_frames: u32,
) -> Result<bool, String> {
    if !PosixSharedMemoryWriter::existing_producer_is_live(name, capacity_frames)? {
        return Ok(false);
    }

    let deadline = Instant::now() + Duration::from_nanos(MIXED_AUDIO_HEARTBEAT_STALE_NANOS);
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        thread::sleep(remaining.min(LEGACY_PRODUCER_LIVENESS_POLL_INTERVAL));
        if !PosixSharedMemoryWriter::existing_producer_is_live(name, capacity_frames)? {
            return Ok(false);
        }
    }
    PosixSharedMemoryWriter::existing_producer_is_live(name, capacity_frames)
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
    match catch_unwind(AssertUnwindSafe(|| {
        create_posix_session_with_resolved_name(config)
    })) {
        Ok(Ok((session, shared_memory_name))) => Box::into_raw(Box::new(MixedAudioSessionHandle {
            session,
            shared_memory_name,
        })),
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
/// Unlinks the default POSIX shared-memory object used by the v1 app-to-HAL stream.
///
/// This is separate from `mixed_audio_session_destroy` so ordinary session stop/restart flows can
/// keep the shared object alive for HAL generation resync, while final app teardown can
/// intentionally discard it.
///
/// # Safety
///
/// This function has no pointer arguments and may be called without a live session handle. Callers
/// must only use it when no process still depends on the default shared-memory object.
pub unsafe extern "C" fn mixed_audio_session_unlink_default_shared_memory() -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        unlink_named_shared_memory_if_production_available(MIXED_AUDIO_SHM_NAME)
            .map(|_| 0)
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

#[no_mangle]
/// Unlinks the POSIX shared-memory object resolved when this session was created.
///
/// # Safety
///
/// `handle` must be either null or a live pointer returned by `mixed_audio_session_create`.
pub unsafe extern "C" fn mixed_audio_session_unlink_session_shared_memory(
    handle: *mut MixedAudioSessionHandle,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let handle = &*handle;
        if handle.shared_memory_name == MIXED_AUDIO_SHM_NAME
            && !handle.session.writer().owns_production_lock()
        {
            return 0;
        }
        PosixSharedMemoryWriter::unlink_name(handle.shared_memory_name.as_str())
            .map(|_| 0)
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

fn unlink_named_shared_memory_if_production_available(name: &str) -> Result<bool, String> {
    match ProductionSharedMemoryLock::try_acquire_for_name(name)? {
        Some(_lock) => {
            PosixSharedMemoryWriter::unlink_name(name)?;
            Ok(true)
        }
        None => Ok(false),
    }
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
/// Clears audio frames and heartbeat in the session shared-memory transport without unlinking it.
///
/// # Safety
///
/// `handle` must be a live session pointer.
pub unsafe extern "C" fn mixed_audio_session_clear_shared_memory(
    handle: *mut MixedAudioSessionHandle,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        session.clear_shared_memory();
        0
    }))
    .unwrap_or(-1)
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
/// Updates source gains for subsequent session mixes without resetting sources or shared memory.
///
/// # Safety
///
/// `handle` must be a live session pointer.
pub unsafe extern "C" fn mixed_audio_session_set_levels(
    handle: *mut MixedAudioSessionHandle,
    system_gain: f32,
    mic_gain: f32,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        session
            .set_levels(system_gain, mic_gain)
            .map(|_| 0)
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

#[no_mangle]
/// Enables or disables the session's configured mic compression preset.
///
/// # Safety
///
/// `handle` must be a live session pointer.
pub unsafe extern "C" fn mixed_audio_session_set_mic_compression_enabled(
    handle: *mut MixedAudioSessionHandle,
    enabled: u32,
) -> i32 {
    if handle.is_null() || (enabled != 0 && enabled != 1) {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let session = &mut (*handle).session;
        session
            .set_mic_compression_enabled(enabled != 0)
            .map(|_| 0)
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

#[no_mangle]
/// Copies peak source levels since the previous read and resets the meter window.
///
/// # Safety
///
/// `handle` must be a live session pointer. Output pointers must point to writable `f32` storage.
pub unsafe extern "C" fn mixed_audio_session_copy_levels(
    handle: *mut MixedAudioSessionHandle,
    out_system_peak: *mut f32,
    out_mic_peak: *mut f32,
) -> i32 {
    if handle.is_null() || out_system_peak.is_null() || out_mic_peak.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let levels = (*handle).session.take_source_levels();
        *out_system_peak = levels.system_peak;
        *out_mic_peak = levels.mic_peak;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared_memory::{
        PosixSharedMemoryWriter, ProductionSharedMemoryLock, SharedMemoryAudioWriter,
    };
    use std::sync::{Mutex, OnceLock};

    fn test_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn session_config() -> MixedAudioSessionConfig {
        MixedAudioSessionConfig {
            shared_memory_capacity_frames: 16,
            max_write_frames: 4,
            ..MixedAudioSessionConfig::default()
        }
    }

    fn write_one_frame(writer: &mut PosixSharedMemoryWriter) {
        let samples = [0.25_f32, -0.25_f32];
        writer.write_frames(
            0,
            &samples,
            1,
            now_nanos(),
            MixedAudioEngineHealth::default(),
        );
        assert_eq!(writer.current_write_frame_index(), 1);
    }

    #[test]
    fn production_resolution_falls_back_to_unlinked_debug_name_when_lock_is_busy() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let pid = std::process::id();
        let production_name = format!("/mca.mix.test.pl.{pid}");
        let debug_name = format!("/mca.mix.debug.{pid}");
        let _ = PosixSharedMemoryWriter::unlink_name(&production_name);
        let _ = PosixSharedMemoryWriter::unlink_name(&debug_name);

        let _owner = ProductionSharedMemoryLock::try_acquire_for_name(&production_name)
            .unwrap()
            .unwrap();
        let resolved = ResolvedPosixSharedMemoryName::production(production_name.clone());
        let (mut session, actual_name) =
            create_posix_session_for_resolved_name(resolved, session_config()).unwrap();

        assert_eq!(actual_name, debug_name);
        assert_eq!(
            session.push_system_interleaved_stereo(&[0.25_f32, -0.25_f32]),
            Ok(1)
        );
        assert_eq!(session.mix_and_write_now(1), Ok(1));

        let recreated = PosixSharedMemoryWriter::create(&debug_name, 16).unwrap();
        assert_eq!(recreated.current_write_frame_index(), 0);
        drop(recreated);
        let _ = PosixSharedMemoryWriter::unlink_name(&production_name);
        let _ = PosixSharedMemoryWriter::unlink_name(&debug_name);
    }

    #[test]
    fn production_resolution_adopts_fresh_heartbeat_when_lock_is_available() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let pid = std::process::id();
        let production_name = format!("/mca.mix.test.ph.{pid}");
        let debug_name = format!("/mca.mix.debug.{pid}");
        let _ = PosixSharedMemoryWriter::unlink_name(&production_name);
        let _ = PosixSharedMemoryWriter::unlink_name(&debug_name);

        let mut live_writer = PosixSharedMemoryWriter::create(&production_name, 16).unwrap();
        write_one_frame(&mut live_writer);

        let resolved = ResolvedPosixSharedMemoryName::production(production_name.clone());
        let (mut session, actual_name) =
            create_posix_session_for_resolved_name(resolved, session_config()).unwrap();

        assert_eq!(actual_name, production_name);
        assert_eq!(
            session.push_system_interleaved_stereo(&[0.25_f32, -0.25_f32]),
            Ok(1)
        );
        assert_eq!(session.mix_and_write_now(1), Ok(1));

        let recreated = PosixSharedMemoryWriter::create(&production_name, 16).unwrap();
        assert_eq!(recreated.current_write_frame_index(), 2);
        drop(recreated);
        drop(live_writer);
        let _ = PosixSharedMemoryWriter::unlink_name(&production_name);
        let _ = PosixSharedMemoryWriter::unlink_name(&debug_name);
    }

    #[test]
    fn production_unlink_skips_when_lock_is_busy() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let name = format!("/mca.mix.test.ub.{}", std::process::id());
        let _ = PosixSharedMemoryWriter::unlink_name(&name);

        let _owner = ProductionSharedMemoryLock::try_acquire_for_name(&name)
            .unwrap()
            .unwrap();
        let mut writer = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        write_one_frame(&mut writer);
        assert!(!unlink_named_shared_memory_if_production_available(&name).unwrap());

        drop(writer);
        let recreated = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        assert_eq!(recreated.current_write_frame_index(), 1);
        drop(recreated);
        let _ = PosixSharedMemoryWriter::unlink_name(&name);
    }

    #[test]
    fn production_unlink_removes_when_lock_is_available() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let name = format!("/mca.mix.test.ua.{}", std::process::id());
        let _ = PosixSharedMemoryWriter::unlink_name(&name);

        let mut writer = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        write_one_frame(&mut writer);
        drop(writer);

        assert!(unlink_named_shared_memory_if_production_available(&name).unwrap());
        let recreated = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        assert_eq!(recreated.current_write_frame_index(), 0);
        drop(recreated);
        let _ = PosixSharedMemoryWriter::unlink_name(&name);
    }
}
