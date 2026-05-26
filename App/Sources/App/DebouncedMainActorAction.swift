import Foundation

@MainActor
final class DebouncedMainActorAction {
    private let delayNanoseconds: UInt64
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        delayNanoseconds: UInt64 = 500_000_000,
        action: @escaping @MainActor () -> Void
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.action = action
    }

    func schedule() {
        task?.cancel()
        let delayNanoseconds = delayNanoseconds
        let action = action
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
