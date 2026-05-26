import AVFoundation
import AppKit
import CoreAudio
import Foundation

struct AppPrerequisiteChecker: PrerequisiteChecking {
    private let driverPath = "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"
    private let driverInfoPlistName = "Info.plist"
    private let driverCompatibilityKey = "MCAHALCompatibilityVersion"
    private let sharedMemoryABIKey = "MCASharedMemoryABIVersion"
    private let mixedCaptureDeviceUID = "com.minamiktr.mca.device.MixedCaptureAudio"
    private let resolver = PrerequisiteStatusResolver()

    func snapshot() -> PrerequisiteSnapshot {
        let driverBundleExists = FileManager.default.fileExists(atPath: driverPath)
        let mixedCaptureDevice = CoreAudioDeviceLookup.device(uid: mixedCaptureDeviceUID)
        let defaultMicrophone = AVCaptureDevice.default(for: .audio)
        return resolver.resolve(
            inputs: PrerequisiteInputs(
                driverBundleExists: driverBundleExists,
                installedDriverCompatibility: driverBundleExists ? installedDriverCompatibility() : nil,
                loadedDriverCompatibility: mixedCaptureDevice?.compatibility,
                mixedCaptureDeviceVisible: mixedCaptureDevice != nil,
                mixedCaptureDeviceName: mixedCaptureDevice?.name,
                microphoneAuthorization: microphoneAuthorization(),
                defaultMicrophoneAvailable: defaultMicrophone != nil,
                defaultMicrophoneName: defaultMicrophone?.localizedName
            )
        )
    }

    private func installedDriverCompatibility() -> DriverCompatibilityMetadata? {
        let infoURL = URL(fileURLWithPath: driverPath)
            .appendingPathComponent("Contents")
            .appendingPathComponent(driverInfoPlistName)
        guard let plist = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            return nil
        }
        return DriverCompatibilityMetadata(
            driverCompatibilityVersion: uint32Value(plist[driverCompatibilityKey]),
            sharedMemoryABIVersion: uint32Value(plist[sharedMemoryABIKey])
        )
    }

    private func uint32Value(_ value: Any?) -> UInt32? {
        switch value {
        case let number as NSNumber:
            let intValue = number.intValue
            return intValue >= 0 ? UInt32(intValue) : nil
        case let string as String:
            return UInt32(string)
        default:
            return nil
        }
    }

    private func microphoneAuthorization() -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .granted
        @unknown default:
            .unknown
        }
    }
}

struct AppMicrophoneCatalog: MicrophoneCataloging {
    func availableMicrophones() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .microphone,
                .external,
            ],
            mediaType: .audio,
            position: .unspecified
        )
        .devices
        .filter { device in
            !device.uniqueID.hasPrefix("com.minamiktr.mca.")
        }
        .map { device in
            MicrophoneDevice(id: device.uniqueID, name: device.localizedName)
        }
    }
}

struct AppAudioSourceCatalog: AppAudioSourceCataloging {
    func availableAppAudioSources() -> [AppAudioSource] {
        let currentBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> AppAudioSource? in
                guard let bundleID = app.bundleIdentifier,
                      !bundleID.isEmpty,
                      bundleID != currentBundleID,
                      app.activationPolicy == .regular || app.activationPolicy == .accessory
                else {
                    return nil
                }
                guard !seenBundleIDs.contains(bundleID) else {
                    return nil
                }
                seenBundleIDs.insert(bundleID)
                let name = app.localizedName ?? bundleID
                return AppAudioSource(bundleID: bundleID, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

final class AppMicrophoneSelectionStore: MicrophoneSelectionStoring {
    private let defaults: UserDefaults
    private let key = "selectedMicrophoneID"
    private let priorityKey = "preferredMicrophoneIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedMicrophoneID: String? {
        get {
            defaults.string(forKey: key)
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    var preferredMicrophoneIDs: [String] {
        get {
            defaults.stringArray(forKey: priorityKey) ?? selectedMicrophoneID.map { [$0] } ?? []
        }
        set {
            defaults.set(newValue, forKey: priorityKey)
        }
    }
}

final class AppAudioSelectionStore: AppAudioSelectionStoring {
    private let defaults: UserDefaults
    private let captureModeKey = "programAudioCaptureMode"
    private let selectedAppBundleIDsKey = "selectedAppBundleIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var captureMode: ProgramAudioCaptureMode {
        get {
            guard let rawValue = defaults.string(forKey: captureModeKey),
                  let mode = ProgramAudioCaptureMode(rawValue: rawValue)
            else {
                return .globalSystemAudio
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: captureModeKey)
        }
    }

    var selectedAppBundleIDs: [String] {
        get {
            defaults.stringArray(forKey: selectedAppBundleIDsKey) ?? []
        }
        set {
            let sanitized = newValue.reduce(into: [String]()) { result, bundleID in
                guard !bundleID.isEmpty, !result.contains(bundleID) else {
                    return
                }
                result.append(bundleID)
            }
            defaults.set(sanitized, forKey: selectedAppBundleIDsKey)
        }
    }
}

final class AppSystemAudioAccessStore: SystemAudioAccessStoring {
    private let defaults: UserDefaults
    private let key = "hasVerifiedSystemAudioAccess"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasVerifiedSystemAudioAccess: Bool {
        get {
            defaults.bool(forKey: key)
        }
        set {
            defaults.set(newValue, forKey: key)
        }
    }
}

struct CoreAudioDeviceInfo: Equatable {
    var id: AudioObjectID
    var uid: String
    var name: String?
    var modelUID: String? = nil
    var compatibility: DriverCompatibilityMetadata? = nil
    var isRunningSomewhere: Bool = false
}

enum CoreAudioDeviceLookup {
    static func deviceExists(uid expectedUID: String) -> Bool {
        device(uid: expectedUID) != nil
    }

    static func device(uid expectedUID: String) -> CoreAudioDeviceInfo? {
        guard let devices = allDeviceIDs() else {
            return nil
        }
        for deviceID in devices {
            guard let uid = deviceUID(deviceID: deviceID), uid == expectedUID else {
                continue
            }
            return CoreAudioDeviceInfo(
                id: deviceID,
                uid: uid,
                name: deviceName(deviceID: deviceID),
                modelUID: deviceModelUID(deviceID: deviceID),
                compatibility: driverCompatibility(deviceID: deviceID),
                isRunningSomewhere: copyUInt32Property(
                    deviceID: deviceID,
                    selector: kAudioDevicePropertyDeviceIsRunningSomewhere
                ) != 0
            )
        }
        return nil
    }

    private static func allDeviceIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard dataStatus == noErr else {
            return nil
        }
        return devices
    }

    private static func deviceUID(deviceID: AudioObjectID) -> String? {
        copyStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(deviceID: AudioObjectID) -> String? {
        copyStringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName)
    }

    private static func deviceModelUID(deviceID: AudioObjectID) -> String? {
        copyStringProperty(deviceID: deviceID, selector: kAudioDevicePropertyModelUID)
    }

    private static func driverCompatibility(deviceID: AudioObjectID) -> DriverCompatibilityMetadata? {
        let driverVersion = copyUInt32Property(
            deviceID: deviceID,
            selector: fourCharCode("mcav")
        )
        let sharedMemoryVersion = copyUInt32Property(
            deviceID: deviceID,
            selector: fourCharCode("mabi")
        )
        let customMetadata = if driverVersion != nil || sharedMemoryVersion != nil {
            DriverCompatibilityMetadata(
                driverCompatibilityVersion: driverVersion,
                sharedMemoryABIVersion: sharedMemoryVersion
            )
        } else {
            Optional<DriverCompatibilityMetadata>.none
        }
        return DriverCompatibilityMetadata.loadedDeviceMetadata(
            customMetadata: customMetadata,
            modelUID: deviceModelUID(deviceID: deviceID)
        )
    }

    private static func copyStringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func copyUInt32Property(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, dataSize == UInt32(MemoryLayout<UInt32>.size) else {
            return nil
        }
        return value
    }

    private static func fourCharCode(_ string: String) -> AudioObjectPropertySelector {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) | UInt32(scalar.value)
        }
        return AudioObjectPropertySelector(result)
    }
}
