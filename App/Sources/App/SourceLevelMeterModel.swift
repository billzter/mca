import Combine
import Foundation

@MainActor
final class SourceLevelMeterModel: ObservableObject {
    private let liveMixerController: LiveMixerControlling
    private let isMixerRunning: () -> Bool

    @Published private(set) var snapshot: SourceLevelMeterSnapshot = .empty

    init(
        liveMixerController: LiveMixerControlling,
        isMixerRunning: @escaping () -> Bool
    ) {
        self.liveMixerController = liveMixerController
        self.isMixerRunning = isMixerRunning
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

        let decayedSnapshot = snapshot.decayed(toward: nextSnapshot)
        if decayedSnapshot != snapshot {
            snapshot = decayedSnapshot
        }
    }
}
