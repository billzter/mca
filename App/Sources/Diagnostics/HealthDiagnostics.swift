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
    var sharedRingFillFrames: UInt32 = 0
    var sharedRingFillErrorFrames: Int32 = 0
    var sharedRingFillErrorAbsFrames: UInt32 = 0
    var sharedRingOverrunFrames: UInt64 = 0
}

enum SharedRingStabilityStatus: String, Equatable {
    case noRecorder = "No Recorder"
    case warmingUp = "Warming Up"
    case stable = "Stable"
    case watch = "Watch"
    case overrun = "Overrun"
    case waitingForRecorder = "Waiting for Recorder"
    case recorderActive = "Recorder Active"
}

struct SharedRingStats: Equatable {
    static let targetFillFrames: UInt32 = 2_400
    static let empty = SharedRingStats(
        sampleCount: 0,
        status: .warmingUp,
        currentFillFrames: 0,
        currentErrorFrames: 0,
        minErrorFrames: 0,
        maxErrorFrames: 0,
        meanErrorFrames: 0,
        maxAbsErrorFrames: 0,
        p95AbsErrorFrames: 0,
        p99AbsErrorFrames: 0,
        overrunFrames: 0
    )

    var sampleCount: Int
    var status: SharedRingStabilityStatus
    var currentFillFrames: UInt32
    var currentErrorFrames: Int32
    var minErrorFrames: Int32
    var maxErrorFrames: Int32
    var meanErrorFrames: Double
    var maxAbsErrorFrames: UInt32
    var p95AbsErrorFrames: UInt32
    var p99AbsErrorFrames: UInt32
    var overrunFrames: UInt64

    var compactValue: String {
        if status == .noRecorder || status == .waitingForRecorder || status == .recorderActive {
            return "\(status.rawValue)   fill \(Self.msString(currentFillFrames))"
        }
        return "\(status.rawValue)   p99 \(Self.msString(p99AbsErrorFrames))   max \(Self.msString(maxAbsErrorFrames))   overruns \(overrunFrames)"
    }

    var currentFillValue: String {
        "\(currentFillFrames) frames / \(Self.msString(currentFillFrames))"
    }

    var currentErrorValue: String {
        "\(currentErrorFrames) frames / \(Self.signedMsString(currentErrorFrames))"
    }

    static func msString(_ frames: UInt32) -> String {
        String(format: "%.1f ms", Double(frames) / 48.0)
    }

    static func signedMsString(_ frames: Int32) -> String {
        let milliseconds = Double(frames) / 48.0
        return String(format: "%+.1f ms", milliseconds)
    }
}

struct SharedRingStatsAccumulator {
    private let maxSamples: Int
    private let warmupSamples: Int
    private var seenSamples = 0
    private var fillErrors: [Int32] = []
    private var overrunSamples: [UInt64] = []
    private var currentFillFrames: UInt32 = 0
    private var currentErrorFrames: Int32 = 0
    private var latestOverrunFrames: UInt64 = 0

    private(set) var summary: SharedRingStats = .empty

    init(maxSamples: Int = 600, warmupSamples: Int = 5) {
        self.maxSamples = max(1, maxSamples)
        self.warmupSamples = max(0, warmupSamples)
    }

    mutating func record(snapshot: HealthSnapshot, recorderActive: Bool = false) {
        if !recorderActive {
            resetForNoRecorder(snapshot: snapshot)
            return
        }

        seenSamples += 1
        guard seenSamples > warmupSamples else {
            summary = .empty
            return
        }

        currentFillFrames = snapshot.sharedRingFillFrames
        currentErrorFrames = snapshot.sharedRingFillErrorFrames
        latestOverrunFrames = snapshot.sharedRingOverrunFrames

        fillErrors.append(snapshot.sharedRingFillErrorFrames)
        overrunSamples.append(snapshot.sharedRingOverrunFrames)
        if fillErrors.count > maxSamples {
            fillErrors.removeFirst(fillErrors.count - maxSamples)
            overrunSamples.removeFirst(overrunSamples.count - maxSamples)
        }
        recomputeSummary(recorderActive: recorderActive)
    }

    mutating func reset() {
        seenSamples = 0
        fillErrors.removeAll(keepingCapacity: true)
        overrunSamples.removeAll(keepingCapacity: true)
        currentFillFrames = 0
        currentErrorFrames = 0
        latestOverrunFrames = 0
        summary = .empty
    }

    private mutating func resetForNoRecorder(snapshot: HealthSnapshot) {
        seenSamples = 0
        fillErrors.removeAll(keepingCapacity: true)
        overrunSamples.removeAll(keepingCapacity: true)
        currentFillFrames = snapshot.sharedRingFillFrames
        currentErrorFrames = snapshot.sharedRingFillErrorFrames
        latestOverrunFrames = snapshot.sharedRingOverrunFrames
        summary = SharedRingStats(
            sampleCount: 0,
            status: .noRecorder,
            currentFillFrames: currentFillFrames,
            currentErrorFrames: currentErrorFrames,
            minErrorFrames: 0,
            maxErrorFrames: 0,
            meanErrorFrames: 0,
            maxAbsErrorFrames: 0,
            p95AbsErrorFrames: 0,
            p99AbsErrorFrames: 0,
            overrunFrames: 0
        )
    }

    private mutating func recomputeSummary(recorderActive: Bool) {
        guard !fillErrors.isEmpty else {
            summary = .empty
            return
        }

        var minError = Int32.max
        var maxError = Int32.min
        var sum = 0
        var absoluteErrors: [UInt32] = []
        absoluteErrors.reserveCapacity(fillErrors.count)
        for error in fillErrors {
            minError = min(minError, error)
            maxError = max(maxError, error)
            sum += Int(error)
            absoluteErrors.append(UInt32(error.magnitude))
        }
        absoluteErrors.sort()

        let p95 = percentileNearestRank(absoluteErrors, percentile: 95)
        let p99 = percentileNearestRank(absoluteErrors, percentile: 99)
        let maxAbs = absoluteErrors.last ?? 0
        let overrunDelta = latestOverrunFrames.saturatingSubtract(overrunSamples.first ?? latestOverrunFrames)
        let status: SharedRingStabilityStatus
        if overrunDelta > 0 && recorderActive && maxAbs >= 9_600 {
            status = .recorderActive
        } else if overrunDelta > 0 && maxAbs > 48_000 {
            status = .waitingForRecorder
        } else if overrunDelta > 0 {
            status = .overrun
        } else if p99 > 240 || maxAbs > 480 {
            status = .watch
        } else {
            status = .stable
        }

        summary = SharedRingStats(
            sampleCount: fillErrors.count,
            status: status,
            currentFillFrames: currentFillFrames,
            currentErrorFrames: currentErrorFrames,
            minErrorFrames: minError,
            maxErrorFrames: maxError,
            meanErrorFrames: Double(sum) / Double(fillErrors.count),
            maxAbsErrorFrames: maxAbs,
            p95AbsErrorFrames: p95,
            p99AbsErrorFrames: p99,
            overrunFrames: overrunDelta
        )
    }
}

private func percentileNearestRank(_ sortedValues: [UInt32], percentile: Int) -> UInt32 {
    guard !sortedValues.isEmpty else {
        return 0
    }
    let rank = max(1, (sortedValues.count * percentile + 99) / 100)
    return sortedValues[min(rank - 1, sortedValues.count - 1)]
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
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
                id: "shared_ring_fill",
                name: "Shared Ring Fill",
                value: "fill=\(snapshot.sharedRingFillFrames), error=\(snapshot.sharedRingFillErrorFrames)",
                explanation: "Producer-to-HAL shared-ring fill relative to the fixed target latency.",
                visibility: .diagnosticsOnly
            )
        )

        let waitingForRecorder = snapshot.sharedRingOverrunFrames > 0 &&
            snapshot.sharedRingFillErrorAbsFrames > 48_000

        if snapshot.sharedRingOverrunFrames > 0 && !waitingForRecorder {
            userVisibleFindings.append(
                DiagnosticTerm(
                    id: "shared_ring_overrun_frames",
                    name: "Shared Ring Overrun",
                    value: "\(snapshot.sharedRingOverrunFrames)",
                    explanation: "The producer lapped the HAL reader and overwrote unread shared-ring frames.",
                    visibility: .userVisible
                )
            )
            recommendedActions.append("Keep recording if this was brief; restart the app if shared-ring overruns repeat.")
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
            snapshot.clippedSamples > 0 ||
            (snapshot.sharedRingOverrunFrames > 0 && !waitingForRecorder)
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
            "shared_ring_fill_frames=\(snapshot.sharedRingFillFrames)",
            "shared_ring_fill_error_frames=\(snapshot.sharedRingFillErrorFrames)",
            "shared_ring_fill_error_abs_frames=\(snapshot.sharedRingFillErrorAbsFrames)",
            "shared_ring_overrun_frames=\(snapshot.sharedRingOverrunFrames)",
        ]
        return (["severity=\(severity.rawValue)"] + counterLines + termLines).joined(separator: "\n")
    }
}
