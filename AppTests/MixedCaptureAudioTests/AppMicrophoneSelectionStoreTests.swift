import Foundation
@testable import MixedCaptureAudio
import XCTest

final class AppMicrophoneSelectionStoreTests: XCTestCase {

    func testPriorityOrderDoesNotOverwriteSelectedMicrophone() {
        let defaults = isolatedDefaults()
        let store = AppMicrophoneSelectionStore(defaults: defaults)

        store.selectedMicrophoneID = "built-in"
        store.preferredMicrophoneIDs = ["usb", "built-in"]
        store.preferredMicrophoneIDs = ["teams", "usb", "built-in"]

        assertEqual(store.selectedMicrophoneID, "built-in")
        assertEqual(store.preferredMicrophoneIDs, ["teams", "usb", "built-in"])
    }

    func testLegacySelectedMicrophoneSeedsPriorityWhenPriorityIsMissing() {
        let defaults = isolatedDefaults()
        let store = AppMicrophoneSelectionStore(defaults: defaults)

        store.selectedMicrophoneID = "usb"

        assertEqual(store.preferredMicrophoneIDs, ["usb"])
    }

    func testAppAudioSelectionPersistsModeAndBundleIDs() {
        let defaults = isolatedDefaults()
        let store = AppAudioSelectionStore(defaults: defaults)

        store.captureMode = .selectedApps
        store.selectedAppBundleIDs = ["com.apple.Music", "com.tinyspeck.slackmacgap"]

        let reloaded = AppAudioSelectionStore(defaults: defaults)

        assertEqual(reloaded.captureMode, .selectedApps)
        assertEqual(reloaded.selectedAppBundleIDs, ["com.apple.Music", "com.tinyspeck.slackmacgap"])
    }

    func testAudioLevelSettingsPersistClampedDecibels() {
        let defaults = isolatedDefaults()
        let store = AppAudioLevelSettingsStore(defaults: defaults)

        store.settings = AudioLevelSettings(
            systemDecibels: -40.0,
            microphoneDecibels: 18.0,
            enhanceVoice: false
        )

        let reloaded = AppAudioLevelSettingsStore(defaults: defaults)
        assertEqual(reloaded.settings.systemDecibels, AudioLevelSettings.minimumDecibels)
        assertEqual(reloaded.settings.microphoneDecibels, AudioLevelSettings.maximumDecibels)
        assertEqual(reloaded.settings.enhanceVoice, false)
        assertEqual(reloaded.settings.systemGain, Float(pow(10.0, AudioLevelSettings.minimumDecibels / 20.0)))
        assertEqual(reloaded.settings.microphoneGain, Float(pow(10.0, AudioLevelSettings.maximumDecibels / 20.0)))
    }

    private func isolatedDefaults() -> UserDefaults {
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
