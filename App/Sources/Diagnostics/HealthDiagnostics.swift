import Foundation

enum HealthSeverity: String, Equatable {
    case good = "Good"
    case degraded = "Degraded"
    case failed = "Failed"
}

struct HealthSnapshot: Equatable {
    var framesMixed: UInt64
    var systemUnderrunFrames: UInt64
    var micUnderrunFrames: UInt64
    var clippedSamples: UInt64
    var systemQueueFrames: UInt32
    var micQueueFrames: UInt32
    var sourceFrameDelta: Int32
    var sourceFrameDeltaAbs: UInt32
    var systemDriftDropFrames: UInt64
    var micDriftDropFrames: UInt64
    var callbackErrorCount: UInt64
}

struct DiagnosticTerm: Equatable, Identifiable {
    enum Visibility: Equatable {
        case userVisible
        case diagnosticsOnly
    }

    let id: String
    let name: String
    let value: String
    let explanation: String
    let visibility: Visibility
}

struct HealthDiagnosticSummary: Equatable {
    let severity: HealthSeverity
    let snapshot: HealthSnapshot
    let userVisibleFindings: [DiagnosticTerm]
    let diagnosticsOnlyTerms: [DiagnosticTerm]
    let recommendedActions: [String]

    init(snapshot: HealthSnapshot) {
        var userVisibleFindings: [DiagnosticTerm] = []
        var diagnosticsOnlyTerms: [DiagnosticTerm] = [
            DiagnosticTerm(
                id: "frames_mixed",
                name: "Frames Mixed",
                value: "\(snapshot.framesMixed)",
                explanation: "Total output frames produced by the Rust mixer for the current or most recent session.",
                visibility: .diagnosticsOnly
            ),
            DiagnosticTerm(
                id: "source_queue_delta",
                name: "Source Queue Delta",
                value: "\(snapshot.sourceFrameDelta)",
                explanation: "Difference between queued system-audio frames and queued microphone frames.",
                visibility: .diagnosticsOnly
            ),
        ]
        var recommendedActions: [String] = []

        if snapshot.systemUnderrunFrames > 0 {
            userVisibleFindings.append(
                DiagnosticTerm(
                    id: "system_underrun_frames",
                    name: "System Audio Underrun",
                    value: "\(snapshot.systemUnderrunFrames)",
                    explanation: "The mixer had to use silence for missing system-audio frames.",
                    visibility: .userVisible
                )
            )
            recommendedActions.append("Keep recording if this was brief; check system audio access if it repeats.")
        }

        if snapshot.micUnderrunFrames > 0 {
            userVisibleFindings.append(
                DiagnosticTerm(
                    id: "mic_underrun_frames",
                    name: "Microphone Underrun",
                    value: "\(snapshot.micUnderrunFrames)",
                    explanation: "The mixer had to use silence for missing microphone frames.",
                    visibility: .userVisible
                )
            )
            recommendedActions.append("Keep recording if this was brief; check microphone connection if it repeats.")
        }

        if snapshot.clippedSamples > 0 {
            userVisibleFindings.append(
                DiagnosticTerm(
                    id: "clipped_samples",
                    name: "Clipping",
                    value: "\(snapshot.clippedSamples)",
                    explanation: "Some mixed samples exceeded the safe output range and were clamped.",
                    visibility: .userVisible
                )
            )
            recommendedActions.append("Lower microphone or system audio gain if clipping repeats.")
        }

        if snapshot.systemDriftDropFrames > 0 || snapshot.micDriftDropFrames > 0 {
            diagnosticsOnlyTerms.append(
                DiagnosticTerm(
                    id: "source_drift_correction",
                    name: "Source Drift Correction",
                    value: "system=\(snapshot.systemDriftDropFrames), mic=\(snapshot.micDriftDropFrames)",
                    explanation: "Frames trimmed from a leading source to keep system audio and microphone queues aligned.",
                    visibility: .diagnosticsOnly
                )
            )
        }

        diagnosticsOnlyTerms.append(
            DiagnosticTerm(
                id: "queue_frames",
                name: "Queued Frames",
                value: "system=\(snapshot.systemQueueFrames), mic=\(snapshot.micQueueFrames)",
                explanation: "Current queued source frames waiting to be mixed.",
                visibility: .diagnosticsOnly
            )
        )

        if snapshot.callbackErrorCount > 0 {
            userVisibleFindings.append(
                DiagnosticTerm(
                    id: "callback_error_count",
                    name: "Audio Callback Error",
                    value: "\(snapshot.callbackErrorCount)",
                    explanation: "An audio callback or callback-adjacent path rejected data or failed validation.",
                    visibility: .userVisible
                )
            )
            recommendedActions.append("Stop and restart the session.")
        }

        let severity: HealthSeverity
        if snapshot.callbackErrorCount > 0 {
            severity = .failed
        } else if snapshot.systemUnderrunFrames > 0 ||
            snapshot.micUnderrunFrames > 0 ||
            snapshot.clippedSamples > 0
        {
            severity = .degraded
        } else {
            severity = .good
        }

        self.severity = severity
        self.snapshot = snapshot
        self.userVisibleFindings = userVisibleFindings
        self.diagnosticsOnlyTerms = diagnosticsOnlyTerms
        self.recommendedActions = Array(Set(recommendedActions)).sorted()
    }

    func metadataReportLines() -> String {
        let allTerms = userVisibleFindings + diagnosticsOnlyTerms
        let termLines = allTerms
            .sorted { $0.id < $1.id }
            .map { "\($0.id)=\($0.value)" }
        let counterLines = [
            "frames_mixed=\(snapshot.framesMixed)",
            "system_underrun_frames=\(snapshot.systemUnderrunFrames)",
            "mic_underrun_frames=\(snapshot.micUnderrunFrames)",
            "clipped_samples=\(snapshot.clippedSamples)",
            "system_queue_frames=\(snapshot.systemQueueFrames)",
            "mic_queue_frames=\(snapshot.micQueueFrames)",
            "source_frame_delta=\(snapshot.sourceFrameDelta)",
            "source_frame_delta_abs=\(snapshot.sourceFrameDeltaAbs)",
            "system_drift_drop_frames=\(snapshot.systemDriftDropFrames)",
            "mic_drift_drop_frames=\(snapshot.micDriftDropFrames)",
            "callback_error_count=\(snapshot.callbackErrorCount)",
        ]
        return (["severity=\(severity.rawValue)"] + counterLines + termLines).joined(separator: "\n")
    }
}
