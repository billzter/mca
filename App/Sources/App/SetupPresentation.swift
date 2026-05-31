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

struct SetupAdvancedUninstallPresentation: Equatable {
    let title: String
    let message: String
    let actionTitle: String
    let confirmationTitle: String
    let confirmationMessage: String
    let confirmationRemovedItems: [String]
    let confirmationManualItems: [String]
    let confirmationKeptItems: [String]
    let completionTitle: String
    let completionBaseItems: [String]
    let completionRestartItem: String
    let isDestructive: Bool

    static let `default` = SetupAdvancedUninstallPresentation(
        title: "Advanced",
        message: "Remove MixedCaptureAudio from this Mac.",
        actionTitle: "Uninstall MixedCaptureAudio...",
        confirmationTitle: "Uninstall MixedCaptureAudio?",
        confirmationMessage: """
        Uninstall will:
        - Stop the live mixed-audio session
        - Remove app settings and support files
        - Open a Finish Uninstalling window for the app and audio driver

        It will keep:
        - Microphone and system-audio privacy choices

        Finder may ask for administrator approval when you move installed items to Trash. Restart your Mac after uninstall if the audio driver was installed.
        """,
        confirmationRemovedItems: [
            "Live mixed-audio session",
            "Login item",
            "App settings and support files",
        ],
        confirmationManualItems: [
            "MixedCaptureAudio app",
            "MixedCaptureAudio audio driver",
        ],
        confirmationKeptItems: [
            "Microphone and system-audio privacy choices",
        ],
        completionTitle: "Uninstall completed",
        completionBaseItems: [
            "App settings and support files were removed.",
            "MixedCaptureAudio app and audio driver are no longer installed.",
        ],
        completionRestartItem: "Restart your Mac to finish unloading the audio driver.",
        isDestructive: true
    )

    func completionMessage(requiresRestart: Bool) -> String {
        let items = completionBaseItems + (requiresRestart ? [completionRestartItem] : [])
        return items.joined(separator: "\n")
    }
}

struct ManualUninstallItemPresentation: Equatable {
    let title: String
    let path: String
}

struct ManualUninstallPresentation: Equatable {
    let title: String
    let message: String
    let appItem: ManualUninstallItemPresentation
    let driverItem: ManualUninstallItemPresentation
    let revealButtonTitle: String
    let checkAgainButtonTitle: String
    let quitButtonTitle: String

    var orderedItems: [ManualUninstallItemPresentation] {
        [driverItem, appItem]
    }

    static let `default` = ManualUninstallPresentation(
        title: "Finish Uninstalling",
        message: "Drag each remaining item to Trash in Finder, or select it and press Command-Delete. Finder may ask for an administrator password.",
        appItem: ManualUninstallItemPresentation(
            title: "MixedCaptureAudio.app",
            path: "/Applications/MixedCaptureAudio.app"
        ),
        driverItem: ManualUninstallItemPresentation(
            title: "MixedCaptureAudio.driver",
            path: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver"
        ),
        revealButtonTitle: "Show in Finder",
        checkAgainButtonTitle: "Check Again",
        quitButtonTitle: "Quit"
    )
}
