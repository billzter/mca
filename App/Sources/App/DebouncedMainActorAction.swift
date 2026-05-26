import Foundation

@MainActor
final class DebouncedMainActorAction {
    private let delayNanoseconds: UInt64
    private let sleep: (UInt64) async -> Void
    private let action: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        delayNanoseconds: UInt64 = 500_000_000,
        sleep: @escaping (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        action: @escaping @MainActor () -> Void
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.sleep = sleep
        self.action = action
    }

    func schedule() {
        task?.cancel()
        let delayNanoseconds = delayNanoseconds
        let sleep = sleep
        let action = action
        task = Task { @MainActor in
            await sleep(delayNanoseconds)
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
