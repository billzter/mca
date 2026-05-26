import Foundation

@MainActor
@main
struct DebouncedMainActorActionTests {
    static func main() async {
        await testRepeatedSchedulesCoalesceIntoOneTrailingAction()
        print("debounced main actor action tests passed")
    }

    private static func testRepeatedSchedulesCoalesceIntoOneTrailingAction() async {
        var fireCount = 0
        let sleeper = ManualSleeper()
        let debouncedAction = DebouncedMainActorAction(
            delayNanoseconds: 20_000_000,
            sleep: sleeper.sleep
        ) {
            fireCount += 1
        }

        debouncedAction.schedule()
        debouncedAction.schedule()
        debouncedAction.schedule()

        await waitUntil { sleeper.pendingCount == 3 }
        sleeper.resumeAll()
        await waitUntil { fireCount == 1 }
        assertEqual(fireCount, 1)
    }
}

@MainActor
private final class ManualSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func sleep(nanoseconds: UInt64) async {
        _ = nanoseconds
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        let continuations = continuations
        self.continuations.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #file,
    line: UInt = #line
) async {
    for _ in 0..<100 {
        if await condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    fatalError("Timed out waiting for condition", file: file, line: line)
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
