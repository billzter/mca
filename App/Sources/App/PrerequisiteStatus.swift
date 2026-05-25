import Foundation

protocol PrerequisiteChecking {
    func snapshot() -> PrerequisiteSnapshot
}

protocol MicrophonePermissionRequesting {
    func requestAccess() async -> Bool
}

enum SystemAudioAccessTestOutcome: Equatable {
    case receivingAudio
    case silent
    case deniedOrUnavailable
    case failed
}

protocol SystemAudioAccessTesting {
    func runSystemAudioAccessTest() async -> SystemAudioAccessTestOutcome
}

struct MicrophoneDevice: Equatable, Identifiable {
    let id: String
    let name: String
}

protocol MicrophoneCataloging {
    func availableMicrophones() -> [MicrophoneDevice]
}

protocol MicrophoneSelectionStoring: AnyObject {
    var selectedMicrophoneID: String? { get set }
    var preferredMicrophoneIDs: [String] { get set }
}

protocol SystemAudioAccessStoring: AnyObject {
    var hasVerifiedSystemAudioAccess: Bool { get set }
}

enum LaunchAtStartupStatus: String, Equatable {
    case unknown = "Unknown"
    case disabled = "Disabled"
    case enabled = "Enabled"
    case requiresApproval = "RequiresApproval"
    case failed = "Failed"
}

enum LaunchAtStartupSetResult: Equatable {
    case success(LaunchAtStartupStatus)
    case failed(String)
}

protocol LaunchAtStartupControlling: AnyObject {
    func currentStatus() -> LaunchAtStartupStatus
    func setEnabled(_ enabled: Bool) -> LaunchAtStartupSetResult
}

enum LiveMixerStartResult: Equatable {
    case started
    case failed
}

protocol LiveMixerControlling: AnyObject {
    @MainActor func start(microphoneID: String?, completion: @MainActor @escaping (LiveMixerStartResult) -> Void)
    @MainActor func stop(completion: @MainActor @escaping () -> Void)
    @MainActor func currentHealthSnapshot() -> HealthSnapshot?
}

enum LiveMixerMicrophoneID {
    static let noMicrophone = "__MCA_NO_MIC__"
}

enum AudioDeviceStatus: String, CaseIterable {
    case unknown = "Unknown"
    case missing = "Missing"
    case installed = "Installed"
    case installedButNeedsReload = "InstalledButNeedsReload"
    case incompatible = "Incompatible"
    case failed = "Failed"
}

enum DriverUpdateRequirement: String, CaseIterable {
    case none = "None"
    case installDriver = "InstallDriver"
    case reloadCoreAudio = "ReloadCoreAudio"
    case updateDriver = "UpdateDriver"
}

enum PermissionStatus: String, CaseIterable {
    case unknown = "Unknown"
    case notDetermined = "NotDetermined"
    case requesting = "Requesting"
    case granted = "Granted"
    case denied = "Denied"
    case restricted = "Restricted"
    case failed = "Failed"
}

enum SystemAudioAccessStatus: String, CaseIterable {
    case unknown = "Unknown"
    case notTested = "NotTested"
    case promptExpected = "PromptExpected"
    case starting = "Starting"
    case started = "Started"
    case waitingForSignal = "WaitingForSignal"
    case receivingAudio = "ReceivingAudio"
    case silent = "Silent"
    case proceedUnverified = "ProceedUnverified"
    case deniedOrUnavailable = "DeniedOrUnavailable"
    case failed = "Failed"
}

enum SelectedDeviceStatus: String, CaseIterable {
    case unknown = "Unknown"
    case available = "Available"
    case missing = "Missing"
    case failed = "Failed"
}

enum QuickTimeDeviceStatus: String, CaseIterable {
    case unknown = "Unknown"
    case visible = "Visible"
    case notVisible = "NotVisible"
    case failed = "Failed"
}

enum CaptureSessionState: String, CaseIterable {
    case stopped = "Stopped"
    case checkingPrerequisites = "CheckingPrerequisites"
    case requestingPermissions = "RequestingPermissions"
    case ready = "Ready"
    case starting = "Starting"
    case running = "Running"
    case degraded = "Degraded"
    case stopping = "Stopping"
    case failed = "Failed"
}

enum LiveMixerState: String, CaseIterable {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case failed = "Failed"
}

enum MicrophoneFault: Equatable {
    case none
    case usingFallback(selectedName: String, fallbackName: String)
    case selectedUnavailable(selectedName: String)
    case permissionRevoked
}

enum MicrophonePriorityMoveDirection {
    case up
    case down
}

struct MicrophonePriorityItem: Equatable, Identifiable {
    let id: String
    let name: String
    let isAvailable: Bool
    let isActive: Bool
    let isSelected: Bool
}

enum MicrophoneAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case granted
    case denied
    case restricted
    case failed
}

struct DriverCompatibilityMetadata: Equatable {
    var driverCompatibilityVersion: UInt32?
    var sharedMemoryABIVersion: UInt32?

    static let expectedModelUID = "com.minamiktr.mca.model.MixedCaptureAudio.driver1.shm1"

    static let expected = DriverCompatibilityMetadata(
        driverCompatibilityVersion: 1,
        sharedMemoryABIVersion: 1
    )

    static func loadedDeviceMetadata(
        customMetadata: DriverCompatibilityMetadata?,
        modelUID: String?
    ) -> DriverCompatibilityMetadata? {
        if customMetadata == .expected {
            return customMetadata
        }
        if modelUID == expectedModelUID {
            return .expected
        }
        return customMetadata
    }
}

struct PrerequisiteInputs: Equatable {
    var driverBundleExists: Bool
    var installedDriverCompatibility: DriverCompatibilityMetadata? = .expected
    var loadedDriverCompatibility: DriverCompatibilityMetadata? = .expected
    var mixedCaptureDeviceVisible: Bool
    var mixedCaptureDeviceName: String? = nil
    var microphoneAuthorization: MicrophoneAuthorizationState
    var defaultMicrophoneAvailable: Bool
    var defaultMicrophoneName: String? = nil
}

struct PrerequisiteSnapshot: Equatable {
    var driverStatus: AudioDeviceStatus
    var driverUpdateRequirement: DriverUpdateRequirement = .none
    var microphonePermission: PermissionStatus
    var selectedMicStatus: SelectedDeviceStatus
    var quickTimeDeviceStatus: QuickTimeDeviceStatus
    var virtualAudioDeviceName: String? = nil
    var selectedMicrophoneName: String? = nil
}

struct PrerequisiteStatusResolver {
    func resolve(inputs: PrerequisiteInputs) -> PrerequisiteSnapshot {
        PrerequisiteSnapshot(
            driverStatus: resolveDriverStatus(inputs: inputs),
            driverUpdateRequirement: resolveDriverUpdateRequirement(inputs: inputs),
            microphonePermission: resolveMicrophonePermission(inputs.microphoneAuthorization),
            selectedMicStatus: inputs.defaultMicrophoneAvailable ? .available : .missing,
            quickTimeDeviceStatus: inputs.mixedCaptureDeviceVisible ? .visible : .notVisible,
            virtualAudioDeviceName: resolveVirtualAudioDeviceName(inputs: inputs),
            selectedMicrophoneName: resolveSelectedMicrophoneName(inputs: inputs)
        )
    }

    private func resolveDriverStatus(inputs: PrerequisiteInputs) -> AudioDeviceStatus {
        if !inputs.driverBundleExists {
            return .missing
        }
        if !isCompatible(inputs.installedDriverCompatibility) {
            return .incompatible
        }
        if !inputs.mixedCaptureDeviceVisible {
            return .installedButNeedsReload
        }
        if !isCompatible(inputs.loadedDriverCompatibility) {
            return .installedButNeedsReload
        }
        return .installed
    }

    private func resolveDriverUpdateRequirement(inputs: PrerequisiteInputs) -> DriverUpdateRequirement {
        if !inputs.driverBundleExists {
            return .installDriver
        }
        if !isCompatible(inputs.installedDriverCompatibility) {
            return .updateDriver
        }
        if !inputs.mixedCaptureDeviceVisible {
            return .reloadCoreAudio
        }
        if !isCompatible(inputs.loadedDriverCompatibility) {
            return .reloadCoreAudio
        }
        return .none
    }

    private func isCompatible(_ metadata: DriverCompatibilityMetadata?) -> Bool {
        metadata == .expected
    }

    private func resolveMicrophonePermission(_ state: MicrophoneAuthorizationState) -> PermissionStatus {
        switch state {
        case .unknown:
            .unknown
        case .notDetermined:
            .notDetermined
        case .granted:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .failed:
            .failed
        }
    }

    private func resolveVirtualAudioDeviceName(inputs: PrerequisiteInputs) -> String? {
        guard inputs.mixedCaptureDeviceVisible else {
            return nil
        }
        return inputs.mixedCaptureDeviceName ?? "Mixed Capture Audio"
    }

    private func resolveSelectedMicrophoneName(inputs: PrerequisiteInputs) -> String? {
        guard inputs.defaultMicrophoneAvailable else {
            return nil
        }
        return inputs.defaultMicrophoneName ?? "Default Microphone"
    }
}
