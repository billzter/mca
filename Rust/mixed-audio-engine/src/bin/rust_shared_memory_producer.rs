use mixed_audio_engine::session::{MixedAudioSession, MixedAudioSessionConfig};
use mixed_audio_engine::shared_memory::{
    install_signal_handlers, should_stop, MIXED_AUDIO_PHASE2_MARKER_LEFT,
    MIXED_AUDIO_PHASE2_MARKER_RIGHT, MIXED_AUDIO_SHM_NAME, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
};
use mixed_audio_engine::MixedAudioEngineConfig;
use std::env;
use std::thread;
use std::time::Duration;

const SYNTHETIC_BATCH_FRAMES: u32 = 480;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut run_once = false;
    let mut freeze_heartbeat = false;
    for arg in env::args().skip(1) {
        match arg.as_str() {
            "--once" => run_once = true,
            "--freeze-heartbeat" => freeze_heartbeat = true,
            _ => return Err(format!("unknown argument: {arg}")),
        }
    }

    install_signal_handlers();

    let capacity_frames = MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES * 5;
    let config = MixedAudioEngineConfig {
        source_capacity_frames: capacity_frames,
        max_source_skew_frames: MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
        max_drift_correction_per_mix: 8,
        system_gain: 1.0,
        mic_gain: 0.0,
        mic_compression_enabled: 0,
        mic_compression_threshold_db: -24.0,
        mic_compression_ratio: 3.0,
        mic_compression_attack_ms: 8.0,
        mic_compression_release_ms: 200.0,
        mic_compression_makeup_db: 6.0,
        mic_gate_threshold_db: -50.0,
        mic_gate_attenuation_db: -24.0,
    };
    let session_config = MixedAudioSessionConfig {
        engine: config,
        shared_memory_capacity_frames: capacity_frames,
        max_write_frames: MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
    };
    let mut session = MixedAudioSession::new_posix(session_config)
        .map_err(|error| format!("session init failed: {error:?}"))?;
    let mut buffers = MarkerBuffers::new(MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES);

    write_marker_batch(
        &mut session,
        &mut buffers,
        MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES,
        !freeze_heartbeat,
    )?;

    println!("created {MIXED_AUDIO_SHM_NAME}");
    println!(
        "header version=1 sample_rate=48000 channels=2 capacity_frames={} target_fill_frames={}",
        capacity_frames, MIXED_AUDIO_TARGET_SHARED_FILL_FRAMES
    );
    println!(
        "marker left={:.2} right={:.2}",
        MIXED_AUDIO_PHASE2_MARKER_LEFT, MIXED_AUDIO_PHASE2_MARKER_RIGHT
    );
    if freeze_heartbeat {
        println!("heartbeat frozen; press Ctrl-C to stop");
    } else if !run_once {
        println!("rust engine writes active; press Ctrl-C to stop");
    }

    while !should_stop() && !run_once {
        if !freeze_heartbeat {
            write_marker_batch(&mut session, &mut buffers, SYNTHETIC_BATCH_FRAMES, true)?;
        }
        thread::sleep(Duration::from_millis(10));
    }

    println!("removed {MIXED_AUDIO_SHM_NAME}");
    Ok(())
}

struct MarkerBuffers {
    system: Vec<f32>,
}

impl MarkerBuffers {
    fn new(max_frame_count: u32) -> Self {
        Self {
            system: vec![0.0; max_frame_count as usize * 2],
        }
    }

    fn prepare(&mut self, frame_count: u32) -> Result<&[f32], String> {
        let sample_count = frame_count as usize * 2;
        if sample_count > self.system.len() {
            return Err(format!(
                "frame_count {frame_count} exceeds preallocated buffers"
            ));
        }

        let system = &mut self.system[..sample_count];
        for frame in 0..frame_count as usize {
            system[frame * 2] = MIXED_AUDIO_PHASE2_MARKER_LEFT;
            system[frame * 2 + 1] = MIXED_AUDIO_PHASE2_MARKER_RIGHT;
        }
        Ok(&self.system[..sample_count])
    }
}

fn write_marker_batch(
    session: &mut MixedAudioSession<mixed_audio_engine::shared_memory::PosixSharedMemoryWriter>,
    buffers: &mut MarkerBuffers,
    frame_count: u32,
    update_heartbeat: bool,
) -> Result<(), String> {
    let system = buffers.prepare(frame_count)?;

    session
        .push_system_interleaved_stereo(system)
        .map_err(|error| format!("push system failed: {error:?}"))?;
    let heartbeat = if update_heartbeat {
        mixed_audio_engine::shared_memory::now_nanos()
    } else {
        0
    };
    session
        .mix_and_write(frame_count, heartbeat)
        .map_err(|error| format!("mix/write failed: {error:?}"))?;
    Ok(())
}
