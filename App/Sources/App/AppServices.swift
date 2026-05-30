import AppKit
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

enum AppTerminationSharedMemoryPolicy {
    static func shouldDiscardSharedMemory() -> Bool {
        false
    }
}

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

    func applicationWillTerminate() {
        healthPollingCancellable?.cancel()
        healthPollingCancellable = nil
        sourceLevelMeterPollingController.stop()
        model.terminateLiveMixerSynchronously()
        if AppTerminationSharedMemoryPolicy.shouldDiscardSharedMemory() {
            model.discardLiveMixerSharedMemory()
        }
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

@MainActor
final class StatusItemController: NSObject {
    private let model: AppStatusModel
    private let openSetup: @MainActor () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: StatusItemLayout.length)
    private lazy var statusMenuController = StatusMenuController(
        model: model,
        openSetup: openSetup
    )
    private var cancellable: AnyCancellable?
    private var isInstalled = false

    init(model: AppStatusModel, openSetup: @escaping @MainActor () -> Void) {
        self.model = model
        self.openSetup = openSetup
        super.init()
    }

    var statusItemForTesting: NSStatusItem {
        statusItem
    }

    func install() {
        guard !isInstalled else {
            return
        }
        isInstalled = true
        configureButton()
        statusItem.menu = statusMenuController.menu
        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.configureButton()
            }
        }
    }

    func uninstall() {
        guard isInstalled else {
            return
        }
        cancellable = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        isInstalled = false
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
        button.target = nil
        button.action = nil
        button.toolTip = "MixedCaptureAudio"
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
        AppServices.shared.applicationWillTerminate()
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
