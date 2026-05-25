import Foundation

@MainActor
@main
struct AppStatusModelTests {
    static func main() async {
        await testRequestMicrophoneAccessPromptsAndRefreshesGrantedState()
        await testDeniedMicrophoneAccessStillOffersRequestAction()
        await testSystemAudioAccessTestMapsReceivingAudioToReady()
        await testSystemAudioAccessTestMapsSilentCaptureToSilentGuidance()
        await testPrerequisiteRefreshPublishesDeviceNames()
        await testPrerequisiteRefreshPublishesDriverUpdateRequirement()
        await testLiveMixerWaitsWhenSystemAudioSetupIsUnverified()
        await testLiveMixerStartsWhenDurableSetupIsComplete()
        await testLiveMixerStartCompletionIsAsynchronous()
        await testStaleLiveMixerStartCompletionIsIgnored()
        await testLiveMixerStopCompletionIsAsynchronous()
        await testLiveMixerStopsWhenDurableSetupBecomesIncomplete()
        await testSelectingMicrophoneRestartsLiveMixerWithSelection()
        await testSelectedMicrophoneUnplugUsesTemporaryFallback()
        await testSelectedMicrophoneReturnRestoresSavedSelection()
        await testSelectedMicrophoneUnplugWithoutFallbackNeedsAttention()
        await testMicrophonePermissionRevocationStopsMixerAndNeedsSetup()
        await testDeviceConfigurationRecoveryRestartsMixerEvenWhenMicIsUnchanged()
        await testMicrophonePriorityChoosesFirstAvailableDevice()
        await testMicrophonePriorityFallsBackAndRestoresTopPriority()
        await testSelectedMicrophoneCanBeLowerThanTopPriority()
        await testMovingMicrophonePriorityDoesNotChangeSelectedActiveMic()
        await testSelectedMicrophoneUnavailableFallsBackByPriorityThenRestores()
        await testDroppingMicrophonePriorityBeforeTargetReordersOnce()
        await testDroppingMicrophonePriorityAtInsertionIndexReordersOnce()
        await testReorderingInactiveMicrophonesDoesNotRestartMixer()
        await testDeferredPriorityReorderSeparatesVisualMoveFromMixerRestart()
        await testMicrophonePriorityIgnoresInternalLiveMixerDevices()
        await testLiveHealthRefreshPublishesControllerSnapshot()
        await testLiveHealthRefreshClearsWhenControllerHasNoSnapshot()
        await testLaunchAtStartupStateRefreshesFromController()
        await testLaunchAtStartupToggleUpdatesControllerAndState()
        await testLaunchAtStartupToggleFailureIsReported()
        print("app status model tests passed")
    }

    private static func testRequestMicrophoneAccessPromptsAndRefreshesGrantedState() async {
        let checker = FakePrerequisiteChecker(
            snapshots: [
                PrerequisiteSnapshot(
                    driverStatus: .installed,
                    microphonePermission: .notDetermined,
                    selectedMicStatus: .available,
                    quickTimeDeviceStatus: .visible
                ),
                PrerequisiteSnapshot(
                    driverStatus: .installed,
                    microphonePermission: .granted,
                    selectedMicStatus: .available,
                    quickTimeDeviceStatus: .visible
                ),
            ]
        )
        let requester = FakeMicrophonePermissionRequester(granted: true)
        let model = AppStatusModel(
            prerequisiteChecker: checker,
            microphonePermissionRequester: requester,
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )

        model.refreshPrerequisites()
        model.systemAudioAccess = .receivingAudio
        await model.requestMicrophoneAccess()

        assertEqual(requester.requestCount, 1)
        assertEqual(model.microphonePermission, .granted)
        assertEqual(model.sessionState, .ready)
    }

    private static func testDeniedMicrophoneAccessStillOffersRequestAction() async {
        let checker = FakePrerequisiteChecker(
            snapshots: [
                PrerequisiteSnapshot(
                    driverStatus: .installed,
                    microphonePermission: .denied,
                    selectedMicStatus: .available,
                    quickTimeDeviceStatus: .visible
                ),
            ]
        )
        let requester = FakeMicrophonePermissionRequester(granted: true)
        let model = AppStatusModel(
            prerequisiteChecker: checker,
            microphonePermissionRequester: requester,
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )

        model.refreshPrerequisites()
        assertEqual(model.canRequestMicrophoneAccess, true)
        await model.requestMicrophoneAccess()

        assertEqual(requester.requestCount, 1)
        assertEqual(model.microphonePermission, .denied)
        assertEqual(model.microphoneFault, .permissionRevoked)
        assertEqual(model.sessionState, .failed)
    }

    private static func testSystemAudioAccessTestMapsReceivingAudioToReady() async {
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        await model.checkSystemAudioAccess()

        assertEqual(model.systemAudioAccess, .receivingAudio)
        assertEqual(model.sessionState, .ready)
    }

    private static func testPrerequisiteRefreshPublishesDriverUpdateRequirement() async {
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installedButNeedsReload,
                        driverUpdateRequirement: .reloadCoreAudio,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )

        model.refreshPrerequisites()

        assertEqual(model.driverUpdateRequirement, .reloadCoreAudio)
        assertEqual(model.driverStatus, .installedButNeedsReload)
    }

    private static func testSystemAudioAccessTestMapsSilentCaptureToSilentGuidance() async {
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .silent)
        )

        model.refreshPrerequisites()
        await model.checkSystemAudioAccess()

        assertEqual(model.systemAudioAccess, .silent)
        assertStringContains(model.systemAudioGuidance ?? "", "Play any sound")
        assertEqual(model.sessionState, .stopped)
    }

    private static func testPrerequisiteRefreshPublishesDeviceNames() async {
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible,
                        virtualAudioDeviceName: "Mixed Capture Audio",
                        selectedMicrophoneName: "Studio Mic"
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.virtualAudioDeviceName, "Mixed Capture Audio")
        assertEqual(model.selectedMicrophoneName, "Studio Mic")
    }

    private static func testLiveMixerWaitsWhenSystemAudioSetupIsUnverified() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller
        )

        model.refreshPrerequisites()

        assertEqual(controller.startCount, 0)
        assertEqual(model.liveMixerState, .stopped)
    }

    private static func testLiveMixerStartsWhenDurableSetupIsComplete() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(controller.startCount, 1)
        assertEqual(model.liveMixerState, .running)
    }

    private static func testLiveMixerStartCompletionIsAsynchronous() async {
        let controller = FakeLiveMixerController(automaticallyComplete: false)
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(controller.startCount, 1)
        assertEqual(model.liveMixerState, .starting)

        controller.completeStart(at: 0, result: .started)

        assertEqual(model.liveMixerState, .running)
    }

    private static func testStaleLiveMixerStartCompletionIsIgnored() async {
        let controller = FakeLiveMixerController(automaticallyComplete: false)
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                    PrerequisiteSnapshot(
                        driverStatus: .missing,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.refreshPrerequisites()
        controller.completeStart(at: 0, result: .started)

        assertEqual(model.liveMixerState, .stopped)
        assertEqual(model.sessionState, .stopped)
    }

    private static func testLiveMixerStopCompletionIsAsynchronous() async {
        let controller = FakeLiveMixerController(automaticallyComplete: false)
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        controller.completeStart(at: 0, result: .started)
        model.stopLiveMixer()

        assertEqual(controller.stopCount, 1)
        assertEqual(model.liveMixerState, .stopping)

        controller.completeStop(at: 0)

        assertEqual(model.liveMixerState, .stopped)
    }

    private static func testLiveMixerStopsWhenDurableSetupBecomesIncomplete() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .denied,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.refreshPrerequisites()

        assertEqual(controller.startCount, 1)
        assertEqual(controller.stopCount, 1)
        assertEqual(model.liveMixerState, .stopped)
    }

    private static func testSelectingMicrophoneRestartsLiveMixerWithSelection() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "mic-a", name: "Desk Mic"),
                    MicrophoneDevice(id: "mic-b", name: "Headset Mic"),
                ]
            ),
            microphoneSelectionStore: InMemoryMicrophoneSelectionStore(),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.selectMicrophone(id: "mic-b")

        assertEqual(controller.startCount, 2)
        assertEqual(controller.stopCount, 1)
        assertEqual(controller.lastStartedMicrophoneID, "mic-b")
        assertEqual(model.selectedMicrophoneName, "Headset Mic")
    }

    private static func testSelectedMicrophoneUnplugUsesTemporaryFallback() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeMicrophoneCatalog(
            devices: [
                MicrophoneDevice(id: "usb", name: "USB Mic"),
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
            ]
        )
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "usb"
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: catalog,
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.devices = [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
        model.refreshPrerequisites()

        assertEqual(store.selectedMicrophoneID, "usb")
        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneName, "MacBook Pro Microphone")
        assertEqual(model.microphoneFault, .usingFallback(selectedName: "USB Mic", fallbackName: "MacBook Pro Microphone"))
        assertEqual(model.sessionState, .degraded)
        assertEqual(model.liveMixerState, .running)
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
    }

    private static func testSelectedMicrophoneReturnRestoresSavedSelection() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeMicrophoneCatalog(
            devices: [
                MicrophoneDevice(id: "usb", name: "USB Mic"),
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
            ]
        )
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "usb"
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: catalog,
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.devices = [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
        model.refreshPrerequisites()
        catalog.devices = [
            MicrophoneDevice(id: "usb", name: "USB Mic"),
            MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
        ]
        model.refreshPrerequisites()

        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneName, "USB Mic")
        assertEqual(model.microphoneFault, .none)
        assertEqual(model.sessionState, .ready)
        assertEqual(controller.lastStartedMicrophoneID, "usb")
    }

    private static func testSelectedMicrophoneUnplugWithoutFallbackNeedsAttention() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeMicrophoneCatalog(
            devices: [MicrophoneDevice(id: "usb", name: "USB Mic")]
        )
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "usb"
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: catalog,
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.devices = []
        model.refreshPrerequisites()

        assertEqual(store.selectedMicrophoneID, "usb")
        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, nil)
        assertEqual(model.microphoneFault, .selectedUnavailable(selectedName: "USB Mic"))
        assertEqual(model.sessionState, .failed)
        assertEqual(model.liveMixerState, .running)
        assertEqual(controller.lastStartedMicrophoneID, LiveMixerMicrophoneID.noMicrophone)
    }

    private static func testMicrophonePermissionRevocationStopsMixerAndNeedsSetup() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    readySnapshot(),
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .denied,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .visible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
            ),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.refreshPrerequisites()

        assertEqual(model.microphonePermission, .denied)
        assertEqual(model.microphoneFault, .permissionRevoked)
        assertEqual(model.sessionState, .failed)
        assertEqual(model.liveMixerState, .stopped)
        assertEqual(controller.stopCount, 1)
    }

    private static func testDeviceConfigurationRecoveryRestartsMixerEvenWhenMicIsUnchanged() async {
        let controller = FakeLiveMixerController()
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
            ),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.recoverAfterDeviceConfigurationChange()

        assertEqual(controller.startCount, 2)
        assertEqual(controller.stopCount, 1)
        assertEqual(model.liveMixerState, .running)
        assertEqual(model.activeMicrophoneID, "built-in")
    }

    private static func testMicrophonePriorityChoosesFirstAvailableDevice() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["usb", "built-in"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.preferredMicrophoneIDs, ["usb", "built-in"])
        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, "usb")
        assertEqual(controller.lastStartedMicrophoneID, "usb")
    }

    private static func testMicrophonePriorityFallsBackAndRestoresTopPriority() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeMicrophoneCatalog(
            devices: [
                MicrophoneDevice(id: "usb", name: "USB Mic"),
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
            ]
        )
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["usb", "built-in"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: catalog,
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.devices = [MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone")]
        model.refreshPrerequisites()
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(model.microphoneFault, .usingFallback(selectedName: "USB Mic", fallbackName: "MacBook Pro Microphone"))

        catalog.devices = [
            MicrophoneDevice(id: "usb", name: "USB Mic"),
            MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
        ]
        model.refreshPrerequisites()

        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, "usb")
        assertEqual(model.microphoneFault, .none)
    }

    private static func testSelectedMicrophoneCanBeLowerThanTopPriority() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "built-in"
        store.preferredMicrophoneIDs = ["usb", "built-in"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.preferredMicrophoneIDs, ["usb", "built-in"])
        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(model.microphonePriorityItems.map(\.isSelected), [false, true])
        assertEqual(model.microphonePriorityItems.map(\.isActive), [false, true])
    }

    private static func testMovingMicrophonePriorityDoesNotChangeSelectedActiveMic() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "built-in"
        store.preferredMicrophoneIDs = ["built-in", "usb"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.moveMicrophonePriority(id: "usb", direction: .up)

        assertEqual(store.preferredMicrophoneIDs, ["usb", "built-in"])
        assertEqual(model.preferredMicrophoneIDs, ["usb", "built-in"])
        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)
    }

    private static func testSelectedMicrophoneUnavailableFallsBackByPriorityThenRestores() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeMicrophoneCatalog(
            devices: [
                MicrophoneDevice(id: "usb", name: "USB Mic"),
                MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
            ]
        )
        let store = InMemoryMicrophoneSelectionStore()
        store.selectedMicrophoneID = "built-in"
        store.preferredMicrophoneIDs = ["usb", "built-in", "teams"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: catalog,
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.devices = [
            MicrophoneDevice(id: "usb", name: "USB Mic"),
            MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
        ]
        model.refreshPrerequisites()

        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "usb")
        assertEqual(model.microphoneFault, .usingFallback(selectedName: "MacBook Pro Microphone", fallbackName: "USB Mic"))

        catalog.devices = [
            MicrophoneDevice(id: "usb", name: "USB Mic"),
            MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
            MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
        ]
        model.refreshPrerequisites()

        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(model.microphoneFault, .none)
    }

    private static func testDroppingMicrophonePriorityBeforeTargetReordersOnce() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["built-in", "teams", "usb"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.moveMicrophonePriority(draggedID: "usb", before: "built-in")

        assertEqual(store.preferredMicrophoneIDs, ["usb", "built-in", "teams"])
        assertEqual(model.preferredMicrophoneIDs, ["usb", "built-in", "teams"])
        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)
    }

    private static func testDroppingMicrophonePriorityAtInsertionIndexReordersOnce() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["built-in", "teams", "usb"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.moveMicrophonePriority(draggedID: "built-in", toInsertionIndex: 2)

        assertEqual(store.preferredMicrophoneIDs, ["teams", "built-in", "usb"])
        assertEqual(model.preferredMicrophoneIDs, ["teams", "built-in", "usb"])
        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)
    }

    private static func testReorderingInactiveMicrophonesDoesNotRestartMixer() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["built-in", "teams", "usb"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.moveMicrophonePriority(draggedID: "usb", toInsertionIndex: 1)

        assertEqual(store.preferredMicrophoneIDs, ["built-in", "usb", "teams"])
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)
    }

    private static func testDeferredPriorityReorderSeparatesVisualMoveFromMixerRestart() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = ["built-in", "teams", "usb"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "teams", name: "Microsoft Teams Audio"),
                    MicrophoneDevice(id: "usb", name: "USB Mic"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.moveMicrophonePriority(draggedID: "built-in", toInsertionIndex: 2, reconcileMixer: false)

        assertEqual(store.preferredMicrophoneIDs, ["teams", "built-in", "usb"])
        assertEqual(model.selectedMicrophoneID, "built-in")
        assertEqual(model.activeMicrophoneID, "built-in")
        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)

        model.reconcileLiveMixerAfterPriorityChange()

        assertEqual(controller.lastStartedMicrophoneID, "built-in")
        assertEqual(controller.startCount, 1)
    }

    private static func testMicrophonePriorityIgnoresInternalLiveMixerDevices() async {
        let controller = FakeLiveMixerController()
        let store = InMemoryMicrophoneSelectionStore()
        store.preferredMicrophoneIDs = [
            "built-in",
            "com.minamiktr.mca.live-mixer.AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "com.minamiktr.mca.live-mixer.FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        ]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            microphoneCatalog: FakeMicrophoneCatalog(
                devices: [
                    MicrophoneDevice(id: "built-in", name: "MacBook Pro Microphone"),
                    MicrophoneDevice(id: "com.minamiktr.mca.live-mixer.11111111-2222-3333-4444-555555555555", name: "MixedCaptureAudio Live Mixer"),
                ]
            ),
            microphoneSelectionStore: store,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.preferredMicrophoneIDs, ["built-in"])
        assertEqual(store.preferredMicrophoneIDs, ["built-in"])
        assertEqual(model.microphonePriorityItems.map(\.name), ["MacBook Pro Microphone"])
        assertEqual(model.activeMicrophoneID, "built-in")
    }

    private static func readyChecker() -> FakePrerequisiteChecker {
        FakePrerequisiteChecker(snapshots: [readySnapshot()])
    }

    private static func readySnapshot() -> PrerequisiteSnapshot {
        PrerequisiteSnapshot(
            driverStatus: .installed,
            microphonePermission: .granted,
            selectedMicStatus: .available,
            quickTimeDeviceStatus: .visible
        )
    }

    private static func testLiveHealthRefreshPublishesControllerSnapshot() async {
        let controller = FakeLiveMixerController()
        controller.healthSnapshot = HealthSnapshot(
            framesMixed: 96_000,
            systemUnderrunFrames: 0,
            micUnderrunFrames: 512,
            clippedSamples: 3,
            systemQueueFrames: 100,
            micQueueFrames: 612,
            sourceFrameDelta: -512,
            sourceFrameDeltaAbs: 512,
            systemDriftDropFrames: 0,
            micDriftDropFrames: 8,
            callbackErrorCount: 0
        )
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshLiveMixerHealth()

        assertEqual(model.lastHealthSnapshot.framesMixed, 96_000)
        assertEqual(model.lastHealthSnapshot.micUnderrunFrames, 512)
        assertEqual(model.lastHealthSnapshot.clippedSamples, 3)
        assertEqual(model.healthSummary.severity, .degraded)
    }

    private static func testLiveHealthRefreshClearsWhenControllerHasNoSnapshot() async {
        let controller = FakeLiveMixerController()
        controller.healthSnapshot = nil
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )
        model.lastHealthSnapshot = HealthSnapshot(
            framesMixed: 96_000,
            systemUnderrunFrames: 1,
            micUnderrunFrames: 0,
            clippedSamples: 0,
            systemQueueFrames: 0,
            micQueueFrames: 0,
            sourceFrameDelta: 0,
            sourceFrameDeltaAbs: 0,
            systemDriftDropFrames: 0,
            micDriftDropFrames: 0,
            callbackErrorCount: 0
        )

        model.refreshLiveMixerHealth()

        assertEqual(model.lastHealthSnapshot, .empty)
        assertEqual(model.healthSummary.severity, .good)
    }

    private static func testLaunchAtStartupStateRefreshesFromController() async {
        let launchController = FakeLaunchAtStartupController(status: .enabled)
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            launchAtStartupController: launchController
        )

        model.refreshLaunchAtStartupStatus()

        assertEqual(model.launchAtStartupStatus, .enabled)
        assertEqual(model.launchAtStartupErrorMessage, nil)
    }

    private static func testLaunchAtStartupToggleUpdatesControllerAndState() async {
        let launchController = FakeLaunchAtStartupController(status: .disabled)
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            launchAtStartupController: launchController
        )

        model.refreshLaunchAtStartupStatus()
        model.toggleLaunchAtStartup()

        assertEqual(launchController.lastSetEnabled, true)
        assertEqual(model.launchAtStartupStatus, .enabled)
        assertEqual(model.launchAtStartupErrorMessage, nil)
    }

    private static func testLaunchAtStartupToggleFailureIsReported() async {
        let launchController = FakeLaunchAtStartupController(status: .disabled)
        launchController.nextSetResult = .failed("Login item registration failed")
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            launchAtStartupController: launchController
        )

        model.refreshLaunchAtStartupStatus()
        model.toggleLaunchAtStartup()

        assertEqual(model.launchAtStartupStatus, .failed)
        assertEqual(model.launchAtStartupErrorMessage, "Login item registration failed")
    }
}

private final class FakePrerequisiteChecker: PrerequisiteChecking {
    private var snapshots: [PrerequisiteSnapshot]
    private var lastSnapshot: PrerequisiteSnapshot

    init(snapshots: [PrerequisiteSnapshot]) {
        self.snapshots = snapshots
        self.lastSnapshot = snapshots.last ?? PrerequisiteSnapshot(
            driverStatus: .missing,
            microphonePermission: .unknown,
            selectedMicStatus: .unknown,
            quickTimeDeviceStatus: .unknown
        )
    }

    func snapshot() -> PrerequisiteSnapshot {
        if snapshots.isEmpty {
            return lastSnapshot
        }
        lastSnapshot = snapshots.removeFirst()
        return lastSnapshot
    }
}

private final class FakeMicrophonePermissionRequester: MicrophonePermissionRequesting {
    private let granted: Bool
    private(set) var requestCount = 0

    init(granted: Bool) {
        self.granted = granted
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        return granted
    }
}

private struct FakeSystemAudioAccessTester: SystemAudioAccessTesting {
    let outcome: SystemAudioAccessTestOutcome

    func runSystemAudioAccessTest() async -> SystemAudioAccessTestOutcome {
        outcome
    }
}

private final class FakeLiveMixerController: LiveMixerControlling {
    private let automaticallyComplete: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastStartedMicrophoneID: String?
    var startResult: LiveMixerStartResult = .started
    var healthSnapshot: HealthSnapshot?
    private var isRunning = false
    private var startCompletions: [@MainActor (LiveMixerStartResult) -> Void] = []
    private var stopCompletions: [@MainActor () -> Void] = []

    init(automaticallyComplete: Bool = true) {
        self.automaticallyComplete = automaticallyComplete
    }

    @MainActor func start(microphoneID: String?, completion: @MainActor @escaping (LiveMixerStartResult) -> Void) {
        if isRunning {
            stopCount += 1
        }
        startCount += 1
        lastStartedMicrophoneID = microphoneID
        if automaticallyComplete {
            isRunning = startResult == .started
            completion(startResult)
        } else {
            startCompletions.append(completion)
        }
    }

    @MainActor func stop(completion: @MainActor @escaping () -> Void) {
        stopCount += 1
        if automaticallyComplete {
            isRunning = false
            completion()
        } else {
            stopCompletions.append(completion)
        }
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        healthSnapshot
    }

    @MainActor func completeStart(at index: Int, result: LiveMixerStartResult) {
        let completion = startCompletions[index]
        startCompletions.remove(at: index)
        isRunning = result == .started
        completion(result)
    }

    @MainActor func completeStop(at index: Int) {
        let completion = stopCompletions[index]
        stopCompletions.remove(at: index)
        isRunning = false
        completion()
    }
}

private final class FakeLaunchAtStartupController: LaunchAtStartupControlling {
    var status: LaunchAtStartupStatus
    var nextSetResult: LaunchAtStartupSetResult = .success(.enabled)
    private(set) var lastSetEnabled: Bool?

    init(status: LaunchAtStartupStatus) {
        self.status = status
    }

    func currentStatus() -> LaunchAtStartupStatus {
        status
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtStartupSetResult {
        lastSetEnabled = enabled
        switch nextSetResult {
        case let .success(status):
            self.status = status
            return .success(status)
        case .failed:
            return nextSetResult
        }
    }
}

private struct FakeMicrophoneCatalog: MicrophoneCataloging {
    let devices: [MicrophoneDevice]

    func availableMicrophones() -> [MicrophoneDevice] {
        devices
    }
}

private final class MutableFakeMicrophoneCatalog: MicrophoneCataloging {
    var devices: [MicrophoneDevice]

    init(devices: [MicrophoneDevice]) {
        self.devices = devices
    }

    func availableMicrophones() -> [MicrophoneDevice] {
        devices
    }
}

private final class InMemoryMicrophoneSelectionStore: MicrophoneSelectionStoring {
    var selectedMicrophoneID: String?
    var preferredMicrophoneIDs: [String] = []
}

private final class InMemorySystemAudioAccessStore: SystemAudioAccessStoring {
    var hasVerifiedSystemAudioAccess: Bool

    init(hasVerifiedSystemAudioAccess: Bool = false) {
        self.hasVerifiedSystemAudioAccess = hasVerifiedSystemAudioAccess
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func assertStringContains(_ value: String, _ expected: String, file: StaticString = #file, line: UInt = #line) {
    if !value.contains(expected) {
        fatalError("Expected string to contain \(expected)", file: file, line: line)
    }
}

private func assertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("Expected true", file: file, line: line)
    }
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if condition {
        fatalError("Expected false", file: file, line: line)
    }
}
