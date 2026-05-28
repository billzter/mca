import Foundation
@testable import MixedCaptureAudio
import XCTest

final class PrerequisiteStatusTests: XCTestCase {

    func testMissingDriverBlocksDeviceVisibility() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: false,
                mixedCaptureDeviceVisible: false,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .missing)
        assertEqual(snapshot.driverUpdateRequirement, .installDriver)
        assertEqual(snapshot.quickTimeDeviceStatus, .notVisible)
    }

    func testInstalledButNotVisibleNeedsReload() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                mixedCaptureDeviceVisible: false,
                microphoneAuthorization: .notDetermined,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .installedButNeedsReload)
        assertEqual(snapshot.driverUpdateRequirement, .reloadCoreAudio)
        assertEqual(snapshot.quickTimeDeviceStatus, .notVisible)
        assertEqual(snapshot.microphonePermission, .notDetermined)
    }

    func testVisibleDriverIsInstalledAndQuickTimeVisible() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .installed)
        assertEqual(snapshot.driverUpdateRequirement, .none)
        assertEqual(snapshot.quickTimeDeviceStatus, .visible)
        assertEqual(snapshot.selectedMicStatus, .available)
    }

    func testCompatibleBundleWithOldLoadedDriverNeedsCoreAudioReload() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                installedDriverCompatibility: .init(
                    driverCompatibilityVersion: 1,
                    sharedMemoryABIVersion: 1
                ),
                loadedDriverCompatibility: .init(
                    driverCompatibilityVersion: 0,
                    sharedMemoryABIVersion: 1
                ),
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .installedButNeedsReload)
        assertEqual(snapshot.driverUpdateRequirement, .reloadCoreAudio)
        assertEqual(snapshot.quickTimeDeviceStatus, .visible)
    }

    func testIncompatibleInstalledBundleNeedsDriverUpdate() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                installedDriverCompatibility: .init(
                    driverCompatibilityVersion: 0,
                    sharedMemoryABIVersion: 1
                ),
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .incompatible)
        assertEqual(snapshot.driverUpdateRequirement, .updateDriver)
        assertEqual(snapshot.quickTimeDeviceStatus, .visible)
    }

    func testLoadedDriverWithoutCompatibilityMetadataNeedsCoreAudioReload() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                installedDriverCompatibility: .init(
                    driverCompatibilityVersion: 1,
                    sharedMemoryABIVersion: 1
                ),
                loadedDriverCompatibility: nil,
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )

        assertEqual(snapshot.driverStatus, .installedButNeedsReload)
        assertEqual(snapshot.driverUpdateRequirement, .reloadCoreAudio)
        assertEqual(snapshot.quickTimeDeviceStatus, .visible)
    }

    func testLoadedDriverCompatibilityCanComeFromModelUID() {
        let metadata = DriverCompatibilityMetadata.loadedDeviceMetadata(
            customMetadata: nil,
            modelUID: DriverCompatibilityMetadata.expectedModelUID
        )

        assertEqual(metadata, .expected)
    }

    func testMicPermissionMappings() {
        let resolver = PrerequisiteStatusResolver()
        let cases: [(MicrophoneAuthorizationState, PermissionStatus)] = [
            (.unknown, .unknown),
            (.notDetermined, .notDetermined),
            (.granted, .granted),
            (.denied, .denied),
            (.restricted, .restricted),
            (.failed, .failed),
        ]

        for (input, expected) in cases {
            let snapshot = resolver.resolve(
                inputs: PrerequisiteInputs(
                    driverBundleExists: true,
                    mixedCaptureDeviceVisible: true,
                    microphoneAuthorization: input,
                    defaultMicrophoneAvailable: true
                )
            )
            assertEqual(snapshot.microphonePermission, expected)
        }
    }

    func testSelectedMicAvailabilityMappings() {
        let resolver = PrerequisiteStatusResolver()

        let available = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true
            )
        )
        assertEqual(available.selectedMicStatus, .available)

        let missing = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                mixedCaptureDeviceVisible: true,
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: false
            )
        )
        assertEqual(missing.selectedMicStatus, .missing)
    }

    func testDeviceNamesAreIncludedWhenAvailable() {
        let resolver = PrerequisiteStatusResolver()
        let snapshot = resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: true,
                mixedCaptureDeviceVisible: true,
                mixedCaptureDeviceName: "Mixed Capture Audio",
                microphoneAuthorization: .granted,
                defaultMicrophoneAvailable: true,
                defaultMicrophoneName: "MacBook Pro Microphone"
            )
        )

        assertEqual(snapshot.virtualAudioDeviceName, "Mixed Capture Audio")
        assertEqual(snapshot.selectedMicrophoneName, "MacBook Pro Microphone")
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}
