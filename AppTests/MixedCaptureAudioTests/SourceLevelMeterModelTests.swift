import Foundation
@testable import MixedCaptureAudio
import XCTest

final class SourceLevelMeterModelTests: XCTestCase {

    @MainActor
    func testRefreshPublishesRunningSnapshotWithDecay() {
        let controller = FakeMeterLiveMixerController()
        var isRunning = true
        let model = SourceLevelMeterModel(
            liveMixerController: controller,
            isMixerRunning: { isRunning }
        )

        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.80, microphonePeak: 0.40)
        model.refresh()

        assertEqual(model.snapshot, SourceLevelMeterSnapshot(systemPeak: 0.80, microphonePeak: 0.40))

        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.10, microphonePeak: 0.05)
        model.refresh()

        assertAlmostEqual(model.snapshot.systemPeak, 0.68)
        assertAlmostEqual(model.snapshot.microphonePeak, 0.34)

        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.90, microphonePeak: 0.70)
        model.refresh()

        assertEqual(model.snapshot, SourceLevelMeterSnapshot(systemPeak: 0.90, microphonePeak: 0.70))

        isRunning = false
        model.refresh()

        assertEqual(model.snapshot, .empty)
    }

    @MainActor
    func testRefreshClearsWhenMixerIsNotRunning() {
        let controller = FakeMeterLiveMixerController()
        let model = SourceLevelMeterModel(
            liveMixerController: controller,
            isMixerRunning: { false }
        )
        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.80, microphonePeak: 0.40)

        model.refresh()

        assertEqual(model.snapshot, .empty)
    }

    @MainActor
    func testRefreshReportsRawSnapshotBeforeDecay() {
        let controller = FakeMeterLiveMixerController()
        var observedSnapshots: [SourceLevelMeterSnapshot] = []
        let model = SourceLevelMeterModel(
            liveMixerController: controller,
            isMixerRunning: { true },
            onRawSnapshot: { observedSnapshots.append($0) }
        )
        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.80, microphonePeak: 0.40)
        model.refresh()
        controller.sourceLevelSnapshot = SourceLevelMeterSnapshot(systemPeak: 0.10, microphonePeak: 0.05)
        model.refresh()

        assertEqual(observedSnapshots, [
            SourceLevelMeterSnapshot(systemPeak: 0.80, microphonePeak: 0.40),
            SourceLevelMeterSnapshot(systemPeak: 0.10, microphonePeak: 0.05),
        ])
        assertAlmostEqual(model.snapshot.systemPeak, 0.68)
        assertAlmostEqual(model.snapshot.microphonePeak, 0.34)
    }

    @MainActor
    func testAutoVerifierRequiresRecorderActivity() {
        var proofCount = 0
        let verifier = SystemAudioAutoVerifier(requiredConsecutiveTicks: 2) {
            proofCount += 1
        }

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.02, microphonePeak: 0), recorderActive: false)
        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.02, microphonePeak: 0), recorderActive: false)

        assertEqual(proofCount, 0)
    }

    @MainActor
    func testAutoVerifierRequiresRawSystemAudioAboveThreshold() {
        var proofCount = 0
        let verifier = SystemAudioAutoVerifier(requiredConsecutiveTicks: 2) {
            proofCount += 1
        }

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.0001, microphonePeak: 0), recorderActive: true)
        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.0001, microphonePeak: 0), recorderActive: true)

        assertEqual(proofCount, 0)
    }

    @MainActor
    func testAutoVerifierFiresOnceAfterConsecutiveProofTicks() {
        var proofCount = 0
        let verifier = SystemAudioAutoVerifier(requiredConsecutiveTicks: 2) {
            proofCount += 1
        }

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)
        assertEqual(proofCount, 0)

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)
        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)

        assertEqual(proofCount, 1)
    }

    @MainActor
    func testAutoVerifierResetsWhenSignalDrops() {
        var proofCount = 0
        let verifier = SystemAudioAutoVerifier(requiredConsecutiveTicks: 2) {
            proofCount += 1
        }

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)
        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.0, microphonePeak: 0), recorderActive: true)
        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)
        assertEqual(proofCount, 0)

        verifier.observe(snapshot: SourceLevelMeterSnapshot(systemPeak: 0.004, microphonePeak: 0), recorderActive: true)
        assertEqual(proofCount, 1)
    }
}

private final class FakeMeterLiveMixerController: LiveMixerControlling {
    var supportsSelectedAppProcessRestore = false
    var sourceLevelSnapshot: SourceLevelMeterSnapshot?

    @MainActor func start(
        configuration: LiveMixerStartConfiguration,
        completion: @MainActor @escaping (LiveMixerStartResult) -> Void
    ) {
        _ = configuration
        completion(.started)
    }

    @MainActor func stop(completion: @MainActor @escaping () -> Void) {
        completion()
    }

    @MainActor func setAudioLevels(_ settings: AudioLevelSettings) {
        _ = settings
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        nil
    }

    @MainActor func currentSourceLevelSnapshot() -> SourceLevelMeterSnapshot? {
        sourceLevelSnapshot
    }

    @MainActor func isVirtualAudioDeviceRunning() -> Bool {
        false
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func assertAlmostEqual(
    _ actual: Float,
    _ expected: Float,
    tolerance: Float = 0.0001,
    file: StaticString = #file,
    line: UInt = #line
) {
    if abs(actual - expected) > tolerance {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
