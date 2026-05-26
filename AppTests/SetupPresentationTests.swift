import Foundation

@main
struct SetupPresentationTests {
    static func main() {
        testSuccessfulStatusesAreComplete()
        testIncompleteStatusesRemainIncomplete()
        testUserFacingStatusLabelsAreFriendly()
        testReopenAfterSetupPresentationSuppressesDefaultWindow()
        print("setup presentation tests passed")
    }

    private static func testSuccessfulStatusesAreComplete() {
        let completeStatuses = [
            AudioDeviceStatus.installed.rawValue,
            PermissionStatus.granted.rawValue,
            SystemAudioAccessStatus.receivingAudio.rawValue,
            SelectedDeviceStatus.available.rawValue,
            QuickTimeDeviceStatus.visible.rawValue,
        ]

        for status in completeStatuses {
            assertTrue(SetupStepPresentation(status: status).isComplete)
        }
    }

    private static func testIncompleteStatusesRemainIncomplete() {
        let incompleteStatuses = [
            AudioDeviceStatus.installedButNeedsReload.rawValue,
            PermissionStatus.denied.rawValue,
            SystemAudioAccessStatus.silent.rawValue,
            SelectedDeviceStatus.missing.rawValue,
            QuickTimeDeviceStatus.notVisible.rawValue,
        ]

        for status in incompleteStatuses {
            assertFalse(SetupStepPresentation(status: status).isComplete)
        }
    }

    private static func testUserFacingStatusLabelsAreFriendly() {
        let cases = [
            (SystemAudioAccessStatus.receivingAudio.rawValue, "Receiving audio"),
            (SystemAudioAccessStatus.notTested.rawValue, "Not checked"),
            (SystemAudioAccessStatus.deniedOrUnavailable.rawValue, "Needs permission"),
            (AudioDeviceStatus.installedButNeedsReload.rawValue, "Restart required"),
            (AudioDeviceStatus.incompatible.rawValue, "Needs update"),
            (PermissionStatus.notDetermined.rawValue, "Needs approval"),
            (QuickTimeDeviceStatus.notVisible.rawValue, "Not visible"),
        ]

        for (status, expected) in cases {
            assertEqual(SetupStepPresentation(status: status).displayStatus, expected)
        }
    }

    private static func testReopenAfterSetupPresentationSuppressesDefaultWindow() {
        assertFalse(SetupWindowReopenPolicy.shouldAllowSystemDefaultWindowCreation)
    }
}

private func assertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("Expected true", file: file, line: line)
    }
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if condition {
        fatalError("Expected false", file: file, line: line)
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
