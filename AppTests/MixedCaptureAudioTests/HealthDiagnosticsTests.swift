import Foundation
@testable import MixedCaptureAudio
import XCTest

final class HealthDiagnosticsTests: XCTestCase {

    func testCleanRunningSessionIsGood() {
        let summary = HealthDiagnosticSummary(snapshot: .cleanRunning)

        assertEqual(summary.severity, .good)
        assertEqual(summary.userVisibleFindings.count, 0)
        assertContains(summary.diagnosticsOnlyTerms.map(\.name), "Frames Mixed")
    }

    func testMicUnderrunIsDegradedAndUserVisible() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.micUnderrunFrames = 512

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Microphone Underrun")
        assertContains(summary.recommendedActions, "Keep recording if this was brief; check microphone connection if it repeats.")
    }

    func testSourceQueueDropsAreDegradedAndSeparateFromCallbackErrors() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.systemQueueDroppedFrames = 128
        snapshot.micQueueDroppedFrames = 64

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Source Queue Drops")
        assertContains(summary.recommendedActions, "Keep recording if this was brief; reduce system load if source queue drops repeat.")
        assertFalse(summary.userVisibleFindings.map(\.name).contains("Audio Callback Error"))
    }

    func testRecentHealthIgnoresCountersThatWereAlreadyPresentInsideWindow() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        var baseline = HealthSnapshot.cleanRunning
        baseline.micUnderrunFrames = 512
        _ = accumulator.record(
            snapshot: baseline,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        var latest = baseline
        latest.framesMixed += 48_000
        let summary = accumulator.record(
            snapshot: latest,
            at: Date(timeIntervalSinceReferenceDate: 11)
        )

        XCTAssertEqual(summary.severity, .healthy)
        XCTAssertEqual(summary.title, "Healthy")
        XCTAssertEqual(summary.detail, nil)
    }

    func testRecentHealthReportsNewMicUnderrunAsDegraded() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        _ = accumulator.record(
            snapshot: .cleanRunning,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        var latest = HealthSnapshot.cleanRunning
        latest.framesMixed += 48_000
        latest.micUnderrunFrames = 512
        let summary = accumulator.record(
            snapshot: latest,
            at: Date(timeIntervalSinceReferenceDate: 11)
        )

        XCTAssertEqual(summary.severity, .degraded)
        XCTAssertEqual(summary.title, "Degraded")
        XCTAssertEqual(summary.detail, "Microphone underrun")
    }

    func testRecentHealthReportsNewCallbackErrorAsFailed() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        _ = accumulator.record(
            snapshot: .cleanRunning,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        var latest = HealthSnapshot.cleanRunning
        latest.callbackErrorCount = 1
        let summary = accumulator.record(
            snapshot: latest,
            at: Date(timeIntervalSinceReferenceDate: 11)
        )

        XCTAssertEqual(summary.severity, .failed)
        XCTAssertEqual(summary.title, "Failed")
        XCTAssertEqual(summary.detail, "Audio callback error")
    }

    func testRecentHealthResetReportsNoActiveSession() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        _ = accumulator.record(
            snapshot: .cleanRunning,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        let summary = accumulator.reset()

        XCTAssertEqual(summary, .noActiveSession)
    }

    func testRecentHealthIgnoresSharedRingOverrunWhileWaitingForRecorder() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        _ = accumulator.record(
            snapshot: .cleanRunning,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        var latest = HealthSnapshot.cleanRunning
        latest.sharedRingFillFrames = 120_000
        latest.sharedRingFillErrorFrames = 96_000
        latest.sharedRingFillErrorAbsFrames = 96_000
        latest.sharedRingOverrunFrames = 91_200
        let summary = accumulator.record(
            snapshot: latest,
            at: Date(timeIntervalSinceReferenceDate: 11)
        )

        XCTAssertEqual(summary.severity, .healthy)
        XCTAssertEqual(summary.title, "Healthy")
    }

    func testRecentHealthIgnoresSharedRingOverrunWhenNoRecorderIsActive() {
        var accumulator = RecentHealthAccumulator(windowDuration: 5)
        _ = accumulator.record(
            snapshot: .cleanRunning,
            at: Date(timeIntervalSinceReferenceDate: 10),
            recorderActive: false
        )

        var latest = HealthSnapshot.cleanRunning
        latest.sharedRingFillFrames = 12_000
        latest.sharedRingFillErrorFrames = 9_600
        latest.sharedRingFillErrorAbsFrames = 9_600
        latest.sharedRingOverrunFrames = 91_200
        let summary = accumulator.record(
            snapshot: latest,
            at: Date(timeIntervalSinceReferenceDate: 11),
            recorderActive: false
        )

        XCTAssertEqual(summary.severity, .healthy)
        XCTAssertEqual(summary.title, "Healthy")
    }

    func testCallbackErrorsAreFailedAndUserVisible() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.callbackErrorCount = 1

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .failed)
        assertContains(summary.userVisibleFindings.map(\.name), "Audio Callback Error")
        assertContains(summary.recommendedActions, "Stop and restart the session.")
    }

    func testClippingIsDegradedButNotFailed() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.clippedSamples = 4

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Clipping")
        assertContains(summary.recommendedActions, "Lower microphone or system audio gain if clipping repeats.")
    }

    func testDriftCorrectionIsDiagnosticsOnlyWhenNoAudioWasLost() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.micDriftDropFrames = 336
        snapshot.micQueueFrames = 1_704
        snapshot.sourceFrameDelta = -1_704
        snapshot.sourceFrameDeltaAbs = 1_704

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .good)
        assertFalse(summary.userVisibleFindings.map(\.name).contains("Source Drift Correction"))
        assertContains(summary.diagnosticsOnlyTerms.map(\.name), "Source Drift Correction")
    }

    func testSharedRingFillIsDiagnosticsOnlyWhenNoFramesAreLost() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.sharedRingFillFrames = 2_404
        snapshot.sharedRingFillErrorFrames = 4
        snapshot.sharedRingFillErrorAbsFrames = 4

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .good)
        assertFalse(summary.userVisibleFindings.map(\.name).contains("Shared Ring Fill"))
        assertContains(summary.diagnosticsOnlyTerms.map(\.name), "Shared Ring Fill")
    }

    func testSharedRingOverrunIsDegradedAndUserVisible() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.sharedRingFillFrames = 4_804
        snapshot.sharedRingFillErrorFrames = 2_404
        snapshot.sharedRingFillErrorAbsFrames = 2_404
        snapshot.sharedRingOverrunFrames = 4

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Shared Ring Overrun")
        assertContains(summary.recommendedActions, "Keep recording if this was brief; restart the app if shared-ring overruns repeat.")
    }

    func testSharedRingAccumulatorIgnoresWarmupAndReportsPercentiles() {
        var accumulator = SharedRingStatsAccumulator(maxSamples: 5, warmupSamples: 2)

        for error in [999, -999, -48, 0, 96, 240, 480, 24] {
            accumulator.record(snapshot: snapshot(fill: 2_400 + error, error: error, overrun: 0), recorderActive: true)
        }

        let stats = accumulator.summary

        assertEqual(stats.sampleCount, 5)
        assertEqual(stats.status, .watch)
        assertEqual(stats.minErrorFrames, 0)
        assertEqual(stats.maxErrorFrames, 480)
        assertEqual(stats.maxAbsErrorFrames, 480)
        assertEqual(stats.p95AbsErrorFrames, 480)
        assertEqual(stats.p99AbsErrorFrames, 480)
        assertStringContains(stats.compactValue, "Watch")
        assertStringContains(stats.compactValue, "p99 10.0 ms")
    }

    func testSharedRingAccumulatorReportsOverrunsSinceBaseline() {
        var accumulator = SharedRingStatsAccumulator(maxSamples: 10, warmupSamples: 0)

        accumulator.record(snapshot: snapshot(fill: 2_400, error: 0, overrun: 10), recorderActive: true)
        accumulator.record(snapshot: snapshot(fill: 2_404, error: 4, overrun: 14), recorderActive: true)

        let stats = accumulator.summary

        assertEqual(stats.sampleCount, 2)
        assertEqual(stats.status, .overrun)
        assertEqual(stats.overrunFrames, 4)
        assertStringContains(stats.compactValue, "Overrun")
        assertStringContains(stats.compactValue, "overruns 4")
    }

    func testSharedRingAccumulatorReportsOverrunsOnlyWithinRollingWindow() {
        var accumulator = SharedRingStatsAccumulator(maxSamples: 3, warmupSamples: 0)

        for overrun in [1_000, 2_000, 3_000, 4_000, 5_000] {
            accumulator.record(
                snapshot: snapshot(fill: 2_404, error: 4, overrun: UInt64(overrun)),
                recorderActive: true
            )
        }

        let stats = accumulator.summary

        assertEqual(stats.sampleCount, 3)
        assertEqual(stats.overrunFrames, 2_000)
        assertStringContains(stats.compactValue, "overruns 2000")
    }

    func testSharedRingAccumulatorShowsRecorderActiveWhenFeedbackIsBlind() {
        var accumulator = SharedRingStatsAccumulator(maxSamples: 10, warmupSamples: 0)

        accumulator.record(snapshot: snapshot(fill: 4_800, error: 2_400, overrun: 0), recorderActive: true)
        accumulator.record(snapshot: snapshot(fill: 12_000, error: 9_600, overrun: 91_200), recorderActive: true)

        let stats = accumulator.summary

        assertEqual(stats.status, .recorderActive)
        assertStringContains(stats.compactValue, "Recorder Active")
        assertStringContains(stats.compactValue, "fill")
        assertFalse(stats.compactValue.contains("p99"))
    }

    func testSharedRingAccumulatorResetsRollingWindowWithoutRecorder() {
        var accumulator = SharedRingStatsAccumulator(maxSamples: 10, warmupSamples: 0)

        accumulator.record(snapshot: snapshot(fill: 2_404, error: 4, overrun: 0), recorderActive: true)
        accumulator.record(snapshot: snapshot(fill: 12_000, error: 9_600, overrun: 9_600), recorderActive: false)
        accumulator.record(snapshot: snapshot(fill: 12_000, error: 9_600, overrun: 19_200), recorderActive: false)

        let stats = accumulator.summary

        assertEqual(stats.status, .noRecorder)
        assertEqual(stats.sampleCount, 0)
        assertEqual(stats.overrunFrames, 0)
        assertStringContains(stats.compactValue, "No Recorder")
        assertFalse(stats.compactValue.contains("p99"))
    }

    func testDiagnosticReportIsMetadataOnly() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.framesMixed = 2_880_000
        snapshot.micDriftDropFrames = 336
        snapshot.sharedRingFillFrames = 2_404
        snapshot.sharedRingFillErrorFrames = 4

        let report = HealthDiagnosticSummary(snapshot: snapshot).metadataReportLines()

        assertStringContains(report, "severity=Good")
        assertStringContains(report, "frames_mixed=2880000")
        assertStringContains(report, "clipped_samples=0")
        assertStringContains(report, "mic_drift_drop_frames=336")
        assertStringContains(report, "shared_ring_fill_frames=2404")
        assertStringContains(report, "shared_ring_fill_error_frames=4")
        assertFalse(report.contains("clipped_frame_count"))
        assertFalse(report.contains("samples=["))
        assertFalse(report.contains("audio_buffer"))
        assertFalse(report.contains("transcript"))
    }

    private func snapshot(fill: Int, error: Int, overrun: UInt64) -> HealthSnapshot {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.sharedRingFillFrames = UInt32(clamping: fill)
        snapshot.sharedRingFillErrorFrames = Int32(clamping: error)
        snapshot.sharedRingFillErrorAbsFrames = UInt32(error.magnitude)
        snapshot.sharedRingOverrunFrames = overrun
        return snapshot
    }
}

extension HealthSnapshot {
    static var cleanRunning: HealthSnapshot {
        HealthSnapshot(
            framesMixed: 48_000,
            systemUnderrunFrames: 0,
            micUnderrunFrames: 0,
            clippedSamples: 0,
            systemQueueFrames: 0,
            micQueueFrames: 0,
            sourceFrameDelta: 0,
            sourceFrameDeltaAbs: 0,
            systemDriftDropFrames: 0,
            micDriftDropFrames: 0,
            callbackErrorCount: 0
        )
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func assertContains<S: Sequence>(_ values: S, _ expected: S.Element, file: StaticString = #file, line: UInt = #line) where S.Element: Equatable {
    if !values.contains(expected) {
        XCTFail("Expected sequence to contain \(expected)", file: file, line: line)
    }
}

private func assertStringContains(_ value: String, _ expected: String, file: StaticString = #file, line: UInt = #line) {
    if !value.contains(expected) {
        XCTFail("Expected string to contain \(expected)", file: file, line: line)
    }
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertFalse(condition, file: file, line: line)
}
