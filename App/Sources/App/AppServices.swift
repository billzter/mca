import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let model: AppStatusModel
    let sourceLevelMeterModel: SourceLevelMeterModel
    let sourceLevelMeterPollingController: SourceLevelMeterPollingController
    private let setupWindowPresenter = SetupWindowPresenter()
    private var healthPollingCancellable: AnyCancellable?
    private lazy var deviceChangeObserver = DeviceChangeObserver(
        onDeviceChange: { [weak self] in
            self?.model.refreshPrerequisites()
        },
        onRecoverSettled: { [weak self] in
            self?.model.recoverAfterDeviceConfigurationChange()
        },
        onApplicationAudioSourceChange: { [weak self] changedBundleIDs in
            self?.model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: changedBundleIDs)
        },
        onSleep: { [weak self] in
            self?.model.stopLiveMixer()
        }
    )
    private lazy var statusItemController = StatusItemController(
        model: model,
        openSetup: { [weak self] in
            self?.showSetupWindow()
        }
    )

    private init() {
        let liveMixerController = AppLiveMixerController()
        let statusModel = AppStatusModel(
            prerequisiteChecker: AppPrerequisiteChecker(),
            microphonePermissionRequester: AppMicrophonePermissionRequester(),
            systemAudioAccessTester: AppSystemAudioAccessTester(),
            liveMixerController: liveMixerController,
            microphoneCatalog: AppMicrophoneCatalog(),
            microphoneSelectionStore: AppMicrophoneSelectionStore(),
            appAudioSourceCatalog: AppAudioSourceCatalog(),
            appAudioSelectionStore: AppAudioSelectionStore(),
            audioLevelSettingsStore: AppAudioLevelSettingsStore(),
            systemAudioAccessStore: AppSystemAudioAccessStore(),
            launchAtStartupController: AppLaunchAtStartupController()
        )
        let systemAudioAutoVerifier = SystemAudioAutoVerifier {
            statusModel.markSystemAudioReceivingFromLiveProof()
        }
        model = statusModel
        sourceLevelMeterModel = SourceLevelMeterModel(
            liveMixerController: liveMixerController,
            isMixerRunning: { [weak statusModel] in
                statusModel?.liveMixerState == .running
            },
            onRawSnapshot: { snapshot in
                systemAudioAutoVerifier.observe(
                    snapshot: snapshot,
                    recorderActive: liveMixerController.isVirtualAudioDeviceRunning()
                )
            }
        )
        sourceLevelMeterPollingController = SourceLevelMeterPollingController { [weak sourceLevelMeterModel] in
            sourceLevelMeterModel?.refresh()
        }
    }

    func applicationDidFinishLaunching() {
        statusItemController.install()
        deviceChangeObserver.start()
        startHealthPolling()
        model.refreshPrerequisites()
        model.refreshLaunchAtStartupStatus()
        showSetupWindow()
    }

    func showSetupWindow() {
        setupWindowPresenter.show(
            model: model,
            sourceLevelMeterModel: sourceLevelMeterModel,
            sourceLevelMeterPollingController: sourceLevelMeterPollingController
        )
    }

    private func startHealthPolling() {
        guard healthPollingCancellable == nil else {
            return
        }
        healthPollingCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.model.refreshLiveMixerHealth()
            }
    }
}

@MainActor
private final class DeviceChangeObserver {
    private let onDeviceChange: () -> Void
    private let onRecoverSettled: () -> Void
    private let onApplicationAudioSourceChange: (Set<String>) -> Void
    private let onSleep: () -> Void
    private lazy var applicationAudioSourceChangeDebouncer = DebouncedMainActorAction { [weak self] in
        self?.flushApplicationAudioSourceChange()
    }
    private var pendingApplicationAudioSourceBundleIDs: Set<String> = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var isStarted = false
    private let coreAudioQueue = DispatchQueue(label: "com.minamiktr.mca.device-changes")
    private let deviceListAddress =
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    private let defaultOutputAddress =
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    private let defaultSystemOutputAddress =
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    private let processObjectListAddress =
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

    init(
        onDeviceChange: @escaping () -> Void,
        onRecoverSettled: @escaping () -> Void,
        onApplicationAudioSourceChange: @escaping (Set<String>) -> Void,
        onSleep: @escaping () -> Void
    ) {
        self.onDeviceChange = onDeviceChange
        self.onRecoverSettled = onRecoverSettled
        self.onApplicationAudioSourceChange = onApplicationAudioSourceChange
        self.onSleep = onSleep
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        observeCaptureDeviceNotifications()
        observeCoreAudioDeviceList()
        observeSleepWakeNotifications()
        observeApplicationActivation()
        observeApplicationAudioSourceNotifications()
    }

    private func observeCaptureDeviceNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: Notification.Name("AVCaptureDeviceWasConnectedNotification"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.refreshSoon()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: Notification.Name("AVCaptureDeviceWasDisconnectedNotification"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.refreshSoon()
                }
            }
        )
    }

    private func observeCoreAudioDeviceList() {
        observeCoreAudioAddress(deviceListAddress, handler: { [weak self] in
            self?.refreshSoon()
        })
        observeCoreAudioAddress(defaultOutputAddress, handler: { [weak self] in
            self?.recoverSoon()
        })
        observeCoreAudioAddress(defaultSystemOutputAddress, handler: { [weak self] in
            self?.recoverSoon()
        })
        observeCoreAudioAddress(processObjectListAddress, handler: { [weak self] in
            self?.applicationAudioSourceChangeSoon(changedBundleID: nil)
        })
    }

    private func observeCoreAudioAddress(
        _ propertyAddress: AudioObjectPropertyAddress,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = propertyAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            coreAudioQueue
        ) { _, _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    private func observeSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onSleep()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.recoverSoon()
                }
            }
        )
    }

    private func observeApplicationActivation() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onDeviceChange()
                }
            }
        )
    }

    private func observeApplicationAudioSourceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                let changedBundleID = Self.bundleID(fromWorkspaceNotification: notification)
                Task { @MainActor [weak self] in
                    self?.applicationAudioSourceChangeSoon(changedBundleID: changedBundleID)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                let changedBundleID = Self.bundleID(fromWorkspaceNotification: notification)
                Task { @MainActor [weak self] in
                    self?.applicationAudioSourceChangeSoon(changedBundleID: changedBundleID)
                }
            }
        )
    }

    private func refreshSoon() {
        onDeviceChange()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            onDeviceChange()
        }
    }

    private func recoverSoon() {
        onDeviceChange()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            onRecoverSettled()
        }
    }

    nonisolated private static func bundleID(fromWorkspaceNotification notification: Notification) -> String? {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }

    private func applicationAudioSourceChangeSoon(changedBundleID: String?) {
        if let changedBundleID {
            pendingApplicationAudioSourceBundleIDs.insert(changedBundleID)
        }
        applicationAudioSourceChangeDebouncer.schedule()
    }

    private func flushApplicationAudioSourceChange() {
        let changedBundleIDs = pendingApplicationAudioSourceBundleIDs
        pendingApplicationAudioSourceBundleIDs.removeAll(keepingCapacity: true)
        onApplicationAudioSourceChange(changedBundleIDs)
    }
}

@MainActor
enum StatusItemLayout {
    static let length: CGFloat = NSStatusItem.variableLength
}

enum StatusMenuPanelLayout {
    static let width: CGFloat = 360
    static let fallbackHeight: CGFloat = 420
    static let screenPadding: CGFloat = 8
    static let verticalGap: CGFloat = 8

    static var fallbackSize: NSSize {
        NSSize(width: width, height: fallbackHeight)
    }

    static func panelSize(fittingHeight: CGFloat, visibleFrame: NSRect) -> NSSize {
        let availableHeight = max(visibleFrame.height - (verticalGap * 2), 1)
        return NSSize(
            width: width,
            height: min(max(fittingHeight.rounded(.up), 1), availableHeight)
        )
    }

    static func frame(anchorFrame: NSRect, visibleFrame: NSRect, panelSize: NSSize = fallbackSize) -> NSRect {
        let minimumX = visibleFrame.minX + screenPadding
        let maximumX = visibleFrame.maxX - screenPadding - panelSize.width
        let centeredX = anchorFrame.midX - (panelSize.width / 2)
        let originX: CGFloat
        if maximumX >= minimumX {
            originX = min(max(centeredX, minimumX), maximumX)
        } else {
            originX = visibleFrame.midX - (panelSize.width / 2)
        }

        let preferredTop = min(anchorFrame.minY - verticalGap, visibleFrame.maxY - verticalGap)
        let originY = max(preferredTop - panelSize.height, visibleFrame.minY + verticalGap)

        return NSRect(
            x: originX.rounded(),
            y: originY.rounded(),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    static func shouldCloseForGlobalClick(location: NSPoint, statusItemFrame: NSRect, panelFrame: NSRect) -> Bool {
        !statusItemFrame.contains(location) && !panelFrame.contains(location)
    }
}

private final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

@MainActor
private final class StatusItemController: NSObject {
    private let model: AppStatusModel
    private let openSetup: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemLayout.length)
    private lazy var panel = makePanel()
    private var cancellable: AnyCancellable?
    private var applicationResignObserver: NSObjectProtocol?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var statusItemScreenFrame: NSRect = .zero
    private var isInstalled = false

    init(model: AppStatusModel, openSetup: @escaping () -> Void) {
        self.model = model
        self.openSetup = openSetup
        super.init()
    }

    func install() {
        guard !isInstalled else {
            return
        }
        isInstalled = true
        configurePanel()
        configureButton()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.configureButton()
            }
        }
        applicationResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel()
            }
        }
    }

    private func makePanel() -> StatusMenuPanel {
        let panel = StatusMenuPanel(
            contentRect: NSRect(origin: .zero, size: StatusMenuPanelLayout.fallbackSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        return panel
    }

    private func configurePanel() {
        panel.contentViewController = NSHostingController(
            rootView: StatusMenuPanelChrome {
                StatusMenuView(
                    model: model,
                    openSetup: { [weak self] in
                        self?.closePanel()
                        self?.openSetup()
                    }
                )
            }
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }
        button.title = "MCA"
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.image = NSImage(
            systemSymbolName: model.menuBarSystemImage,
            accessibilityDescription: "MixedCaptureAudio"
        )
        button.image?.size = NSSize(width: 18, height: 18)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "MixedCaptureAudio"
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: sender)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else {
            return
        }

        let anchorFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        statusItemScreenFrame = anchorFrame
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame
        let panelSize = preferredPanelSize(visibleFrame: visibleFrame)
        panel.setFrame(
            StatusMenuPanelLayout.frame(
                anchorFrame: anchorFrame,
                visibleFrame: visibleFrame,
                panelSize: panelSize
            ),
            display: true
        )
        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitorsAfterOpeningClick()
    }

    private func preferredPanelSize(visibleFrame: NSRect) -> NSSize {
        guard let contentView = panel.contentViewController?.view else {
            return StatusMenuPanelLayout.fallbackSize
        }
        contentView.setFrameSize(StatusMenuPanelLayout.fallbackSize)
        contentView.layoutSubtreeIfNeeded()
        return StatusMenuPanelLayout.panelSize(
            fittingHeight: contentView.fittingSize.height,
            visibleFrame: visibleFrame
        )
    }

    private func closePanel() {
        guard panel.isVisible else {
            removeEventMonitors()
            return
        }
        panel.orderOut(nil)
        removeEventMonitors()
    }

    private func installEventMonitorsAfterOpeningClick() {
        removeEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalEvent(event) ?? event
            }
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel.isVisible, self.globalEventMonitor == nil else {
                return
            }
            self.globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.closeAfterGlobalClickIfNeeded()
                }
            }
        }
    }

    private func closeAfterGlobalClickIfNeeded() {
        if StatusMenuPanelLayout.shouldCloseForGlobalClick(
            location: NSEvent.mouseLocation,
            statusItemFrame: statusItemScreenFrame,
            panelFrame: panel.frame
        ) {
            closePanel()
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else {
            return event
        }
        if event.type == .keyDown, event.keyCode == 53 {
            closePanel()
            return nil
        }
        if let eventWindow = event.window {
            if eventWindow == panel {
                return event
            }
            if eventWindow == statusItem.button?.window {
                return event
            }
        }
        closePanel()
        return event
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.applicationDidFinishLaunching()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            AppServices.shared.showSetupWindow()
        }
        return SetupWindowReopenPolicy.shouldAllowSystemDefaultWindowCreation
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppServices.shared.model.stopLiveMixer()
        }
    }
}

@MainActor
private final class SetupWindowPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var sourceLevelMeterPollingController: SourceLevelMeterPollingController?

    func show(
        model: AppStatusModel,
        sourceLevelMeterModel: SourceLevelMeterModel,
        sourceLevelMeterPollingController: SourceLevelMeterPollingController
    ) {
        self.sourceLevelMeterPollingController = sourceLevelMeterPollingController
        let setupWindow = window ?? makeWindow(
            model: model,
            sourceLevelMeterModel: sourceLevelMeterModel
        )
        window = setupWindow
        setupWindow.makeKeyAndOrderFront(nil)
        sourceLevelMeterPollingController.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(
        model: AppStatusModel,
        sourceLevelMeterModel: SourceLevelMeterModel
    ) -> NSWindow {
        let hostingView = NSHostingView(rootView: SetupView(
            model: model,
            sourceLevelMeterModel: sourceLevelMeterModel
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MixedCaptureAudio Setup"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        sourceLevelMeterPollingController?.stop()
    }
}
