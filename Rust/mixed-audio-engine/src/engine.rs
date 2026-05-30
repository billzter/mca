use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

pub use crate::generated_shared_memory_abi::{
    MIXED_AUDIO_OUTPUT_CHANNEL_COUNT as MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS,
    MIXED_AUDIO_OUTPUT_SAMPLE_RATE as MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
};

// Release builds intentionally use `panic = "abort"`. These FFI wrappers still use
// `catch_unwind` so debug/test unwind builds fail closed, but release safety relies on
// validating inputs and keeping the implementation's normal error paths panic-free.
const MIXED_AUDIO_ENGINE_MAX_SOURCE_GAIN: f32 = 16.0;
const MIN_DETECTOR_LEVEL: f32 = 0.000_000_001;
const SOFT_LIMIT_THRESHOLD: f32 = 0.95;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct MixedAudioEngineConfig {
    pub source_capacity_frames: u32,
    pub max_source_skew_frames: u32,
    pub max_drift_correction_per_mix: u32,
    pub system_gain: f32,
    pub mic_gain: f32,
    pub mic_compression_enabled: u32,
    pub mic_compression_threshold_db: f32,
    pub mic_compression_ratio: f32,
    pub mic_compression_attack_ms: f32,
    pub mic_compression_release_ms: f32,
    pub mic_compression_makeup_db: f32,
    pub mic_gate_threshold_db: f32,
    pub mic_gate_attenuation_db: f32,
}

impl Default for MixedAudioEngineConfig {
    fn default() -> Self {
        Self {
            source_capacity_frames: 48_000,
            max_source_skew_frames: 2_400,
            max_drift_correction_per_mix: 8,
            system_gain: 1.0,
            mic_gain: 1.0,
            mic_compression_enabled: 0,
            mic_compression_threshold_db: -24.0,
            mic_compression_ratio: 3.0,
            mic_compression_attack_ms: 8.0,
            mic_compression_release_ms: 200.0,
            mic_compression_makeup_db: 6.0,
            mic_gate_threshold_db: -50.0,
            mic_gate_attenuation_db: -24.0,
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
    pub system_queue_overflow_frames: u64,
    pub mic_queue_overflow_frames: u64,
    pub system_queue_frames: u32,
    pub mic_queue_frames: u32,
    pub source_frame_delta: i32,
    pub source_frame_delta_abs: u32,
    pub system_drift_drop_frames: u64,
    pub mic_drift_drop_frames: u64,
    pub callback_error_count: u64,
    pub shared_ring_fill_frames: u32,
    pub shared_ring_fill_error_frames: i32,
    pub shared_ring_fill_error_abs_frames: u32,
    pub shared_ring_overrun_frames: u64,
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

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct SourceLevels {
    pub system_peak: f32,
    pub mic_peak: f32,
}

#[derive(Debug, Clone, Copy)]
struct MicDynamics {
    enabled: bool,
    threshold_db: f32,
    ratio: f32,
    attack_coeff: f32,
    release_coeff: f32,
    threshold_lin: f32,
    makeup_lin: f32,
    gate_threshold_lin: f32,
    gate_attenuation_lin: f32,
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
    mic_dynamics: MicDynamics,
    mic_comp_envelope: f32,
    source_levels: SourceLevels,
}

impl Engine {
    pub fn new(config: MixedAudioEngineConfig) -> EngineResult<Self> {
        if config.source_capacity_frames == 0
            || config.max_source_skew_frames > config.source_capacity_frames
            || config.max_drift_correction_per_mix == 0
            || !Self::levels_are_valid(config.system_gain, config.mic_gain)
            || !Self::compression_config_is_valid(config)
        {
            return Err(EngineError::InvalidConfig);
        }

        let capacity = config.source_capacity_frames as usize;
        let mic_dynamics = Self::mic_dynamics_from_config(config);
        Ok(Self {
            config,
            system: RingBuffer::new(capacity)?,
            mic: RingBuffer::new(capacity)?,
            health: MixedAudioEngineHealth::default(),
            mic_dynamics,
            mic_comp_envelope: 0.0,
            source_levels: SourceLevels::default(),
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
        let mut written = 0u32;
        for frame in 0..frames {
            if self
                .system
                .push(StereoFrame {
                    left: samples[frame * 2],
                    right: samples[frame * 2 + 1],
                })
                .is_err()
            {
                self.health.system_queue_overflow_frames +=
                    (frames as u64).saturating_sub(written as u64);
                self.refresh_queue_health();
                return Ok(written);
            }
            written += 1;
        }
        self.refresh_queue_health();
        Ok(written)
    }

    pub fn push_mic_mono(&mut self, samples: &[f32]) -> EngineResult<u32> {
        let mut written = 0u32;
        for sample in samples {
            if self.mic.push(*sample).is_err() {
                self.health.mic_queue_overflow_frames +=
                    (samples.len() as u64).saturating_sub(written as u64);
                self.refresh_queue_health();
                return Ok(written);
            }
            written += 1;
        }
        self.refresh_queue_health();
        Ok(written)
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

            let system_left = system.left * self.config.system_gain;
            let system_right = system.right * self.config.system_gain;
            let mic = self.process_mic_sample(mic) * self.config.mic_gain;
            self.record_source_levels(system_left, system_right, mic);
            let left = system_left + mic;
            let right = system_right + mic;
            output[frame * 2] = self.limit_sample(left);
            output[frame * 2 + 1] = self.limit_sample(right);
        }

        self.health.frames_mixed += requested_frames as u64;
        self.refresh_queue_health();
        Ok(requested_frames as u32)
    }

    pub fn health(&self) -> MixedAudioEngineHealth {
        self.health
    }

    pub fn take_source_levels(&mut self) -> SourceLevels {
        let levels = self.source_levels;
        self.source_levels = SourceLevels::default();
        levels
    }

    pub fn set_levels(&mut self, system_gain: f32, mic_gain: f32) -> EngineResult<()> {
        if !Self::levels_are_valid(system_gain, mic_gain) {
            return Err(EngineError::InvalidConfig);
        }
        self.config.system_gain = system_gain;
        self.config.mic_gain = mic_gain;
        Ok(())
    }

    pub fn set_mic_compression_enabled(&mut self, enabled: bool) -> EngineResult<()> {
        self.config.mic_compression_enabled = u32::from(enabled);
        if !Self::compression_config_is_valid(self.config) {
            return Err(EngineError::InvalidConfig);
        }
        self.mic_dynamics = Self::mic_dynamics_from_config(self.config);
        self.mic_comp_envelope = 0.0;
        Ok(())
    }

    pub fn reset_sources(&mut self) {
        self.system.clear();
        self.mic.clear();
        self.mic_comp_envelope = 0.0;
        self.refresh_queue_health();
    }

    pub(crate) fn record_callback_error(&mut self) {
        self.health.callback_error_count += 1;
    }

    fn record_source_levels(&mut self, system_left: f32, system_right: f32, mic: f32) {
        let system_peak = system_left.abs().max(system_right.abs());
        if system_peak.is_finite() {
            self.source_levels.system_peak = self.source_levels.system_peak.max(system_peak);
        }
        let mic_peak = mic.abs();
        if mic_peak.is_finite() {
            self.source_levels.mic_peak = self.source_levels.mic_peak.max(mic_peak);
        }
    }

    fn limit_sample(&mut self, sample: f32) -> f32 {
        if !sample.is_finite() {
            self.health.clipped_samples += 1;
            if sample.is_nan() {
                return 0.0;
            }
            return if sample.is_sign_negative() { -1.0 } else { 1.0 };
        }

        let abs_sample = sample.abs();
        if abs_sample > 1.0 {
            self.health.clipped_samples += 1;
        }
        if abs_sample <= SOFT_LIMIT_THRESHOLD {
            return sample;
        }

        let limited = self.soft_limit_positive(abs_sample);
        limited.copysign(sample)
    }

    fn soft_limit_positive(&self, sample: f32) -> f32 {
        let range = 1.0 - SOFT_LIMIT_THRESHOLD;
        let over = sample - SOFT_LIMIT_THRESHOLD;
        SOFT_LIMIT_THRESHOLD + (range * (over / (over + range)))
    }

    fn levels_are_valid(system_gain: f32, mic_gain: f32) -> bool {
        system_gain.is_finite()
            && mic_gain.is_finite()
            && (0.0..=MIXED_AUDIO_ENGINE_MAX_SOURCE_GAIN).contains(&system_gain)
            && (0.0..=MIXED_AUDIO_ENGINE_MAX_SOURCE_GAIN).contains(&mic_gain)
    }

    fn compression_config_is_valid(config: MixedAudioEngineConfig) -> bool {
        (config.mic_compression_enabled == 0 || config.mic_compression_enabled == 1)
            && config.mic_compression_threshold_db.is_finite()
            && config.mic_compression_threshold_db <= 0.0
            && config.mic_compression_ratio.is_finite()
            && config.mic_compression_ratio >= 1.0
            && config.mic_compression_attack_ms.is_finite()
            && config.mic_compression_attack_ms > 0.0
            && config.mic_compression_release_ms.is_finite()
            && config.mic_compression_release_ms > 0.0
            && config.mic_compression_makeup_db.is_finite()
            && (-24.0..=24.0).contains(&config.mic_compression_makeup_db)
            && config.mic_gate_threshold_db.is_finite()
            && config.mic_gate_threshold_db <= 0.0
            && config.mic_gate_attenuation_db.is_finite()
            && (-120.0..=0.0).contains(&config.mic_gate_attenuation_db)
    }

    fn mic_dynamics_from_config(config: MixedAudioEngineConfig) -> MicDynamics {
        MicDynamics {
            enabled: config.mic_compression_enabled != 0,
            threshold_db: config.mic_compression_threshold_db,
            ratio: config.mic_compression_ratio,
            attack_coeff: Self::time_coefficient(config.mic_compression_attack_ms),
            release_coeff: Self::time_coefficient(config.mic_compression_release_ms),
            threshold_lin: Self::db_to_linear(config.mic_compression_threshold_db),
            makeup_lin: Self::db_to_linear(config.mic_compression_makeup_db),
            gate_threshold_lin: Self::db_to_linear(config.mic_gate_threshold_db),
            gate_attenuation_lin: Self::db_to_linear(config.mic_gate_attenuation_db),
        }
    }

    fn time_coefficient(time_ms: f32) -> f32 {
        (-1.0 / (time_ms * 0.001 * MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE as f32)).exp()
    }

    fn db_to_linear(db: f32) -> f32 {
        10.0_f32.powf(db / 20.0)
    }

    fn process_mic_sample(&mut self, sample: f32) -> f32 {
        let dynamics = self.mic_dynamics;
        if !dynamics.enabled {
            return sample;
        }

        let level = sample.abs();
        let coeff = if level > self.mic_comp_envelope {
            dynamics.attack_coeff
        } else {
            dynamics.release_coeff
        };
        self.mic_comp_envelope = (coeff * self.mic_comp_envelope) + ((1.0 - coeff) * level);

        let mut gain = 1.0;
        if self.mic_comp_envelope > dynamics.threshold_lin {
            let envelope_db = 20.0 * self.mic_comp_envelope.max(MIN_DETECTOR_LEVEL).log10();
            let over_db = envelope_db - dynamics.threshold_db;
            let reduce_db = over_db * (1.0 - (1.0 / dynamics.ratio));
            gain *= Self::db_to_linear(-reduce_db);
        }
        if self.mic_comp_envelope < dynamics.gate_threshold_lin {
            gain *= dynamics.gate_attenuation_lin;
        }

        sample * gain * dynamics.makeup_lin
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
/// Updates source gains for subsequent mixes without resetting queued audio or health counters.
///
/// # Safety
///
/// `handle` must be a live engine pointer.
pub unsafe extern "C" fn mixed_audio_engine_set_levels(
    handle: *mut MixedAudioEngineHandle,
    system_gain: f32,
    mic_gain: f32,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let engine = &mut (*handle).engine;
        engine
            .set_levels(system_gain, mic_gain)
            .map(|_| 0)
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
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
