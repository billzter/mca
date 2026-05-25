import Foundation

@main
struct HealthDiagnosticsTests {
    static func main() {
        testCleanRunningSessionIsGood()
        testMicUnderrunIsDegradedAndUserVisible()
        testCallbackErrorsAreFailedAndUserVisible()
        testClippingIsDegradedButNotFailed()
        testDriftCorrectionIsDiagnosticsOnlyWhenNoAudioWasLost()
        testDiagnosticReportIsMetadataOnly()
        print("health diagnostics tests passed")
    }

    private static func testCleanRunningSessionIsGood() {
        let summary = HealthDiagnosticSummary(snapshot: .cleanRunning)

        assertEqual(summary.severity, .good)
        assertEqual(summary.userVisibleFindings.count, 0)
        assertContains(summary.diagnosticsOnlyTerms.map(\.name), "Frames Mixed")
    }

    private static func testMicUnderrunIsDegradedAndUserVisible() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.micUnderrunFrames = 512

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Microphone Underrun")
        assertContains(summary.recommendedActions, "Keep recording if this was brief; check microphone connection if it repeats.")
    }

    private static func testCallbackErrorsAreFailedAndUserVisible() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.callbackErrorCount = 1

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .failed)
        assertContains(summary.userVisibleFindings.map(\.name), "Audio Callback Error")
        assertContains(summary.recommendedActions, "Stop and restart the session.")
    }

    private static func testClippingIsDegradedButNotFailed() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.clippedSamples = 4

        let summary = HealthDiagnosticSummary(snapshot: snapshot)

        assertEqual(summary.severity, .degraded)
        assertContains(summary.userVisibleFindings.map(\.name), "Clipping")
        assertContains(summary.recommendedActions, "Lower microphone or system audio gain if clipping repeats.")
    }

    private static func testDriftCorrectionIsDiagnosticsOnlyWhenNoAudioWasLost() {
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

    private static func testDiagnosticReportIsMetadataOnly() {
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.framesMixed = 2_880_000
        snapshot.micDriftDropFrames = 336

        let report = HealthDiagnosticSummary(snapshot: snapshot).metadataReportLines()

        assertStringContains(report, "severity=Good")
        assertStringContains(report, "frames_mixed=2880000")
        assertStringContains(report, "clipped_samples=0")
        assertStringContains(report, "mic_drift_drop_frames=336")
        assertFalse(report.contains("clipped_frame_count"))
        assertFalse(report.contains("samples=["))
        assertFalse(report.contains("audio_buffer"))
        assertFalse(report.contains("transcript"))
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
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func assertContains<S: Sequence>(_ values: S, _ expected: S.Element, file: StaticString = #file, line: UInt = #line) where S.Element: Equatable {
    if !values.contains(expected) {
        fatalError("Expected sequence to contain \(expected)", file: file, line: line)
    }
}

private func assertStringContains(_ value: String, _ expected: String, file: StaticString = #file, line: UInt = #line) {
    if !value.contains(expected) {
        fatalError("Expected string to contain \(expected)", file: file, line: line)
    }
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if condition {
        fatalError("Expected false", file: file, line: line)
    }
}
