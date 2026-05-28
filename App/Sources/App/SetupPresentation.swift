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

struct SetupChecklistRowPresentation: Equatable, Identifiable {
    enum ID: Equatable {
        case virtualAudioDevice
        case microphone
        case systemAudio
        case quickTimeInput
    }

    let id: ID
    let title: String
    let primary: String
    let status: String

    var step: SetupStepPresentation {
        SetupStepPresentation(status: status)
    }

    var displayStatus: String {
        step.displayStatus
    }

    var isComplete: Bool {
        step.isComplete
    }
}

struct SetupChecklistPresentation {
    let rows: [SetupChecklistRowPresentation]

    var completedRows: [SetupChecklistRowPresentation] {
        rows.filter(\.isComplete)
    }

    var incompleteRows: [SetupChecklistRowPresentation] {
        rows.filter { !$0.isComplete }
    }

    var defaultVisibleRows: [SetupChecklistRowPresentation] {
        incompleteRows
    }

    var completeCount: Int {
        completedRows.count
    }

    var isComplete: Bool {
        !rows.isEmpty && completeCount == rows.count
    }

    var headerStatus: String? {
        isComplete ? "Complete" : nil
    }
}

enum SetupActionPanelPlacement {
    static func prioritizesSystemAudio(_ status: SystemAudioAccessStatus) -> Bool {
        switch status {
        case .receivingAudio, .proceedUnverified:
            false
        case .unknown, .notTested, .promptExpected, .starting, .started, .waitingForSignal, .silent, .deniedOrUnavailable, .failed:
            true
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
