import AppKit
import Darwin
import SwiftUI

@main
enum MixedCaptureAudioUninstallerMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = UninstallerAppDelegate()
        UninstallerCommandMenu.install(on: app)
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        withExtendedLifetime(appDelegate) {
            app.run()
        }
    }
}

@MainActor
private final class UninstallerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var cleanup: DetachedUninstallerCleanup?
    private var model: DetachedUninstallerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let manifestURL = DetachedUninstallRequest.requestManifestURL(),
            let data = try? Data(contentsOf: manifestURL),
            let request = try? JSONDecoder().decode(DetachedUninstallRequest.self, from: data)
        else {
            showLaunchFailure()
            return
        }

        let copyDirectoryURL = manifestURL.deletingLastPathComponent()
        let cleanup = DetachedUninstallerCleanup(copyDirectoryURL: copyDirectoryURL)
        cleanup.removeOlderSiblingCopies()
        self.cleanup = cleanup

        let model = DetachedUninstallerModel(request: request)
        self.model = model
        model.startParentExitPolling()
        let hostingView = NSHostingView(rootView: DetachedUninstallerView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.presentation.title
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        DetachedUninstallerWindowLifecyclePresentation.shouldTerminateAfterLastWindowClosed(
            isComplete: model?.isComplete ?? true
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = DetachedUninstallerWindowLifecyclePresentation.terminationDecision(
            isComplete: model?.isComplete ?? true
        )
        switch decision {
        case .allow:
            return .terminateNow
        case let .confirmBeforeTerminating(presentation):
            if confirmQuitBeforeCompletion(presentation) {
                return .terminateNow
            }
            return .terminateCancel
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let shouldClose = DetachedUninstallerWindowLifecyclePresentation.shouldCloseWindow(
            isComplete: model?.isComplete ?? true
        )
        if !shouldClose {
            sender.miniaturize(nil)
        }
        return shouldClose
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup?.removeCurrentCopyDirectory()
    }

    private func restoreWindowAfterCancelledTermination() {
        guard let window else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func confirmQuitBeforeCompletion(
        _ presentation: DetachedUninstallerQuitConfirmationPresentation
    ) -> Bool {
        restoreWindowAfterCancelledTermination()

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.messageText
        alert.informativeText = presentation.informativeText
        alert.addButton(withTitle: presentation.continueButtonTitle)
        alert.addButton(withTitle: presentation.quitButtonTitle)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            restoreWindowAfterCancelledTermination()
            return false
        }
        return true
    }

    private func showLaunchFailure() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not open uninstaller"
        alert.informativeText = "The uninstall request was missing or unreadable. Open Finder and remove MixedCaptureAudio.app and MixedCaptureAudio.driver manually."
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@MainActor
private enum UninstallerCommandMenu {
    static func install(on application: NSApplication) {
        let presentation = DetachedUninstallerCommandMenuPresentation.default
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem(presentation: presentation))
        mainMenu.addItem(windowMenuItem(presentation: presentation))
        application.mainMenu = mainMenu
    }

    private static func applicationMenuItem(
        presentation: DetachedUninstallerCommandMenuPresentation
    ) -> NSMenuItem {
        let item = NSMenuItem(title: presentation.applicationMenuTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: presentation.applicationMenuTitle)
        menu.addItem(NSMenuItem(
            title: presentation.quitTitle,
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: presentation.quitKeyEquivalent
        ))
        item.submenu = menu
        return item
    }

    private static func windowMenuItem(
        presentation: DetachedUninstallerCommandMenuPresentation
    ) -> NSMenuItem {
        let item = NSMenuItem(title: presentation.windowMenuTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: presentation.windowMenuTitle)
        menu.addItem(NSMenuItem(
            title: presentation.minimizeTitle,
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: presentation.minimizeKeyEquivalent
        ))
        menu.addItem(NSMenuItem(
            title: presentation.zoomTitle,
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: presentation.bringAllToFrontTitle,
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        ))
        item.submenu = menu
        return item
    }
}

@MainActor
private final class DetachedUninstallerModel: ObservableObject {
    private static let parentPollIntervalNanoseconds: UInt64 = 250_000_000
    private static let parentWaitTimeoutNanoseconds: UInt64 = 30_000_000_000

    let presentation: DetachedUninstallerPresentation
    private let request: DetachedUninstallRequest
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let parentProcessIsRunningProvider: (Int32) -> Bool
    private var parentPollTask: Task<Void, Never>?
    @Published private(set) var installedPaths: Set<String>
    @Published private(set) var parentProcessIsRunning: Bool
    @Published private(set) var parentProcessWaitTimedOut = false
    @Published private(set) var isComplete = false

    init(
        request: DetachedUninstallRequest,
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        parentProcessIsRunningProvider: @escaping (Int32) -> Bool = detachedUninstallerProcessExists(pid:)
    ) {
        self.request = request
        self.fileManager = fileManager
        self.workspace = workspace
        self.parentProcessIsRunningProvider = parentProcessIsRunningProvider
        presentation = DetachedUninstallerPresentation(request: request)
        installedPaths = Set(presentation.items.map(\.path).filter { fileManager.fileExists(atPath: $0) })
        parentProcessIsRunning = request.parentProcessIdentifier.map(parentProcessIsRunningProvider) ?? false
        isComplete = installedPaths.isEmpty
    }

    deinit {
        parentPollTask?.cancel()
    }

    var itemRows: [DetachedUninstallerItemRowPresentation] {
        presentation.itemRows(
            installedPaths: installedPaths,
            parentProcessIsRunning: parentProcessIsRunning,
            parentProcessWaitTimedOut: parentProcessWaitTimedOut
        )
    }

    func startParentExitPolling() {
        guard request.parentProcessIdentifier != nil, parentProcessIsRunning else {
            return
        }
        parentPollTask = Task { [weak self] in
            var elapsedNanoseconds: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.parentPollIntervalNanoseconds)
                elapsedNanoseconds += Self.parentPollIntervalNanoseconds
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    self.refreshParentProcessState()
                    if !self.parentProcessIsRunning {
                        self.parentProcessWaitTimedOut = false
                        self.parentPollTask?.cancel()
                        self.parentPollTask = nil
                    } else if elapsedNanoseconds >= Self.parentWaitTimeoutNanoseconds {
                        self.parentProcessWaitTimedOut = true
                        self.parentPollTask?.cancel()
                        self.parentPollTask = nil
                    }
                }
            }
        }
    }

    func reveal(_ row: DetachedUninstallerItemRowPresentation) {
        guard row.isRemovalAvailable else {
            return
        }
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: row.item.path)])
    }

    func checkAgain() {
        refreshParentProcessState()
        if !parentProcessIsRunning {
            parentProcessWaitTimedOut = false
        }
        installedPaths = Set(presentation.items.map(\.path).filter { fileManager.fileExists(atPath: $0) })
        isComplete = installedPaths.isEmpty
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func refreshParentProcessState() {
        guard let parentProcessIdentifier = request.parentProcessIdentifier else {
            parentProcessIsRunning = false
            return
        }
        parentProcessIsRunning = parentProcessIsRunningProvider(parentProcessIdentifier)
    }

}

private func detachedUninstallerProcessExists(pid: Int32) -> Bool {
    guard pid > 0 else {
        return false
    }
    errno = 0
    if kill(pid, 0) == 0 {
        return true
    }
    return errno != ESRCH
}

private struct DetachedUninstallerView: View {
    @ObservedObject var model: DetachedUninstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.presentation.title)
                    .font(.title2.weight(.semibold))
                Text(model.presentation.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(model.itemRows) { row in
                    DetachedUninstallerItemRow(
                        row: row,
                        revealButtonTitle: model.presentation.revealButtonTitle,
                        reveal: {
                            model.reveal(row)
                        }
                    )
                }
            }

            guidancePanel

            Spacer(minLength: 0)

            HStack {
                Button(model.presentation.quitButtonTitle) {
                    model.quit()
                }
                Spacer()
                Button {
                    model.checkAgain()
                } label: {
                    Label(model.presentation.checkAgainButtonTitle, systemImage: "arrow.clockwise")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
    }

    private var guidancePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isComplete ? model.presentation.completionTitle : model.presentation.inProgressTitle)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.isComplete ? model.presentation.completionItems : model.presentation.inProgressItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DetachedUninstallerItemRow: View {
    let row: DetachedUninstallerItemRowPresentation
    let revealButtonTitle: String
    let reveal: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isInstalled ? row.item.systemImageName : "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(row.isInstalled ? .primary : .green)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                    .font(.headline)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(row.allowsMultilineDetail ? nil : 1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button(revealButtonTitle) {
                reveal()
            }
            .disabled(!row.isRemovalAvailable)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private final class DetachedUninstallerCleanup {
    private let copyDirectoryURL: URL
    private let fileManager: FileManager

    init(copyDirectoryURL: URL, fileManager: FileManager = .default) {
        self.copyDirectoryURL = copyDirectoryURL
        self.fileManager = fileManager
    }

    func removeOlderSiblingCopies() {
        let rootURL = copyDirectoryURL.deletingLastPathComponent()
        guard let siblingURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for siblingURL in siblingURLs where siblingURL != copyDirectoryURL {
            guard
                let values = try? siblingURL.resourceValues(forKeys: [.contentModificationDateKey]),
                let modificationDate = values.contentModificationDate,
                modificationDate < cutoff
            else {
                continue
            }
            try? fileManager.removeItem(at: siblingURL)
        }
    }

    func removeCurrentCopyDirectory() {
        try? fileManager.removeItem(at: copyDirectoryURL)
    }
}
