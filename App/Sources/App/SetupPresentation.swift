import Foundation

struct SetupStepPresentation {
    let status: String

    var displayStatus: String {
        switch status {
        case AudioDeviceStatus.installed.rawValue:
            "Installed"
        case AudioDeviceStatus.installedButNeedsReload.rawValue:
            "Restart required"
        case AudioDeviceStatus.missing.rawValue:
            "Missing"
        case AudioDeviceStatus.incompatible.rawValue:
            "Needs update"
        case PermissionStatus.granted.rawValue:
            "Granted"
        case PermissionStatus.notDetermined.rawValue:
            "Needs approval"
        case PermissionStatus.denied.rawValue:
            "Denied"
        case PermissionStatus.restricted.rawValue:
            "Restricted"
        case PermissionStatus.failed.rawValue:
            "Failed"
        case PermissionStatus.unknown.rawValue:
            "Unknown"
        case SystemAudioAccessStatus.notTested.rawValue:
            "Not checked"
        case SystemAudioAccessStatus.waitingForSignal.rawValue:
            "Checking"
        case SystemAudioAccessStatus.receivingAudio.rawValue:
            "Receiving audio"
        case SystemAudioAccessStatus.proceedUnverified.rawValue:
            "Verified"
        case SystemAudioAccessStatus.silent.rawValue:
            "Silent"
        case SystemAudioAccessStatus.deniedOrUnavailable.rawValue:
            "Needs permission"
        case SystemAudioAccessStatus.failed.rawValue:
            "Failed"
        case CaptureSessionState.degraded.rawValue:
            "Degraded"
        case SelectedDeviceStatus.available.rawValue:
            "Available"
        case SelectedDeviceStatus.missing.rawValue:
            "Missing"
        case SelectedDeviceStatus.unknown.rawValue:
            "Unknown"
        case QuickTimeDeviceStatus.visible.rawValue:
            "Visible"
        case QuickTimeDeviceStatus.notVisible.rawValue:
            "Not visible"
        case QuickTimeDeviceStatus.unknown.rawValue:
            "Unknown"
        default:
            status
        }
    }

    var isComplete: Bool {
        switch status {
        case AudioDeviceStatus.installed.rawValue,
             PermissionStatus.granted.rawValue,
             SystemAudioAccessStatus.receivingAudio.rawValue,
             SystemAudioAccessStatus.proceedUnverified.rawValue,
             SelectedDeviceStatus.available.rawValue,
             QuickTimeDeviceStatus.visible.rawValue:
            true
        default:
            false
        }
    }
}

enum SetupWindowReopenPolicy {
    static let shouldAllowSystemDefaultWindowCreation = false
}

enum AppLifecyclePresentation {
    static let exposesSystemSettingsScene = false
    static let usesExplicitAppKitDelegateMain = true
}
