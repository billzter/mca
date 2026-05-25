use mixed_audio_engine::{
    MixedAudioEngineConfig, MixedAudioEngineHandle, MixedAudioEngineHealth,
    MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS, MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE,
};
use std::sync::atomic::Ordering;

fn default_config() -> MixedAudioEngineConfig {
    MixedAudioEngineConfig {
        source_capacity_frames: 4096,
        max_source_skew_frames: 128,
        max_drift_correction_per_mix: 8,
        system_gain: 1.0,
        mic_gain: 1.0,
    }
}

#[test]
fn config_and_health_have_stable_c_layout() {
    assert_eq!(std::mem::size_of::<MixedAudioEngineConfig>(), 20);
    assert_eq!(std::mem::align_of::<MixedAudioEngineConfig>(), 4);
    assert_eq!(std::mem::size_of::<MixedAudioEngineHealth>(), 72);
    assert_eq!(std::mem::align_of::<MixedAudioEngineHealth>(), 8);
    assert_eq!(MIXED_AUDIO_ENGINE_OUTPUT_SAMPLE_RATE, 48_000);
    assert_eq!(MIXED_AUDIO_ENGINE_OUTPUT_CHANNELS, 2);
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
fn clamps_output_and_counts_clipped_samples() {
    let mut engine = mixed_audio_engine::Engine::new(default_config()).unwrap();
    engine
        .push_system_interleaved_stereo(&[0.80, -0.80])
        .unwrap();
    engine.push_mic_mono(&[0.60]).unwrap();

    let mut output = [0.0_f32; 2];
    let mixed = engine.mix_available(1, &mut output).unwrap();

    assert_eq!(mixed, 1);
    assert_eq!(output, [1.0, -0.19999999]);
    assert_eq!(engine.health().clipped_samples, 1);
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
    assert_eq!(output, [0.15, -0.05, 0.30, -0.10]);

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
}

#[test]
fn shared_memory_header_matches_c_abi_layout() {
    use mixed_audio_engine::shared_memory::{
        MixedAudioSharedMemoryHeader, MIXED_AUDIO_SHM_MAGIC, MIXED_AUDIO_SHM_NAME,
        MIXED_AUDIO_SHM_VERSION, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
    };

    assert_eq!(MIXED_AUDIO_SHM_MAGIC, 0x4D415544);
    assert_eq!(MIXED_AUDIO_SHM_VERSION, 1);
    assert_eq!(MIXED_AUDIO_SHM_NAME, "/mca.mix.v1");
    assert_eq!(MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES, 2400);
    assert_eq!(std::mem::size_of::<MixedAudioSharedMemoryHeader>(), 88);
    assert_eq!(std::mem::align_of::<MixedAudioSharedMemoryHeader>(), 8);
}

#[test]
fn shared_memory_writer_tracks_indices_and_counters() {
    use mixed_audio_engine::shared_memory::SharedMemoryLayout;

    let mut layout = SharedMemoryLayout::new_for_test(16);
    assert_eq!(layout.header().capacity_frames, 16);

    layout.write_frames(0, &[0.25, -0.25, 0.50, -0.50], 1, 1234);
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

    layout.increment_clipped_frames(3);
    assert_eq!(
        layout.header().clipped_frame_count.load(Ordering::Relaxed),
        3
    );
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
    assert_eq!(session.health().frames_mixed, 2);
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
