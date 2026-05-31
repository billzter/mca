import Foundation

struct DetachedUninstallRequest: Codable, Equatable {
    static let requestArgument = "--request"
    static let manifestFileName = "DetachedUninstallRequest.json"

    let appPath: String
    let driverPath: String
    let requiresRestart: Bool
    let parentProcessIdentifier: Int32?

    static func commandLineArguments(manifestURL: URL) -> [String] {
        [requestArgument, manifestURL.path]
    }

    static func requestManifestURL(from arguments: [String] = CommandLine.arguments) -> URL? {
        guard let argumentIndex = arguments.firstIndex(of: requestArgument) else {
            return nil
        }
        let valueIndex = arguments.index(after: argumentIndex)
        guard arguments.indices.contains(valueIndex), !arguments[valueIndex].isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: arguments[valueIndex])
    }
}

struct DetachedUninstallerItemPresentation: Equatable, Identifiable {
    enum Kind: Equatable {
        case driver
        case app
    }

    let kind: Kind
    let title: String
    let path: String
    let systemImageName: String

    var id: Kind {
        kind
    }
}

struct DetachedUninstallerPresentation: Equatable {
    let title: String
    let message: String
    let items: [DetachedUninstallerItemPresentation]
    let revealButtonTitle: String
    let checkAgainButtonTitle: String
    let quitButtonTitle: String
    let inProgressTitle: String
    let inProgressItems: [String]
    let completionTitle: String
    let completionItems: [String]
    let completionMessage: String
    let waitingForMainAppToQuitDetail: String
    let parentProcessTimedOutDetail: String

    init(request: DetachedUninstallRequest) {
        title = "Finish Uninstalling"
        message = "Drag each remaining item to Trash in Finder, or select it and press Command-Delete. Finder may ask for an administrator password."
        items = [
            DetachedUninstallerItemPresentation(
                kind: .driver,
                title: "MixedCaptureAudio.driver",
                path: request.driverPath,
                systemImageName: "puzzlepiece.extension"
            ),
            DetachedUninstallerItemPresentation(
                kind: .app,
                title: "MixedCaptureAudio.app",
                path: request.appPath,
                systemImageName: "app"
            ),
        ]
        revealButtonTitle = "Show in Finder"
        checkAgainButtonTitle = "Check Again"
        quitButtonTitle = "Quit"
        inProgressTitle = "Next steps"
        completionTitle = "Uninstall completed"
        waitingForMainAppToQuitDetail = "Waiting for MixedCaptureAudio to quit..."
        parentProcessTimedOutDetail = "MixedCaptureAudio is still running. Quit it manually, then click Check Again."

        var nextSteps = [
            "Move each listed item to Trash in Finder.",
            "Click Check Again after Trash accepts the items.",
        ]
        if request.requiresRestart {
            nextSteps.append("Restart your Mac after uninstall if the audio driver was installed.")
        }
        inProgressItems = nextSteps

        var completionItems = [
            "MixedCaptureAudio app and audio driver are no longer installed.",
        ]
        if request.requiresRestart {
            completionItems.append("Restart your Mac to finish unloading the audio driver.")
        }
        self.completionItems = completionItems
        completionMessage = completionItems.map { "- \($0)" }.joined(separator: "\n")
    }

    func itemRows(
        installedPaths: Set<String>,
        parentProcessIsRunning: Bool,
        parentProcessWaitTimedOut: Bool = false
    ) -> [DetachedUninstallerItemRowPresentation] {
        items.map { item in
            let isInstalled = installedPaths.contains(item.path)
            let isWaitingForMainApp = item.kind == .app && isInstalled && parentProcessIsRunning
            let detail = detail(
                for: item,
                isInstalled: isInstalled,
                isWaitingForMainApp: isWaitingForMainApp,
                parentProcessWaitTimedOut: parentProcessWaitTimedOut
            )
            return DetachedUninstallerItemRowPresentation(
                item: item,
                isInstalled: isInstalled,
                isRemovalAvailable: isInstalled && !isWaitingForMainApp,
                detail: detail,
                allowsMultilineDetail: detail != item.path && isInstalled
            )
        }
    }

    private func detail(
        for item: DetachedUninstallerItemPresentation,
        isInstalled: Bool,
        isWaitingForMainApp: Bool,
        parentProcessWaitTimedOut: Bool
    ) -> String {
        if !isInstalled {
            return "Removed"
        }
        if isWaitingForMainApp {
            if parentProcessWaitTimedOut {
                return parentProcessTimedOutDetail
            }
            return waitingForMainAppToQuitDetail
        }
        return item.path
    }
}

struct DetachedUninstallerItemRowPresentation: Equatable, Identifiable {
    let item: DetachedUninstallerItemPresentation
    let isInstalled: Bool
    let isRemovalAvailable: Bool
    let detail: String
    let allowsMultilineDetail: Bool

    var id: DetachedUninstallerItemPresentation.Kind {
        item.kind
    }
}

enum DetachedUninstallerLifecyclePresentation {
    static let usesRegularAppActivationPolicy = true
}

struct DetachedUninstallerQuitConfirmationPresentation: Equatable {
    let messageText: String
    let informativeText: String
    let continueButtonTitle: String
    let quitButtonTitle: String

    static let `default` = DetachedUninstallerQuitConfirmationPresentation(
        messageText: "Quit before uninstall finishes?",
        informativeText: "MixedCaptureAudio may still be installed. Continue uninstalling, or quit the helper now and finish later.",
        continueButtonTitle: "Continue Uninstalling",
        quitButtonTitle: "Quit Anyway"
    )
}

struct DetachedUninstallerCommandMenuPresentation: Equatable {
    let applicationMenuTitle: String
    let quitTitle: String
    let quitKeyEquivalent: String
    let windowMenuTitle: String
    let minimizeTitle: String
    let minimizeKeyEquivalent: String
    let zoomTitle: String
    let bringAllToFrontTitle: String

    static let `default` = DetachedUninstallerCommandMenuPresentation(
        applicationMenuTitle: "Finish Uninstalling MCA",
        quitTitle: "Quit Finish Uninstalling MCA",
        quitKeyEquivalent: "q",
        windowMenuTitle: "Window",
        minimizeTitle: "Minimize",
        minimizeKeyEquivalent: "m",
        zoomTitle: "Zoom",
        bringAllToFrontTitle: "Bring All to Front"
    )
}

enum DetachedUninstallerTerminationDecision: Equatable {
    case allow
    case confirmBeforeTerminating(DetachedUninstallerQuitConfirmationPresentation)
}

enum DetachedUninstallerWindowLifecyclePresentation {
    static func terminationDecision(isComplete: Bool) -> DetachedUninstallerTerminationDecision {
        if isComplete {
            return .allow
        }
        return .confirmBeforeTerminating(.default)
    }

    static func shouldCloseWindow(isComplete: Bool) -> Bool {
        isComplete
    }

    static func shouldTerminateAfterLastWindowClosed(isComplete: Bool) -> Bool {
        isComplete
    }
}
