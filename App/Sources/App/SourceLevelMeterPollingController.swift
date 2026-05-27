import Combine
import Foundation

@MainActor
final class SourceLevelMeterPollingController {
    typealias MakeCancellable = @MainActor (@escaping () -> Void) -> AnyCancellable

    private let refresh: () -> Void
    private let makeCancellable: MakeCancellable
    private var cancellable: AnyCancellable?

    init(
        refresh: @escaping () -> Void,
        makeCancellable: MakeCancellable? = nil
    ) {
        self.refresh = refresh
        self.makeCancellable = makeCancellable ?? { refresh in
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    refresh()
                }
        }
    }

    var isRunning: Bool {
        cancellable != nil
    }

    func start() {
        guard cancellable == nil else {
            return
        }
        cancellable = makeCancellable(refresh)
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
