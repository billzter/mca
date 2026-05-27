use mixed_audio_engine::{Engine, MixedAudioEngineConfig, MixedAudioEngineHealth};

const TICK_FRAMES: usize = 64;

#[derive(Clone, Copy)]
enum FramePattern {
    Constant(usize),
    Cycle(&'static [usize]),
    PauseThenRecover {
        normal: usize,
        pause_start_tick: usize,
        pause_ticks: usize,
        recovery_frames: usize,
        recovery_ticks: usize,
    },
}

impl FramePattern {
    fn frames_at(self, tick: usize) -> usize {
        match self {
            Self::Constant(frames) => frames,
            Self::Cycle(frames) => frames[tick % frames.len()],
            Self::PauseThenRecover {
                normal,
                pause_start_tick,
                pause_ticks,
                recovery_frames,
                recovery_ticks,
            } => {
                let pause_end = pause_start_tick + pause_ticks;
                let recovery_end = pause_end + recovery_ticks;
                if (pause_start_tick..pause_end).contains(&tick) {
                    0
                } else if (pause_end..recovery_end).contains(&tick) {
                    recovery_frames
                } else {
                    normal
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
enum CounterExpectation {
    Eq(u64),
    Gt(u64),
}

#[derive(Clone, Copy)]
struct ExpectedHealth {
    max_source_delta_abs: u32,
    system_underrun_frames: CounterExpectation,
    mic_underrun_frames: CounterExpectation,
    clipped_samples: CounterExpectation,
    system_drift_drop_frames: CounterExpectation,
    mic_drift_drop_frames: CounterExpectation,
    callback_error_count: CounterExpectation,
}

struct StressCase {
    name: &'static str,
    ticks: usize,
    config: MixedAudioEngineConfig,
    system_pattern: FramePattern,
    mic_pattern: FramePattern,
    initial_system_frames: usize,
    initial_mic_frames: usize,
    system_frame: [f32; 2],
    mic_sample: f32,
    expected: ExpectedHealth,
}

fn stress_config(
    max_source_skew_frames: u32,
    max_drift_correction_per_mix: u32,
) -> MixedAudioEngineConfig {
    MixedAudioEngineConfig {
        source_capacity_frames: 4_096,
        max_source_skew_frames,
        max_drift_correction_per_mix,
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

fn steady_case(
    name: &'static str,
    system_pattern: FramePattern,
    mic_pattern: FramePattern,
    expected: ExpectedHealth,
) -> StressCase {
    StressCase {
        name,
        ticks: 400,
        config: stress_config(64, 4),
        system_pattern,
        mic_pattern,
        initial_system_frames: 0,
        initial_mic_frames: 0,
        system_frame: [0.20, -0.20],
        mic_sample: 0.10,
        expected,
    }
}

#[derive(Debug)]
struct StressResult {
    health: MixedAudioEngineHealth,
    max_abs_output_sample: f32,
}

fn run_stress_case(case: &StressCase) -> StressResult {
    let mut engine = Engine::new(case.config).unwrap();
    push_system_frames(&mut engine, case.initial_system_frames, case.system_frame);
    push_mic_frames(&mut engine, case.initial_mic_frames, case.mic_sample);

    let mut output = vec![0.0_f32; TICK_FRAMES * 2];
    let mut max_abs_output_sample = 0.0_f32;
    for tick in 0..case.ticks {
        push_system_frames(
            &mut engine,
            case.system_pattern.frames_at(tick),
            case.system_frame,
        );
        push_mic_frames(
            &mut engine,
            case.mic_pattern.frames_at(tick),
            case.mic_sample,
        );
        engine
            .mix_available(TICK_FRAMES as u32, &mut output)
            .unwrap();
        for sample in &output {
            max_abs_output_sample = max_abs_output_sample.max(sample.abs());
        }
    }

    StressResult {
        health: engine.health(),
        max_abs_output_sample,
    }
}

fn push_system_frames(engine: &mut Engine, frames: usize, frame: [f32; 2]) {
    let mut samples = Vec::with_capacity(frames * 2);
    for _ in 0..frames {
        samples.extend_from_slice(&frame);
    }
    engine.push_system_interleaved_stereo(&samples).unwrap();
}

fn push_mic_frames(engine: &mut Engine, frames: usize, sample: f32) {
    let samples = vec![sample; frames];
    engine.push_mic_mono(&samples).unwrap();
}

fn assert_counter(case_name: &str, field_name: &str, actual: u64, expected: CounterExpectation) {
    match expected {
        CounterExpectation::Eq(value) => assert_eq!(
            actual, value,
            "{case_name}: expected {field_name} == {value}, got {actual}"
        ),
        CounterExpectation::Gt(value) => assert!(
            actual > value,
            "{case_name}: expected {field_name} > {value}, got {actual}"
        ),
    }
}

fn assert_expected(case: &StressCase, result: StressResult) {
    let health = result.health;
    assert_eq!(
        health.frames_mixed,
        (case.ticks * TICK_FRAMES) as u64,
        "{}: frames_mixed",
        case.name
    );
    assert!(
        health.source_frame_delta_abs <= case.expected.max_source_delta_abs,
        "{}: expected source_frame_delta_abs <= {}, got {}",
        case.name,
        case.expected.max_source_delta_abs,
        health.source_frame_delta_abs
    );
    assert_counter(
        case.name,
        "system_underrun_frames",
        health.system_underrun_frames,
        case.expected.system_underrun_frames,
    );
    assert_counter(
        case.name,
        "mic_underrun_frames",
        health.mic_underrun_frames,
        case.expected.mic_underrun_frames,
    );
    assert_counter(
        case.name,
        "clipped_samples",
        health.clipped_samples,
        case.expected.clipped_samples,
    );
    assert_counter(
        case.name,
        "system_drift_drop_frames",
        health.system_drift_drop_frames,
        case.expected.system_drift_drop_frames,
    );
    assert_counter(
        case.name,
        "mic_drift_drop_frames",
        health.mic_drift_drop_frames,
        case.expected.mic_drift_drop_frames,
    );
    assert_counter(
        case.name,
        "callback_error_count",
        health.callback_error_count,
        case.expected.callback_error_count,
    );
    assert!(
        result.max_abs_output_sample <= 1.0,
        "{}: output exceeded clamp range: {}",
        case.name,
        result.max_abs_output_sample
    );
}

fn clean_expected(max_source_delta_abs: u32) -> ExpectedHealth {
    ExpectedHealth {
        max_source_delta_abs,
        system_underrun_frames: CounterExpectation::Eq(0),
        mic_underrun_frames: CounterExpectation::Eq(0),
        clipped_samples: CounterExpectation::Eq(0),
        system_drift_drop_frames: CounterExpectation::Eq(0),
        mic_drift_drop_frames: CounterExpectation::Eq(0),
        callback_error_count: CounterExpectation::Eq(0),
    }
}

#[test]
fn declarative_synthetic_drift_stress_cases_a_through_g() {
    let mut faster_mic = clean_expected(36);
    faster_mic.mic_drift_drop_frames = CounterExpectation::Gt(0);

    let mut slower_mic = clean_expected(36);
    slower_mic.system_drift_drop_frames = CounterExpectation::Gt(0);

    let mut paused_mic = clean_expected(100);
    paused_mic.mic_underrun_frames = CounterExpectation::Eq(320);
    paused_mic.mic_drift_drop_frames = CounterExpectation::Gt(0);

    let mut far_ahead_mic = clean_expected(72);
    far_ahead_mic.mic_drift_drop_frames = CounterExpectation::Gt(0);

    let mut clipping = clean_expected(0);
    clipping.clipped_samples = CounterExpectation::Eq((16 * TICK_FRAMES * 2) as u64);

    let cases = [
        steady_case(
            "case A: both sources perfect 48 kHz cadence",
            FramePattern::Constant(TICK_FRAMES),
            FramePattern::Constant(TICK_FRAMES),
            clean_expected(0),
        ),
        steady_case(
            "case B: mic is slightly faster and gets nudged back",
            FramePattern::Constant(TICK_FRAMES),
            FramePattern::Cycle(&[TICK_FRAMES, TICK_FRAMES + 1]),
            faster_mic,
        ),
        steady_case(
            "case C: mic is slightly slower than a leading system source",
            FramePattern::Cycle(&[TICK_FRAMES, TICK_FRAMES + 1]),
            FramePattern::Constant(TICK_FRAMES),
            slower_mic,
        ),
        StressCase {
            name: "case D: mic arrives in uneven but pre-buffered bursts",
            ticks: 400,
            config: stress_config(192, 4),
            system_pattern: FramePattern::Constant(TICK_FRAMES),
            mic_pattern: FramePattern::Cycle(&[TICK_FRAMES * 2, 0]),
            initial_system_frames: 0,
            initial_mic_frames: 0,
            system_frame: [0.20, -0.20],
            mic_sample: 0.10,
            expected: clean_expected(0),
        },
        StressCase {
            name: "case E: mic pauses briefly, reports underrun, then recovers",
            ticks: 400,
            config: stress_config(192, 4),
            system_pattern: FramePattern::Constant(TICK_FRAMES),
            mic_pattern: FramePattern::PauseThenRecover {
                normal: TICK_FRAMES,
                pause_start_tick: 50,
                pause_ticks: 5,
                recovery_frames: TICK_FRAMES * 2,
                recovery_ticks: 5,
            },
            initial_system_frames: 0,
            initial_mic_frames: 0,
            system_frame: [0.20, -0.20],
            mic_sample: 0.10,
            expected: paused_mic,
        },
        StressCase {
            name: "case F: mic starts far ahead and is gradually bounded",
            ticks: 400,
            config: stress_config(128, 8),
            system_pattern: FramePattern::Constant(TICK_FRAMES),
            mic_pattern: FramePattern::Constant(TICK_FRAMES),
            initial_system_frames: 0,
            initial_mic_frames: 1_024,
            system_frame: [0.20, -0.20],
            mic_sample: 0.10,
            expected: far_ahead_mic,
        },
        StressCase {
            name: "case G: loud system plus loud mic clips predictably",
            ticks: 16,
            config: stress_config(64, 4),
            system_pattern: FramePattern::Constant(TICK_FRAMES),
            mic_pattern: FramePattern::Constant(TICK_FRAMES),
            initial_system_frames: 0,
            initial_mic_frames: 0,
            system_frame: [0.80, 0.80],
            mic_sample: 0.60,
            expected: clipping,
        },
    ];

    for case in &cases {
        let result = run_stress_case(case);
        assert_expected(case, result);
    }
}
