import Combine
import Foundation

@MainActor
final class SourceLevelMeterModel: ObservableObject {
    private let liveMixerController: LiveMixerControlling
    private let isMixerRunning: () -> Bool
    private let onRawSnapshot: (SourceLevelMeterSnapshot) -> Void

    @Published private(set) var snapshot: SourceLevelMeterSnapshot = .empty

    init(
        liveMixerController: LiveMixerControlling,
        isMixerRunning: @escaping () -> Bool,
        onRawSnapshot: @escaping (SourceLevelMeterSnapshot) -> Void = { _ in }
    ) {
        self.liveMixerController = liveMixerController
        self.isMixerRunning = isMixerRunning
        self.onRawSnapshot = onRawSnapshot
    }

    func refresh() {
        guard isMixerRunning(),
              let nextSnapshot = liveMixerController.currentSourceLevelSnapshot()
        else {
            if snapshot != .empty {
                snapshot = .empty
            }
            return
        }

        onRawSnapshot(nextSnapshot)
        let decayedSnapshot = snapshot.decayed(toward: nextSnapshot)
        if decayedSnapshot != snapshot {
            snapshot = decayedSnapshot
        }
    }
}

@MainActor
final class SystemAudioAutoVerifier {
    private let systemPeakThreshold: Float
    private let requiredConsecutiveTicks: Int
    private let onVerified: () -> Void
    private var consecutiveTicks = 0
    private var hasVerified = false

    init(
        systemPeakThreshold: Float = 0.0031622776,
        requiredConsecutiveTicks: Int = 8,
        onVerified: @escaping () -> Void
    ) {
        self.systemPeakThreshold = max(0.0, systemPeakThreshold)
        self.requiredConsecutiveTicks = max(1, requiredConsecutiveTicks)
        self.onVerified = onVerified
    }

    func observe(snapshot: SourceLevelMeterSnapshot, recorderActive: Bool) {
        guard !hasVerified else {
            return
        }
        guard recorderActive, snapshot.systemPeak >= systemPeakThreshold else {
            consecutiveTicks = 0
            return
        }

        consecutiveTicks += 1
        if consecutiveTicks >= requiredConsecutiveTicks {
            hasVerified = true
            onVerified()
        }
    }
}
