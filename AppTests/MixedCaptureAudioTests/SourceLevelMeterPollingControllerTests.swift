import Combine
import Foundation
@testable import MixedCaptureAudio
import XCTest

final class SourceLevelMeterPollingControllerTests: XCTestCase {

    @MainActor
    func testStartConnectsOnceAndStopCancels() {
        let scheduler = FakeMeterScheduler()
        let controller = SourceLevelMeterPollingController(
            refresh: {},
            makeCancellable: scheduler.makeCancellable
        )

        controller.start()
        controller.start()

        assertEqual(scheduler.cancellables.count, 1)
        assertEqual(controller.isRunning, true)

        controller.stop()

        assertEqual(scheduler.cancellables.first?.cancelCount, 1)
        assertEqual(controller.isRunning, false)
    }

    @MainActor
    func testTickRefreshesOnlyWhileStarted() {
        let scheduler = FakeMeterScheduler()
        var refreshCount = 0
        let controller = SourceLevelMeterPollingController(
            refresh: { refreshCount += 1 },
            makeCancellable: scheduler.makeCancellable
        )

        scheduler.tick()
        assertEqual(refreshCount, 0)

        controller.start()
        scheduler.tick()
        scheduler.tick()

        assertEqual(refreshCount, 2)

        controller.stop()
        scheduler.tick()

        assertEqual(refreshCount, 2)
    }
}

@MainActor
private final class FakeMeterScheduler {
    private var tickHandler: (() -> Void)?
    private(set) var cancellables: [FakeCancellable] = []

    func makeCancellable(_ tickHandler: @escaping () -> Void) -> AnyCancellable {
        self.tickHandler = tickHandler
        let cancellable = FakeCancellable { [weak self] in
            self?.tickHandler = nil
        }
        cancellables.append(cancellable)
        return AnyCancellable(cancellable)
    }

    func tick() {
        tickHandler?()
    }
}

private final class FakeCancellable: Cancellable {
    private let onCancel: () -> Void
    private(set) var cancelCount = 0

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        cancelCount += 1
        onCancel()
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
