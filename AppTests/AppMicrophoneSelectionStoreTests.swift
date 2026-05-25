import Foundation

@main
struct AppMicrophoneSelectionStoreTests {
    static func main() {
        testPriorityOrderDoesNotOverwriteSelectedMicrophone()
        testLegacySelectedMicrophoneSeedsPriorityWhenPriorityIsMissing()
        testAppAudioSelectionPersistsModeAndBundleIDs()
        print("microphone selection store tests passed")
    }

    private static func testPriorityOrderDoesNotOverwriteSelectedMicrophone() {
        let defaults = isolatedDefaults()
        let store = AppMicrophoneSelectionStore(defaults: defaults)

        store.selectedMicrophoneID = "built-in"
        store.preferredMicrophoneIDs = ["usb", "built-in"]
        store.preferredMicrophoneIDs = ["teams", "usb", "built-in"]

        assertEqual(store.selectedMicrophoneID, "built-in")
        assertEqual(store.preferredMicrophoneIDs, ["teams", "usb", "built-in"])
    }

    private static func testLegacySelectedMicrophoneSeedsPriorityWhenPriorityIsMissing() {
        let defaults = isolatedDefaults()
        let store = AppMicrophoneSelectionStore(defaults: defaults)

        store.selectedMicrophoneID = "usb"

        assertEqual(store.preferredMicrophoneIDs, ["usb"])
    }

    private static func testAppAudioSelectionPersistsModeAndBundleIDs() {
        let defaults = isolatedDefaults()
        let store = AppAudioSelectionStore(defaults: defaults)

        store.captureMode = .selectedApps
        store.selectedAppBundleIDs = ["com.apple.Music", "com.tinyspeck.slackmacgap"]

        let reloaded = AppAudioSelectionStore(defaults: defaults)

        assertEqual(reloaded.captureMode, .selectedApps)
        assertEqual(reloaded.selectedAppBundleIDs, ["com.apple.Music", "com.tinyspeck.slackmacgap"])
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.minamiktr.mca.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
