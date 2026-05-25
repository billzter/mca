use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

pub const MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE: u32 = 48_000;
pub const MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MixedAudioEngineConfig {
    pub source_capacity_frames: u32,
    pub max_source_skew_frames: u32,
    pub max_drift_correction_per_mix: u32,
    pub system_gain: f32,
    pub mic_gain: f32,
}

impl Default for MixedAudioEngineConfig {
    fn default() -> Self {
        Self {
            source_capacity_frames: 48_000,
            max_source_skew_frames: 2_400,
            max_drift_correction_per_mix: 8,
            system_gain: 1.0,
            mic_gain: 1.0,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MixedAudioEngineHealth {
    pub frames_mixed: u64,
    pub system_underrun_frames: u64,
    pub mic_underrun_frames: u64,
    pub clipped_samples: u64,
    pub system_queue_frames: u32,
    pub mic_queue_frames: u32,
    pub source_frame_delta: i32,
    pub source_frame_delta_abs: u32,
    pub system_drift_drop_frames: u64,
    pub mic_drift_drop_frames: u64,
    pub callback_error_count: u64,
}

#[repr(C)]
pub struct MixedAudioEngineHandle {
    engine: Engine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineError {
    InvalidConfig,
    OutputBufferTooSmall,
    SourceBufferShape,
    QueueOverflow,
}

type EngineResult<T> = Result<T, EngineError>;

#[derive(Debug, Clone, Copy, Default)]
struct StereoFrame {
    left: f32,
    right: f32,
}

#[derive(Debug)]
struct RingBuffer<T: Copy + Default> {
    frames: Vec<T>,
    capacity: usize,
    read_index: usize,
    len: usize,
}

impl<T: Copy + Default> RingBuffer<T> {
    fn new(capacity: usize) -> EngineResult<Self> {
        if capacity == 0 {
            return Err(EngineError::InvalidConfig);
        }
        Ok(Self {
            frames: vec![T::default(); capacity],
            capacity,
            read_index: 0,
            len: 0,
        })
    }

    fn len(&self) -> usize {
        self.len
    }

    fn push(&mut self, frame: T) -> EngineResult<()> {
        if self.len == self.capacity {
            return Err(EngineError::QueueOverflow);
        }
        let write_index = (self.read_index + self.len) % self.capacity;
        self.frames[write_index] = frame;
        self.len += 1;
        Ok(())
    }

    fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        let frame = self.frames[self.read_index];
        self.read_index = (self.read_index + 1) % self.capacity;
        self.len -= 1;
        Some(frame)
    }

    fn clear(&mut self) {
        self.read_index = 0;
        self.len = 0;
    }
}

#[derive(Debug)]
pub struct Engine {
    config: MixedAudioEngineConfig,
    system: RingBuffer<StereoFrame>,
    mic: RingBuffer<f32>,
    health: MixedAudioEngineHealth,
}

impl Engine {
    pub fn new(config: MixedAudioEngineConfig) -> EngineResult<Self> {
        if config.source_capacity_frames == 0
            || config.max_source_skew_frames > config.source_capacity_frames
            || config.max_drift_correction_per_mix == 0
            || !config.system_gain.is_finite()
            || !config.mic_gain.is_finite()
        {
            return Err(EngineError::InvalidConfig);
        }

        let capacity = config.source_capacity_frames as usize;
        Ok(Self {
            config,
            system: RingBuffer::new(capacity)?,
            mic: RingBuffer::new(capacity)?,
            health: MixedAudioEngineHealth::default(),
        })
    }

    pub fn push_system_interleaved_stereo(&mut self, samples: &[f32]) -> EngineResult<u32> {
        if !samples
            .len()
            .is_multiple_of(MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize)
        {
            self.health.callback_error_count += 1;
            return Err(EngineError::SourceBufferShape);
        }

        let frames = samples.len() / MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        for frame in 0..frames {
            self.system.push(StereoFrame {
                left: samples[frame * 2],
                right: samples[frame * 2 + 1],
            })?;
        }
        self.refresh_queue_health();
        Ok(frames as u32)
    }

    pub fn push_mic_mono(&mut self, samples: &[f32]) -> EngineResult<u32> {
        for sample in samples {
            self.mic.push(*sample)?;
        }
        self.refresh_queue_health();
        Ok(samples.len() as u32)
    }

    pub fn mix_available(
        &mut self,
        requested_frames: u32,
        output: &mut [f32],
    ) -> EngineResult<u32> {
        let requested_frames = requested_frames as usize;
        let required_samples = requested_frames * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
        if output.len() < required_samples {
            self.health.callback_error_count += 1;
            return Err(EngineError::OutputBufferTooSmall);
        }

        self.bound_source_skew();

        for frame in 0..requested_frames {
            let system = self.system.pop();
            let mic = self.mic.pop();

            let system = match system {
                Some(frame) => frame,
                None => {
                    self.health.system_underrun_frames += 1;
                    StereoFrame::default()
                }
            };
            let mic = match mic {
                Some(sample) => sample,
                None => {
                    self.health.mic_underrun_frames += 1;
                    0.0
                }
            };

            let left = (system.left * self.config.system_gain) + (mic * self.config.mic_gain);
            let right = (system.right * self.config.system_gain) + (mic * self.config.mic_gain);
            output[frame * 2] = self.clamp_sample(left);
            output[frame * 2 + 1] = self.clamp_sample(right);
        }

        self.health.frames_mixed += requested_frames as u64;
        self.refresh_queue_health();
        Ok(requested_frames as u32)
    }

    pub fn health(&self) -> MixedAudioEngineHealth {
        self.health
    }

    pub fn reset_sources(&mut self) {
        self.system.clear();
        self.mic.clear();
        self.refresh_queue_health();
    }

    pub(crate) fn record_callback_error(&mut self) {
        self.health.callback_error_count += 1;
    }

    fn clamp_sample(&mut self, sample: f32) -> f32 {
        if sample > 1.0 {
            self.health.clipped_samples += 1;
            1.0
        } else if sample < -1.0 {
            self.health.clipped_samples += 1;
            -1.0
        } else {
            sample
        }
    }

    fn bound_source_skew(&mut self) {
        let max_skew = self.config.max_source_skew_frames as usize;
        let target_lead = max_skew / 2;
        let mut remaining_corrections = self.config.max_drift_correction_per_mix as usize;
        while remaining_corrections > 0 && self.leading_source_exceeds_target(true, target_lead) {
            let _ = self.system.pop();
            self.health.system_drift_drop_frames += 1;
            remaining_corrections -= 1;
        }
        while remaining_corrections > 0 && self.leading_source_exceeds_target(false, target_lead) {
            let _ = self.mic.pop();
            self.health.mic_drift_drop_frames += 1;
            remaining_corrections -= 1;
        }
        self.refresh_queue_health();
    }

    fn leading_source_exceeds_target(&self, system_leads: bool, target_lead: usize) -> bool {
        if system_leads {
            self.system.len() > self.mic.len().saturating_add(target_lead)
        } else {
            self.mic.len() > self.system.len().saturating_add(target_lead)
        }
    }

    fn refresh_queue_health(&mut self) {
        self.health.system_queue_frames = self.system.len() as u32;
        self.health.mic_queue_frames = self.mic.len() as u32;
        let delta = self.system.len() as i64 - self.mic.len() as i64;
        self.health.source_frame_delta = delta as i32;
        self.health.source_frame_delta_abs = delta.unsigned_abs() as u32;
    }
}

fn result_frames(result: EngineResult<u32>) -> u32 {
    result.unwrap_or(0)
}

#[no_mangle]
/// Creates a new mixer engine handle.
///
/// # Safety
///
/// The returned pointer must later be passed to `mixed_audio_engine_destroy` exactly once. The
/// caller must not share the handle across threads without external synchronization.
pub unsafe extern "C" fn mixed_audio_engine_create(
    config: MixedAudioEngineConfig,
) -> *mut MixedAudioEngineHandle {
    match catch_unwind(AssertUnwindSafe(|| Engine::new(config))) {
        Ok(Ok(engine)) => Box::into_raw(Box::new(MixedAudioEngineHandle { engine })),
        _ => ptr::null_mut(),
    }
}

#[no_mangle]
/// Destroys a mixer engine handle created by `mixed_audio_engine_create`.
///
/// # Safety
///
/// `handle` must be either null or a live pointer returned by `mixed_audio_engine_create`. Passing
/// the same non-null handle more than once is undefined behavior.
pub unsafe extern "C" fn mixed_audio_engine_destroy(handle: *mut MixedAudioEngineHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        drop(Box::from_raw(handle));
    }));
}

#[no_mangle]
/// Pushes interleaved stereo system-audio frames into the engine.
///
/// # Safety
///
/// `handle` must be a live engine pointer. `samples` must point to at least `frames * 2`
/// readable `f32` samples for the duration of the call.
pub unsafe extern "C" fn mixed_audio_engine_push_system_interleaved_stereo(
    handle: *mut MixedAudioEngineHandle,
    samples: *const f32,
    frames: u32,
) -> u32 {
    if handle.is_null() || samples.is_null() {
        return 0;
    }
    let sample_count = frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &mut (*handle).engine;
        let samples = slice::from_raw_parts(samples, sample_count);
        result_frames(engine.push_system_interleaved_stereo(samples))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Pushes mono microphone frames into the engine.
///
/// # Safety
///
/// `handle` must be a live engine pointer. `samples` must point to at least `frames` readable
/// `f32` samples for the duration of the call.
pub unsafe extern "C" fn mixed_audio_engine_push_mic_mono(
    handle: *mut MixedAudioEngineHandle,
    samples: *const f32,
    frames: u32,
) -> u32 {
    if handle.is_null() || samples.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &mut (*handle).engine;
        let samples = slice::from_raw_parts(samples, frames as usize);
        result_frames(engine.push_mic_mono(samples))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Mixes available frames into an interleaved stereo output buffer.
///
/// # Safety
///
/// `handle` must be a live engine pointer. `output` must point to at least `frames * 2` writable
/// `f32` samples for the duration of the call.
pub unsafe extern "C" fn mixed_audio_engine_mix_available(
    handle: *mut MixedAudioEngineHandle,
    output: *mut f32,
    frames: u32,
) -> u32 {
    if handle.is_null() || output.is_null() {
        return 0;
    }
    let sample_count = frames as usize * MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS as usize;
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &mut (*handle).engine;
        let output = slice::from_raw_parts_mut(output, sample_count);
        result_frames(engine.mix_available(frames, output))
    }))
    .unwrap_or(0)
}

#[no_mangle]
/// Copies the current engine health snapshot into `out_health`.
///
/// # Safety
///
/// `handle` must be a live engine pointer. `out_health` must point to writable storage for one
/// `MixedAudioEngineHealth`.
pub unsafe extern "C" fn mixed_audio_engine_get_health(
    handle: *const MixedAudioEngineHandle,
    out_health: *mut MixedAudioEngineHealth,
) -> i32 {
    if handle.is_null() || out_health.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        *out_health = (*handle).engine.health();
        0
    }))
    .unwrap_or(-1)
}
