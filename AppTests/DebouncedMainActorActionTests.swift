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
        let debouncedAction = DebouncedMainActorAction(delayNanoseconds: 20_000_000) {
            fireCount += 1
        }

        debouncedAction.schedule()
        debouncedAction.schedule()
        debouncedAction.schedule()
        try? await Task.sleep(nanoseconds: 60_000_000)

        assertEqual(fireCount, 1)
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
