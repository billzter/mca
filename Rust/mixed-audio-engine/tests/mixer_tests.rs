use mixed_audio_engine::{
    MixedAudioEngineConfig, MixedAudioEngineHandle, MixedAudioEngineHealth,
    MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS, MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
};
use std::sync::{atomic::Ordering, Mutex};

static ENVIRONMENT_LOCK: Mutex<()> = Mutex::new(());

fn default_config() -> MixedAudioEngineConfig {
    MixedAudioEngineConfig {
        source_capacity_frames: 4096,
        max_source_skew_frames: 128,
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

#[test]
fn config_and_health_have_stable_c_layout() {
    assert_eq!(std::mem::size_of::<MixedAudioEngineConfig>(), 52);
    assert_eq!(std::mem::align_of::<MixedAudioEngineConfig>(), 4);
    assert_eq!(std::mem::size_of::<MixedAudioEngineHealth>(), 112);
    assert_eq!(std::mem::align_of::<MixedAudioEngineHealth>(), 8);
    assert_eq!(MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE, 48_000);
    assert_eq!(MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS, 2);
}

#[test]
fn engine_reports_partial_system_queue_overflow() {
    let mut config = default_config();
    config.source_capacity_frames = 2;
    config.max_source_skew_frames = 2;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();

    let written = engine
        .push_system_interleaved_stereo(&[0.10, -0.10, 0.20, -0.20, 0.30, -0.30, 0.40, -0.40])
        .unwrap();

    assert_eq!(written, 2);
    let health = engine.health();
    assert_eq!(health.system_queue_frames, 2);
    assert_eq!(health.system_queue_overflow_frames, 2);
    assert_eq!(health.callback_error_count, 0);
}

#[test]
fn engine_reports_partial_mic_queue_overflow() {
    let mut config = default_config();
    config.source_capacity_frames = 2;
    config.max_source_skew_frames = 2;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();

    let written = engine.push_mic_mono(&[0.10, 0.20, 0.30, 0.40]).unwrap();

    assert_eq!(written, 2);
    let health = engine.health();
    assert_eq!(health.mic_queue_frames, 2);
    assert_eq!(health.mic_queue_overflow_frames, 2);
    assert_eq!(health.callback_error_count, 0);
}

#[test]
fn mixes_system_stereo_and_centered_mic_with_gains() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.20, -0.20, 0.40, -0.40])
        .unwrap();
    engine.push_mic_mono(&[0.10, -0.10]).unwrap();

    let mut output = [0.0_f32; 4];
    let mixed = engine.mix_available(2, &mut output).unwrap();

    assert_eq!(mixed, 2);
    assert_eq!(output, [0.30, -0.10, 0.30, -0.50]);
    assert_eq!(engine.health().frames_mixed, 2);
}

#[test]
fn live_level_update_changes_subsequent_mix_without_resetting_health() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.20, -0.20])
        .unwrap();
    engine.push_mic_mono(&[0.10]).unwrap();

    engine.set_levels(0.50, 2.0).unwrap();

    let mut output = [0.0_f32; 2];
    let mixed = engine.mix_available(1, &mut output).unwrap();

    assert_eq!(mixed, 1);
    assert_eq!(output, [0.30, 0.10]);
    assert_eq!(engine.health().frames_mixed, 1);
}

#[test]
fn live_level_update_rejects_non_finite_or_absurd_values() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();

    assert!(engine.set_levels(f32::NAN, 1.0).is_err());
    assert!(engine.set_levels(1.0, f32::INFINITY).is_err());
    assert!(engine.set_levels(-0.1, 1.0).is_err());
    assert!(engine.set_levels(1.0, 32.0).is_err());
}

#[test]
fn source_level_meters_report_peak_since_last_read_and_reset() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine.set_levels(0.50, 2.0).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.20, -0.80, 0.40, 0.10])
        .unwrap();
    engine.push_mic_mono(&[0.05, -0.30]).unwrap();

    let mut output = [0.0_f32; 4];
    engine.mix_available(2, &mut output).unwrap();
    let levels = engine.take_source_levels();

    assert_eq!(levels.system_peak, 0.40);
    assert_eq!(levels.mic_peak, 0.60);
    assert_eq!(engine.take_source_levels().system_peak, 0.0);
    assert_eq!(engine.take_source_levels().mic_peak, 0.0);
}

#[test]
fn source_level_meters_are_post_processing_and_post_slider() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_threshold_db = 0.0;
    config.mic_compression_ratio = 1.0;
    config.mic_compression_makeup_db = 6.0;
    config.mic_gate_threshold_db = -80.0;
    config.mic_gate_attenuation_db = 0.0;
    config.system_gain = 0.25;
    config.mic_gain = 2.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.80, -0.40])
        .unwrap();
    engine.push_mic_mono(&[0.10]).unwrap();

    let mut output = [0.0_f32; 2];
    engine.mix_available(1, &mut output).unwrap();
    let levels = engine.take_source_levels();

    assert_eq!(levels.system_peak, 0.20);
    assert!((levels.mic_peak - 0.39905244).abs() < 0.000_001);
}

#[test]
fn mic_compression_reduces_sustained_loud_voice() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_threshold_db = -20.0;
    config.mic_compression_ratio = 4.0;
    config.mic_compression_attack_ms = 0.1;
    config.mic_compression_release_ms = 200.0;
    config.mic_compression_makeup_db = 0.0;
    config.mic_gate_threshold_db = -80.0;
    config.mic_gate_attenuation_db = 0.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();
    engine.push_mic_mono(&vec![1.0; 256]).unwrap();

    let mut output = vec![0.0_f32; 256 * 2];
    engine.mix_available(256, &mut output).unwrap();

    let last_left = output[400];
    assert!(last_left > 0.15, "last_left={last_left}");
    assert!(last_left < 0.25, "last_left={last_left}");
}

#[test]
fn mic_compression_makeup_gain_lifts_voice_when_not_reducing() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_threshold_db = 0.0;
    config.mic_compression_ratio = 1.0;
    config.mic_compression_attack_ms = 8.0;
    config.mic_compression_release_ms = 200.0;
    config.mic_compression_makeup_db = 6.0;
    config.mic_gate_threshold_db = -80.0;
    config.mic_gate_attenuation_db = 0.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();
    engine.push_mic_mono(&[0.10]).unwrap();

    let mut output = [0.0_f32; 2];
    engine.mix_available(1, &mut output).unwrap();

    assert!((output[0] - 0.19952622).abs() < 0.000_001);
    assert_eq!(output[0], output[1]);
}

#[test]
fn mic_gate_attenuates_room_tone_before_makeup_gain() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_threshold_db = -24.0;
    config.mic_compression_ratio = 3.0;
    config.mic_compression_attack_ms = 8.0;
    config.mic_compression_release_ms = 200.0;
    config.mic_compression_makeup_db = 6.0;
    config.mic_gate_threshold_db = -50.0;
    config.mic_gate_attenuation_db = -24.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();
    engine.push_mic_mono(&[0.001]).unwrap();

    let mut output = [0.0_f32; 2];
    engine.mix_available(1, &mut output).unwrap();

    assert!(output[0] < 0.000_2, "output={}", output[0]);
}

#[test]
fn reset_sources_clears_mic_compression_envelope() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_threshold_db = -20.0;
    config.mic_compression_ratio = 4.0;
    config.mic_compression_attack_ms = 0.1;
    config.mic_compression_release_ms = 200.0;
    config.mic_compression_makeup_db = 0.0;
    config.mic_gate_threshold_db = -80.0;
    config.mic_gate_attenuation_db = 0.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();
    engine.push_mic_mono(&vec![1.0; 256]).unwrap();
    let mut output = vec![0.0_f32; 256 * 2];
    engine.mix_available(256, &mut output).unwrap();
    assert!(output[510] < 0.25);

    engine.reset_sources();
    engine.push_mic_mono(&[1.0]).unwrap();
    let mut after_reset = [0.0_f32; 2];
    engine.mix_available(1, &mut after_reset).unwrap();

    assert!(after_reset[0] > 0.50, "after_reset={}", after_reset[0]);
}

#[test]
fn mic_compression_config_rejects_invalid_parameters() {
    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_ratio = 0.5;
    assert!(mixed_audio_engine::Engine::new(config).is_err());

    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_attack_ms = 0.0;
    assert!(mixed_audio_engine::Engine::new(config).is_err());

    let mut config = default_config();
    config.mic_compression_enabled = 1;
    config.mic_compression_makeup_db = f32::NAN;
    assert!(mixed_audio_engine::Engine::new(config).is_err());
}

#[test]
fn live_mic_compression_toggle_changes_subsequent_mix() {
    let mut config = default_config();
    config.mic_compression_enabled = 0;
    config.mic_compression_threshold_db = 0.0;
    config.mic_compression_ratio = 1.0;
    config.mic_compression_makeup_db = 6.0;
    config.mic_gate_threshold_db = -80.0;
    config.mic_gate_attenuation_db = 0.0;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();

    engine.set_mic_compression_enabled(true).unwrap();
    engine.push_mic_mono(&[0.10]).unwrap();
    let mut output = [0.0_f32; 2];
    engine.mix_available(1, &mut output).unwrap();
    assert!((output[0] - 0.19952622).abs() < 0.000_001);

    engine.set_mic_compression_enabled(false).unwrap();
    engine.push_mic_mono(&[0.10]).unwrap();
    let mut dry_output = [0.0_f32; 2];
    engine.mix_available(1, &mut dry_output).unwrap();
    assert_eq!(dry_output, [0.10, 0.10]);
}

#[test]
fn missing_mic_mixes_system_with_silence_and_counts_underrun() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.25, -0.25, 0.50, -0.50])
        .unwrap();

    let mut output = [0.0_f32; 4];
    let mixed = engine.mix_available(2, &mut output).unwrap();

    assert_eq!(mixed, 2);
    assert_eq!(output, [0.25, -0.25, 0.50, -0.50]);
    assert_eq!(engine.health().mic_underrun_frames, 2);
    assert_eq!(engine.health().system_underrun_frames, 0);
}

#[test]
fn soft_limits_output_and_counts_overloaded_samples() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.80, -0.80])
        .unwrap();
    engine.push_mic_mono(&[0.60]).unwrap();

    let mut output = [0.0_f32; 2];
    let mixed = engine.mix_available(1, &mut output).unwrap();

    assert_eq!(mixed, 1);
    assert!(output[0] > 0.95, "limited={}", output[0]);
    assert!(output[0] < 1.0, "limited={}", output[0]);
    assert_eq!(output[1], -0.19999999);
    assert_eq!(engine.health().clipped_samples, 1);
}

#[test]
fn soft_limiter_is_monotonic_around_full_scale() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[1.0, 0.0, 1.0001, 0.0])
        .unwrap();

    let mut output = [0.0_f32; 4];
    engine.mix_available(2, &mut output).unwrap();

    assert!(output[0] > 0.95, "first={}", output[0]);
    assert!(
        output[2] >= output[0],
        "first={} second={}",
        output[0],
        output[2]
    );
    assert!(output[2] < 1.0, "second={}", output[2]);
    assert_eq!(engine.health().clipped_samples, 1);
}

#[test]
fn limiter_rejects_non_finite_samples() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[f32::INFINITY, f32::NAN, f32::NEG_INFINITY, 0.0])
        .unwrap();

    let mut output = [0.0_f32; 4];
    engine.mix_available(2, &mut output).unwrap();

    assert_eq!(output, [1.0, 0.0, -1.0, 0.0]);
    assert_eq!(engine.health().clipped_samples, 3);
}

#[test]
fn source_skew_correction_is_bounded_per_mix_call() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    let system = vec![0.0_f32; 256 * 2];
    let mic = vec![0.0_f32; 512];
    engine.push_system_interleaved_stereo(&system).unwrap();
    engine.push_mic_mono(&mic).unwrap();

    let mut output = vec![0.0_f32; 64 * 2];
    let mixed = engine.mix_available(64, &mut output).unwrap();
    let health = engine.health();

    assert_eq!(mixed, 64);
    assert_eq!(health.mic_drift_drop_frames, 8);
    assert_eq!(health.source_frame_delta, -248);
}

#[test]
fn persistent_mic_lead_is_gradually_aligned_toward_target_fill() {
    let mut config = default_config();
    config.source_capacity_frames = 16_384;
    config.max_source_skew_frames = 2_400;
    config.max_drift_correction_per_mix = 8;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();

    let system = vec![0.0_f32; 512 * 2];
    let mic = vec![0.0_f32; 512];
    engine.push_mic_mono(&vec![0.0; 2_048]).unwrap();
    for _ in 0..128 {
        engine.push_system_interleaved_stereo(&system).unwrap();
        engine.push_mic_mono(&mic).unwrap();
        let mut output = vec![0.0_f32; 512 * 2];
        engine.mix_available(512, &mut output).unwrap();
    }

    let health = engine.health();
    assert!(health.mic_queue_frames <= 1_200);
    assert_eq!(health.system_underrun_frames, 0);
    assert_eq!(health.mic_underrun_frames, 0);
    assert!(health.mic_drift_drop_frames > 0);
    assert!(health.mic_drift_drop_frames <= 1024);
}

#[test]
fn drift_alignment_does_not_correct_when_mic_lead_is_near_target() {
    let mut config = default_config();
    config.source_capacity_frames = 16_384;
    config.max_source_skew_frames = 2_400;
    config.max_drift_correction_per_mix = 8;
    let mut engine = mixed_audio_engine::Engine::new(config).unwrap();

    let system = vec![0.0_f32; 512 * 2];
    let mic = vec![0.0_f32; 512];
    engine.push_mic_mono(&vec![0.0; 1_024]).unwrap();
    for _ in 0..16 {
        engine.push_system_interleaved_stereo(&system).unwrap();
        engine.push_mic_mono(&mic).unwrap();
        let mut output = vec![0.0_f32; 512 * 2];
        engine.mix_available(512, &mut output).unwrap();
    }

    let health = engine.health();
    assert_eq!(health.mic_queue_frames, 1_024);
    assert_eq!(health.mic_drift_drop_frames, 0);
}

#[test]
fn c_abi_push_mix_and_health_snapshot_work() {
    let config = default_config();
    let handle = unsafe { mixed_audio_engine::mixed_audio_engine_create(config) };
    assert!(!handle.is_null());

    assert_eq!(
        unsafe { mixed_audio_engine::mixed_audio_engine_set_levels(handle, 0.50, 2.0) },
        0
    );

    let system = [0.10_f32, -0.10, 0.20, -0.20];
    let mic = [0.05_f32, 0.10];
    let system_pushed = unsafe {
        mixed_audio_engine::mixed_audio_engine_push_system_interleaved_stereo(
            handle,
            system.as_ptr(),
            2,
        )
    };
    let mic_pushed =
        unsafe { mixed_audio_engine::mixed_audio_engine_push_mic_mono(handle, mic.as_ptr(), 2) };
    assert_eq!(system_pushed, 2);
    assert_eq!(mic_pushed, 2);

    let mut output = [0.0_f32; 4];
    let mixed = unsafe {
        mixed_audio_engine::mixed_audio_engine_mix_available(handle, output.as_mut_ptr(), 2)
    };
    assert_eq!(mixed, 2);
    assert_eq!(output, [0.15, 0.05, 0.30, 0.10]);

    let mut health = MixedAudioEngineHealth::default();
    let health_ok =
        unsafe { mixed_audio_engine::mixed_audio_engine_get_health(handle, &mut health) };
    assert_eq!(health_ok, 0);
    assert_eq!(health.frames_mixed, 2);

    unsafe { mixed_audio_engine::mixed_audio_engine_destroy(handle) };
}

#[test]
fn c_abi_null_handle_is_rejected() {
    let mut output = [0.0_f32; 2];
    let mixed = unsafe {
        mixed_audio_engine::mixed_audio_engine_mix_available(
            std::ptr::null_mut::<MixedAudioEngineHandle>(),
            output.as_mut_ptr(),
            1,
        )
    };
    assert_eq!(mixed, 0);
    assert_eq!(
        unsafe {
            mixed_audio_engine::mixed_audio_engine_set_levels(
                std::ptr::null_mut::<MixedAudioEngineHandle>(),
                1.0,
                1.0,
            )
        },
        -1
    );
}

#[test]
fn c_abi_invalid_inputs_fail_closed_before_panic_paths() {
    use mixed_audio_engine::session::{
        mixed_audio_session_copy_levels, mixed_audio_session_create,
        mixed_audio_session_get_health, mixed_audio_session_mix_and_write,
        mixed_audio_session_set_levels, mixed_audio_session_set_mic_compression_enabled,
        MixedAudioSessionConfig, MixedAudioSessionHandle,
    };

    let invalid_engine = MixedAudioEngineConfig {
        source_capacity_frames: 0,
        ..default_config()
    };
    let engine_handle = unsafe { mixed_audio_engine::mixed_audio_engine_create(invalid_engine) };
    assert!(engine_handle.is_null());

    let valid_engine = unsafe { mixed_audio_engine::mixed_audio_engine_create(default_config()) };
    assert!(!valid_engine.is_null());
    assert_eq!(
        unsafe {
            mixed_audio_engine::mixed_audio_engine_push_system_interleaved_stereo(
                valid_engine,
                std::ptr::null(),
                128,
            )
        },
        0
    );
    assert_eq!(
        unsafe {
            mixed_audio_engine::mixed_audio_engine_get_health(valid_engine, std::ptr::null_mut())
        },
        -1
    );
    unsafe { mixed_audio_engine::mixed_audio_engine_destroy(valid_engine) };

    let invalid_session = MixedAudioSessionConfig {
        shared_memory_capacity_frames: 0,
        ..MixedAudioSessionConfig::default()
    };
    let session_handle = unsafe { mixed_audio_session_create(invalid_session) };
    assert!(session_handle.is_null());
    assert_eq!(
        unsafe {
            mixed_audio_session_mix_and_write(std::ptr::null_mut::<MixedAudioSessionHandle>(), 512)
        },
        0
    );
    assert_eq!(
        unsafe {
            mixed_audio_session_get_health(
                std::ptr::null::<MixedAudioSessionHandle>(),
                std::ptr::null_mut(),
            )
        },
        -1
    );
    assert_eq!(
        unsafe {
            mixed_audio_session_set_levels(
                std::ptr::null_mut::<MixedAudioSessionHandle>(),
                1.0,
                1.0,
            )
        },
        -1
    );
    assert_eq!(
        unsafe {
            mixed_audio_session_set_mic_compression_enabled(
                std::ptr::null_mut::<MixedAudioSessionHandle>(),
                1,
            )
        },
        -1
    );
    let mut system_peak = 0.0_f32;
    let mut mic_peak = 0.0_f32;
    assert_eq!(
        unsafe {
            mixed_audio_session_copy_levels(
                std::ptr::null_mut::<MixedAudioSessionHandle>(),
                &mut system_peak,
                &mut mic_peak,
            )
        },
        -1
    );
}

#[test]
fn c_abi_unlinks_session_specific_test_shared_memory_name() {
    use mixed_audio_engine::session::{
        mixed_audio_session_create, mixed_audio_session_destroy, mixed_audio_session_mix_and_write,
        mixed_audio_session_push_system_interleaved_stereo,
        mixed_audio_session_unlink_session_shared_memory, MixedAudioSessionConfig,
        MIXED_AUDIO_TEST_SHM_NAME_ENV,
    };
    use mixed_audio_engine::shared_memory::{PosixSharedMemoryWriter, SharedMemoryAudioWriter};

    let _environment_guard = ENVIRONMENT_LOCK.lock().unwrap();
    let name = format!("/mca.mix.test.{}", std::process::id());
    let _ = PosixSharedMemoryWriter::unlink_name(&name);

    std::env::set_var(MIXED_AUDIO_TEST_SHM_NAME_ENV, &name);
    let config = MixedAudioSessionConfig {
        shared_memory_capacity_frames: 16,
        max_write_frames: 4,
        ..MixedAudioSessionConfig::default()
    };
    let session_handle = unsafe { mixed_audio_session_create(config) };
    std::env::remove_var(MIXED_AUDIO_TEST_SHM_NAME_ENV);

    assert!(!session_handle.is_null());
    let samples = [0.25_f32, -0.25];
    assert_eq!(
        unsafe {
            mixed_audio_session_push_system_interleaved_stereo(session_handle, samples.as_ptr(), 1)
        },
        1
    );
    assert_eq!(
        unsafe { mixed_audio_session_mix_and_write(session_handle, 1) },
        1
    );
    assert_eq!(
        unsafe { mixed_audio_session_unlink_session_shared_memory(session_handle) },
        0
    );
    unsafe { mixed_audio_session_destroy(session_handle) };

    let recreated = PosixSharedMemoryWriter::create(&name, 16).unwrap();
    assert_eq!(recreated.current_write_frame_index(), 0);
    drop(recreated);
    let _ = PosixSharedMemoryWriter::unlink_name(&name);
}

#[test]
fn c_abi_auto_namespaces_xctest_session_shared_memory() {
    use mixed_audio_engine::session::{
        mixed_audio_session_create, mixed_audio_session_destroy, mixed_audio_session_mix_and_write,
        mixed_audio_session_push_system_interleaved_stereo,
        mixed_audio_session_unlink_session_shared_memory, MixedAudioSessionConfig,
        MIXED_AUDIO_TEST_SHM_NAME_ENV,
    };
    use mixed_audio_engine::shared_memory::{PosixSharedMemoryWriter, SharedMemoryAudioWriter};

    let _environment_guard = ENVIRONMENT_LOCK.lock().unwrap();
    let name = format!("/mca.mix.test.{}", std::process::id());
    let _ = PosixSharedMemoryWriter::unlink_name(&name);

    std::env::remove_var(MIXED_AUDIO_TEST_SHM_NAME_ENV);
    std::env::set_var(
        "XCTestConfigurationFilePath",
        "/tmp/MixedCaptureAudioTests.xctestconfiguration",
    );
    let config = MixedAudioSessionConfig {
        shared_memory_capacity_frames: 16,
        max_write_frames: 4,
        ..MixedAudioSessionConfig::default()
    };
    let session_handle = unsafe { mixed_audio_session_create(config) };
    std::env::remove_var("XCTestConfigurationFilePath");

    assert!(!session_handle.is_null());
    let samples = [0.25_f32, -0.25];
    assert_eq!(
        unsafe {
            mixed_audio_session_push_system_interleaved_stereo(session_handle, samples.as_ptr(), 1)
        },
        1
    );
    assert_eq!(
        unsafe { mixed_audio_session_mix_and_write(session_handle, 1) },
        1
    );

    let recreated = PosixSharedMemoryWriter::create(&name, 16).unwrap();
    assert_eq!(recreated.current_write_frame_index(), 0);
    drop(recreated);
    let _ = PosixSharedMemoryWriter::unlink_name(&name);

    assert_eq!(
        unsafe { mixed_audio_session_unlink_session_shared_memory(session_handle) },
        0
    );
    unsafe { mixed_audio_session_destroy(session_handle) };

    let recreated_after_session = PosixSharedMemoryWriter::create(&name, 16).unwrap();
    assert_eq!(recreated_after_session.current_write_frame_index(), 0);
    drop(recreated_after_session);
    let _ = PosixSharedMemoryWriter::unlink_name(&name);
}

#[test]
fn shared_memory_header_matches_c_abi_layout() {
    use mixed_audio_engine::shared_memory::{
        MixedAudioSharedMemoryHeader, MIXED_AUDIO_HEARTBEAT_STALE_NANOS,
        MIXED_AUDIO_OUTPUT_CHANNEL_COUNT, MIXED_AUDIO_OUTPUT_SAMPLE_RATE, MIXED_AUDIO_SHM_MAGIC,
        MIXED_AUDIO_SHM_NAME, MIXED_AUDIO_SHM_VERSION, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
    };

    assert_eq!(MIXED_AUDIO_SHM_MAGIC, 0x4D415544);
    assert_eq!(MIXED_AUDIO_SHM_VERSION, 1);
    assert_eq!(MIXED_AUDIO_SHM_NAME, "/mca.mix.v1");
    assert_eq!(MIXED_AUDIO_OUTPUT_SAMPLE_RATE, 48_000);
    assert_eq!(MIXED_AUDIO_OUTPUT_CHANNEL_COUNT, 2);
    assert_eq!(MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES, 2400);
    assert_eq!(MIXED_AUDIO_HEARTBEAT_STALE_NANOS, 500_000_000);
    assert_eq!(std::mem::size_of::<MixedAudioSharedMemoryHeader>(), 88);
    assert_eq!(std::mem::align_of::<MixedAudioSharedMemoryHeader>(), 8);
    assert_eq!(
        std::mem::offset_of!(MixedAudioSharedMemoryHeader, write_frame_index),
        24
    );
    assert_eq!(
        std::mem::offset_of!(MixedAudioSharedMemoryHeader, generation),
        40
    );
    assert_eq!(
        std::mem::offset_of!(MixedAudioSharedMemoryHeader, producer_heartbeat_nanos),
        48
    );
}

#[test]
fn shared_memory_writer_tracks_indices_and_counters() {
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let mut layout = SharedMemoryLayout::new_for_test(16);
    assert_eq!(layout.header().capacity_frames, 16);

    let status = layout.write_frames(0, &[0.25, -0.25, 0.50, -0.50], 1, 1234);
    assert_eq!(layout.header().write_frame_index.load(Ordering::Acquire), 2);
    assert_eq!(layout.header().generation.load(Ordering::Acquire), 1);
    assert_eq!(
        layout
            .header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire),
        1234
    );
    assert_eq!(layout.frames()[0], 0.25);
    assert_eq!(layout.frames()[1], -0.25);
    assert_eq!(layout.frames()[2], 0.50);
    assert_eq!(layout.frames()[3], -0.50);
    assert_eq!(status.fill_frames, 2);
    assert_eq!(status.fill_error_frames, -2398);
    assert_eq!(status.fill_error_abs_frames, 2398);
    assert_eq!(status.overrun_frames, 0);

    layout.increment_clipped_frames(3);
    assert_eq!(
        layout.header().clipped_frame_count.load(Ordering::Relaxed),
        3
    );
}

#[test]
fn shared_memory_writer_reports_reader_fill_error_and_overruns() {
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let mut layout = SharedMemoryLayout::new_for_test(4_800);
    layout
        .header()
        .read_frame_index
        .store(20, Ordering::Release);

    let status = layout.write_frames(2_420, &[0.0; 4 * 2], 1, 1234);

    assert_eq!(
        layout.header().write_frame_index.load(Ordering::Acquire),
        2_424
    );
    assert_eq!(status.fill_frames, 2_404);
    assert_eq!(status.fill_error_frames, 4);
    assert_eq!(status.fill_error_abs_frames, 4);
    assert_eq!(status.overrun_frames, 0);
    assert_eq!(layout.header().overrun_count.load(Ordering::Relaxed), 0);

    layout
        .header()
        .read_frame_index
        .store(2_400, Ordering::Release);
    let overrun = layout.write_frames(7_196, &[0.0; 8 * 2], 1, 1235);

    assert_eq!(overrun.fill_frames, 4_800);
    assert_eq!(overrun.fill_error_frames, 2_400);
    assert_eq!(overrun.fill_error_abs_frames, 2_400);
    assert_eq!(overrun.overrun_frames, 4);
    assert_eq!(layout.header().overrun_count.load(Ordering::Relaxed), 4);
    assert_eq!(
        layout.header().dropped_frame_count.load(Ordering::Relaxed),
        4
    );
}

#[test]
fn shared_memory_writer_includes_source_queue_overflow_in_dropped_frames() {
    use mixed_audio_engine::shared_memory::{SharedMemoryAudioWriter, SharedMemoryLayout};

    let mut layout = SharedMemoryLayout::new_for_test(16);
    let mut health = MixedAudioEngineHealth::default();
    health.system_queue_overflow_frames = 3;
    health.mic_queue_overflow_frames = 5;

    layout.write_audio_frames(0, &[0.0, 0.0], 1, 1234, health);

    assert_eq!(
        layout.header().dropped_frame_count.load(Ordering::Relaxed),
        8
    );
}

#[test]
fn shared_memory_writer_counts_only_newly_overwritten_frames() {
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let mut layout = SharedMemoryLayout::new_for_test(4_800);
    layout.header().read_frame_index.store(0, Ordering::Release);

    let full = layout.write_frames(0, &vec![0.0; 4_800 * 2], 1, 1234);
    assert_eq!(full.fill_frames, 4_800);
    assert_eq!(full.overrun_frames, 0);
    assert_eq!(layout.header().overrun_count.load(Ordering::Relaxed), 0);

    let first_overrun = layout.write_frames(4_800, &vec![0.0; 512 * 2], 1, 1235);
    assert_eq!(first_overrun.fill_frames, 4_800);
    assert_eq!(first_overrun.overrun_frames, 512);
    assert_eq!(layout.header().overrun_count.load(Ordering::Relaxed), 512);

    let second_overrun = layout.write_frames(5_312, &vec![0.0; 512 * 2], 1, 1236);
    assert_eq!(second_overrun.fill_frames, 4_800);
    assert_eq!(second_overrun.overrun_frames, 512);
    assert_eq!(layout.header().overrun_count.load(Ordering::Relaxed), 1_024);
}

#[test]
fn posix_shared_memory_writer_creates_hal_writable_object() {
    use mixed_audio_engine::shared_memory::MIXED_AUDIO_SHM_MODE;

    assert_eq!(MIXED_AUDIO_SHM_MODE, 0o666);
}

#[test]
fn posix_shared_memory_writer_adopts_existing_object_for_restart() {
    use mixed_audio_engine::shared_memory::{PosixSharedMemoryWriter, SharedMemoryAudioWriter};

    let name = format!("/mca.test.restart.{}", std::process::id());
    let _ = PosixSharedMemoryWriter::unlink_name(&name);

    {
        let mut first = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        first.write_audio_frames(
            40,
            &[0.10, -0.10, 0.20, -0.20],
            7,
            1234,
            MixedAudioEngineHealth::default(),
        );
    }

    let second = PosixSharedMemoryWriter::create(&name, 16).unwrap();
    assert_eq!(second.current_write_frame_index(), 42);
    assert_eq!(second.current_generation(), 7);
    assert_eq!(second.current_heartbeat_nanos(), 0);

    let _ = PosixSharedMemoryWriter::unlink_name(&name);
}

#[test]
fn posix_shared_memory_writer_replaces_wrong_sized_existing_object() {
    use mixed_audio_engine::shared_memory::{PosixSharedMemoryWriter, SharedMemoryAudioWriter};

    let name = format!("/mca.test.resize.{}", std::process::id());
    let _ = PosixSharedMemoryWriter::unlink_name(&name);

    {
        let mut first = PosixSharedMemoryWriter::create(&name, 16).unwrap();
        first.write_audio_frames(
            40,
            &[0.10, -0.10, 0.20, -0.20],
            7,
            1234,
            MixedAudioEngineHealth::default(),
        );
    }

    let second = PosixSharedMemoryWriter::create(&name, 32).unwrap();
    assert_eq!(second.current_write_frame_index(), 0);
    assert_eq!(second.current_generation(), 1);
    assert_eq!(second.current_heartbeat_nanos(), 0);

    let _ = PosixSharedMemoryWriter::unlink_name(&name);
}

#[test]
fn shared_ring_fill_error_stats_report_percentiles() {
    use mixed_audio_engine::shared_memory::{
        SharedMemoryLayout, SharedRingFillErrorStats, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
    };

    let mut layout = SharedMemoryLayout::new_for_test(4_800);
    let desired_errors = [-12, -4, -1, 0, 1, 3, 5, 8, 13, 21];
    let mut observed_errors = Vec::with_capacity(desired_errors.len());
    for error in desired_errors {
        layout.header().read_frame_index.store(0, Ordering::Release);
        let first_frame =
            (MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES as i64 + i64::from(error) - 1).max(0) as u64;
        let status = layout.write_frames(first_frame, &[0.0, 0.0], 1, 1234);
        observed_errors.push(status.fill_error_frames);
    }

    assert_eq!(observed_errors, desired_errors);
    let stats = SharedRingFillErrorStats::from_errors(&observed_errors).unwrap();

    assert_eq!(stats.sample_count, 10);
    assert_eq!(stats.min_frames, -12);
    assert_eq!(stats.max_frames, 21);
    assert_eq!(stats.max_abs_frames, 21);
    assert!((stats.mean_frames - 3.4).abs() < 0.000_001);
    assert_eq!(stats.p95_abs_frames, 21);
    assert_eq!(stats.p99_abs_frames, 21);
    assert!(SharedRingFillErrorStats::from_errors(&[]).is_none());
}

#[test]
fn session_writes_real_capture_buffers_to_shared_memory() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    session
        .push_system_interleaved_stereo(&[0.20, -0.20, 0.40, -0.40])
        .unwrap();
    session.push_mic_mono(&[0.10, -0.10]).unwrap();

    let written = session.mix_and_write(2, 5678).unwrap();
    assert_eq!(written, 2);

    let layout = session.writer();
    assert_eq!(layout.header().write_frame_index.load(Ordering::Acquire), 2);
    assert_eq!(
        layout
            .header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire),
        5678
    );
    assert_eq!(&layout.frames()[..4], &[0.30, -0.10, 0.30, -0.50]);
    let health = session.health();
    assert_eq!(health.frames_mixed, 2);
    assert_eq!(health.shared_ring_fill_frames, 2);
    assert_eq!(health.shared_ring_fill_error_frames, -2398);
    assert_eq!(health.shared_ring_fill_error_abs_frames, 2398);
    assert_eq!(health.shared_ring_overrun_frames, 0);
}

#[test]
fn session_adopts_writer_generation_and_write_index_on_restart() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let mut layout = SharedMemoryLayout::new_for_test(16);
    layout.write_frames(40, &[0.10, -0.10, 0.20, -0.20], 7, 1234);

    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    assert_eq!(session.frame_index(), 42);
    session
        .push_system_interleaved_stereo(&[0.30, -0.30])
        .unwrap();
    session.push_mic_mono(&[0.10]).unwrap();
    assert_eq!(session.mix_and_write(1, 5678).unwrap(), 1);

    let layout = session.writer();
    assert_eq!(
        layout.header().write_frame_index.load(Ordering::Acquire),
        43
    );
    assert_eq!(layout.header().generation.load(Ordering::Acquire), 8);
}

#[test]
fn session_clear_shared_memory_preserves_restart_state_without_audio() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    session
        .push_system_interleaved_stereo(&[0.20, -0.20, 0.40, -0.40])
        .unwrap();
    session.push_mic_mono(&[0.10, -0.10]).unwrap();
    assert_eq!(session.mix_and_write(2, 5678).unwrap(), 2);
    assert!(session.writer().frames()[..4]
        .iter()
        .any(|sample| *sample != 0.0));

    session.clear_shared_memory();

    let layout = session.writer();
    assert_eq!(layout.header().write_frame_index.load(Ordering::Acquire), 2);
    assert_eq!(layout.header().generation.load(Ordering::Acquire), 1);
    assert_eq!(
        layout
            .header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire),
        0
    );
    assert!(layout.frames().iter().all(|sample| *sample == 0.0));
}

#[test]
fn session_level_update_changes_live_writer_output() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    session.set_levels(0.50, 2.0).unwrap();
    session
        .push_system_interleaved_stereo(&[0.20, -0.20])
        .unwrap();
    session.push_mic_mono(&[0.10]).unwrap();

    let written = session.mix_and_write(1, 4321).unwrap();

    assert_eq!(written, 1);
    assert_eq!(&session.writer().frames()[..2], &[0.30, 0.10]);
    assert_eq!(session.health().frames_mixed, 1);
}

#[test]
fn session_level_reader_reports_peak_since_last_read() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    session.set_levels(0.50, 2.0).unwrap();
    session
        .push_system_interleaved_stereo(&[0.20, -0.80])
        .unwrap();
    session.push_mic_mono(&[0.30]).unwrap();
    session.mix_and_write(1, 1234).unwrap();

    let levels = session.take_source_levels();

    assert_eq!(levels.system_peak, 0.40);
    assert_eq!(levels.mic_peak, 0.60);
    assert_eq!(session.take_source_levels().system_peak, 0.0);
    assert_eq!(session.take_source_levels().mic_peak, 0.0);
}

#[test]
fn session_rejects_writes_larger_than_preallocated_output_buffer() {
    use mixed_audio_engine::session::{MixedAudioSession, SessionError};
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 2).unwrap();

    let result = session.mix_and_write(3, 1);
    assert_eq!(result, Err(SessionError::WriteRequestTooLarge));
    assert_eq!(session.health().callback_error_count, 1);
}

#[test]
fn session_reset_clears_sources_but_preserves_writer_and_frame_index() {
    use mixed_audio_engine::session::MixedAudioSession;
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let layout = SharedMemoryLayout::new_for_test(16);
    let mut session = MixedAudioSession::new_for_writer(default_config(), layout, 4).unwrap();

    session
        .push_system_interleaved_stereo(&[0.80, -0.80, 0.60, -0.60])
        .unwrap();
    session.push_mic_mono(&[0.20, 0.20]).unwrap();
    assert_eq!(session.health().system_queue_frames, 2);
    assert_eq!(session.health().mic_queue_frames, 2);

    session.reset_sources();
    assert_eq!(session.health().system_queue_frames, 0);
    assert_eq!(session.health().mic_queue_frames, 0);
    assert_eq!(session.frame_index(), 0);

    session
        .push_system_interleaved_stereo(&[0.10, -0.10, 0.30, -0.30])
        .unwrap();
    session.push_mic_mono(&[0.05, -0.05]).unwrap();
    let written = session.mix_and_write(2, 9_876).unwrap();
    assert_eq!(written, 2);

    let layout = session.writer();
    assert_eq!(layout.header().write_frame_index.load(Ordering::Acquire), 2);
    assert_eq!(
        layout
            .header()
            .producer_heartbeat_nanos
            .load(Ordering::Acquire),
        9_876
    );
    for (actual, expected) in layout.frames()[..4].iter().zip([0.15, -0.05, 0.25, -0.35]) {
        assert!((actual - expected).abs() < 0.000_001);
    }
    assert_eq!(session.frame_index(), 2);
}
