import Foundation

@main
struct PrerequisiteStatusTests {
    static func main() {
        testMissingDriverBlocksDeviceVisibility()
        testInstalledButNotVisibleNeedsReload()
        testVisibleDriverIsInstalledAndQuickTimeVisible()
        testCompatibleBundleWithOldLoadedDriverNeedsCoreAudioReload()
        testIncompatibleInstalledBundleNeedsDriverUpdate()
        testLoadedDriverWithoutCompatibilityMetadataNeedsCoreAudioReload()
        testLoadedDriverCompatibilityCanComeFromModelUID()
        testMicPermissionMappings()
        testSelectedMicAvailabilityMappings()
        testDeviceNamesAreIncludedWhenAvailable()
        print("prerequisite status tests passed")
    }

    private static func testMissingDriverBlocksDeviceVisibility() {
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

    private static func testInstalledButNotVisibleNeedsReload() {
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

    private static func testVisibleDriverIsInstalledAndQuickTimeVisible() {
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

    private static func testCompatibleBundleWithOldLoadedDriverNeedsCoreAudioReload() {
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

    private static func testIncompatibleInstalledBundleNeedsDriverUpdate() {
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

    private static func testLoadedDriverWithoutCompatibilityMetadataNeedsCoreAudioReload() {
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

    private static func testLoadedDriverCompatibilityCanComeFromModelUID() {
        let metadata = DriverCompatibilityMetadata.loadedDeviceMetadata(
            customMetadata: nil,
            modelUID: DriverCompatibilityMetadata.expectedModelUID
        )

        assertEqual(metadata, .expected)
    }

    private static func testMicPermissionMappings() {
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

    private static func testSelectedMicAvailabilityMappings() {
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

    private static func testDeviceNamesAreIncludedWhenAvailable() {
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
