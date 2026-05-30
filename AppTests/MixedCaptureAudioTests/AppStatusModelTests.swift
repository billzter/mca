import AppKit
import Foundation
@testable import MixedCaptureAudio
import XCTest

final class AppStatusModelTests: XCTestCase {

    @MainActor
    func testRequestMicrophoneAccessPromptsAndRefreshesGrantedState() async {
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

    @MainActor
    func testLiveMixerControllerBeginsActivityAfterSuccessfulNativeStart() async {
        let nativeClient = FakeAppLiveMixerNativeClient(startStatus: 0)
        let activityAssertion = FakeLiveMixerActivityAssertion()
        let controller = AppLiveMixerController(
            nativeClient: nativeClient,
            activityAssertion: activityAssertion
        )

        let result = await startLiveMixer(controller)

        assertEqual(result, .started)
        assertEqual(nativeClient.startCount, 1)
        assertEqual(activityAssertion.beginCount, 1)
        assertEqual(activityAssertion.endCount, 0)
        assertEqual(activityAssertion.isActive, true)
    }

    @MainActor
    func testLiveMixerControllerStopEndsActivityAssertion() async {
        let nativeClient = FakeAppLiveMixerNativeClient(startStatus: 0)
        let activityAssertion = FakeLiveMixerActivityAssertion()
        let controller = AppLiveMixerController(
            nativeClient: nativeClient,
            activityAssertion: activityAssertion
        )

        _ = await startLiveMixer(controller)
        await stopLiveMixer(controller)

        assertEqual(nativeClient.stopCount, 1)
        assertEqual(activityAssertion.beginCount, 1)
        assertEqual(activityAssertion.endCount, 1)
        assertEqual(activityAssertion.isActive, false)
    }

    @MainActor
    func testLiveMixerControllerDiscardSharedMemoryEndsActivityAssertion() async {
        let nativeClient = FakeAppLiveMixerNativeClient(startStatus: 0)
        let activityAssertion = FakeLiveMixerActivityAssertion()
        let controller = AppLiveMixerController(
            nativeClient: nativeClient,
            activityAssertion: activityAssertion
        )

        _ = await startLiveMixer(controller)
        controller.discardSharedMemory()

        assertEqual(nativeClient.discardSharedMemoryCount, 1)
        assertEqual(activityAssertion.beginCount, 1)
        assertEqual(activityAssertion.endCount, 1)
        assertEqual(activityAssertion.isActive, false)
    }

    @MainActor
    func testLiveMixerControllerSynchronousTerminationStopClearsWithoutDiscardingSharedMemory() async {
        let nativeClient = FakeAppLiveMixerNativeClient(startStatus: 0)
        let activityAssertion = FakeLiveMixerActivityAssertion()
        let controller = AppLiveMixerController(
            nativeClient: nativeClient,
            activityAssertion: activityAssertion
        )

        _ = await startLiveMixer(controller)
        controller.stopSynchronouslyForTermination()

        assertEqual(nativeClient.stopCount, 1)
        assertEqual(nativeClient.discardSharedMemoryCount, 0)
        assertEqual(activityAssertion.beginCount, 1)
        assertEqual(activityAssertion.endCount, 1)
        assertEqual(activityAssertion.isActive, false)
    }

    @MainActor
    func testDiscardLiveMixerSharedMemoryStopsModelAndCallsController() {
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
            microphoneSelectionStore: {
                let store = InMemoryMicrophoneSelectionStore()
                store.selectedMicrophoneID = "mic-1"
                return store
            }(),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )
        model.refreshPrerequisites()
        model.liveMixerState = .running

        model.discardLiveMixerSharedMemory()

        assertEqual(controller.discardSharedMemoryCount, 1)
        assertEqual(model.liveMixerState, LiveMixerState.stopped)
    }

    @MainActor
    func testTerminateLiveMixerSynchronouslyStopsWithoutDiscardingSharedMemory() {
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
            microphoneSelectionStore: InMemoryMicrophoneSelectionStore(),
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )
        model.refreshPrerequisites()
        model.liveMixerState = .running

        model.terminateLiveMixerSynchronously()

        assertEqual(controller.stopSynchronouslyCount, 1)
        assertEqual(controller.stopCount, 0)
        assertEqual(controller.discardSharedMemoryCount, 0)
        assertEqual(model.liveMixerState, LiveMixerState.stopped)
    }

    @MainActor
    func testLiveMixerControllerFailedRestartEndsPreviousActivityAssertion() async {
        let nativeClient = FakeAppLiveMixerNativeClient(startStatus: 0)
        let activityAssertion = FakeLiveMixerActivityAssertion()
        let controller = AppLiveMixerController(
            nativeClient: nativeClient,
            activityAssertion: activityAssertion
        )

        _ = await startLiveMixer(controller)
        nativeClient.startStatus = -12
        let result = await startLiveMixer(controller)

        assertEqual(result, .failed(statusCode: -12))
        assertEqual(nativeClient.startCount, 2)
        assertEqual(activityAssertion.beginCount, 1)
        assertEqual(activityAssertion.endCount, 1)
        assertEqual(activityAssertion.isActive, false)
    }

    @MainActor
    func testDeniedMicrophoneAccessStillOffersRequestAction() async {
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

    @MainActor
    func testSystemAudioAccessTestMapsReceivingAudioToReady() async {
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

    @MainActor
    func testPrerequisiteRefreshPublishesDriverUpdateRequirement() async {
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

    @MainActor
    func testSystemAudioAccessTestMapsSilentCaptureToSilentGuidance() async {
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
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .silent),
            liveMixerController: controller
        )

        model.refreshPrerequisites()
        await model.checkSystemAudioAccess()

        assertEqual(model.systemAudioAccess, .silent)
        assertStringContains(model.systemAudioGuidance ?? "", "Play any sound")
        assertEqual(model.sessionState, .ready)
        assertEqual(model.liveMixerState, .running)
        assertEqual(controller.startCount, 1)
    }

    @MainActor
    func testLiveSystemAudioProofMarksReceivingAndPersists() async {
        let store = InMemorySystemAudioAccessStore()
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .silent),
            systemAudioAccessStore: store
        )

        model.markSystemAudioReceivingFromLiveProof()

        assertEqual(model.systemAudioAccess, .receivingAudio)
        assertEqual(store.hasVerifiedSystemAudioAccess, true)
    }

    @MainActor
    func testLiveSystemAudioProofIsIdempotent() async {
        let store = InMemorySystemAudioAccessStore()
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .silent),
            systemAudioAccessStore: store
        )

        model.markSystemAudioReceivingFromLiveProof()
        model.markSystemAudioReceivingFromLiveProof()

        assertEqual(model.systemAudioAccess, .receivingAudio)
        assertEqual(store.hasVerifiedSystemAudioAccess, true)
    }

    @MainActor
    func testLiveSystemAudioProofDoesNotMakeDurableSetupComplete() async {
        let model = AppStatusModel(
            prerequisiteChecker: FakePrerequisiteChecker(
                snapshots: [
                    PrerequisiteSnapshot(
                        driverStatus: .installed,
                        microphonePermission: .granted,
                        selectedMicStatus: .available,
                        quickTimeDeviceStatus: .notVisible
                    ),
                ]
            ),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .silent)
        )

        model.refreshPrerequisites()
        model.markSystemAudioReceivingFromLiveProof()

        assertEqual(model.systemAudioAccess, .receivingAudio)
        assertEqual(model.sessionState, .stopped)
    }

    @MainActor
    func testPrerequisiteRefreshPublishesDeviceNames() async {
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

    @MainActor
    func testLiveMixerStartsWhenSystemAudioSetupIsUnverified() async {
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

        assertEqual(controller.startCount, 1)
        assertEqual(model.liveMixerState, .running)
        assertEqual(model.sessionState, .ready)
        assertEqual(model.systemAudioAccess, .notTested)
    }

    @MainActor
    func testLiveMixerStartsWhenDurableSetupIsComplete() async {
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

    @MainActor
    func testLiveMixerStartFailurePreservesUntestedSystemAudioState() async {
        let controller = FakeLiveMixerController()
        controller.startResult = .failed(statusCode: -1)
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller
        )

        model.refreshPrerequisites()

        assertEqual(controller.startCount, 1)
        assertEqual(model.liveMixerState, .failed)
        assertEqual(model.sessionState, .failed)
        assertEqual(model.systemAudioAccess, .notTested)
    }

    @MainActor
    func testLiveMixerStartFailureExplainsNativeFailureCode() async {
        let controller = FakeLiveMixerController()
        controller.startResult = .failed(statusCode: -1)
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller
        )

        model.refreshPrerequisites()

        assertEqual(
            model.systemAudioGuidance,
            "System audio tap blocked. Allow MCA in Screen & System Audio Recording, then check again. (code -1)"
        )
    }

    @MainActor
    func testLiveMixerStartCompletionIsAsynchronous() async {
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

    @MainActor
    func testStaleLiveMixerStartCompletionIsIgnored() async {
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

    @MainActor
    func testLiveMixerStopCompletionIsAsynchronous() async {
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

    @MainActor
    func testLiveMixerStopsWhenDurableSetupBecomesIncomplete() async {
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

    @MainActor
    func testSelectingMicrophoneRestartsLiveMixerWithSelection() async {
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

    @MainActor
    func testSelectedAppCaptureModeStartsMixerWithSelectedBundleIDs() async {
        let controller = FakeLiveMixerController()
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                    AppAudioSource(bundleID: "com.apple.Safari", name: "Safari"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.captureMode, .selectedApps)
        assertEqual(model.appAudioSourceItems.map(\.bundleID), ["com.apple.Music", "com.apple.Safari"])
        assertEqual(controller.lastStartedConfiguration?.captureMode, .selectedApps)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music"])
    }

    @MainActor
    func testChangingSelectedAppsRestartsRunningMixer() async {
        let controller = FakeLiveMixerController()
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                    AppAudioSource(bundleID: "com.apple.Safari", name: "Safari"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.toggleAppAudioSource(bundleID: "com.apple.Safari")

        assertEqual(controller.startCount, 2)
        assertEqual(controller.stopCount, 1)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music", "com.apple.Safari"])
    }

    @MainActor
    func testSelectedAppModeWithoutSelectionDoesNotStartMixer() async {
        let controller = FakeLiveMixerController()
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(controller.startCount, 0)
        assertEqual(model.sessionState, .stopped)
        assertEqual(model.liveMixerState, .stopped)
    }

    @MainActor
    func testAddingFirstSelectedAppStartsBlockedSelectedAppMixer() async {
        let controller = FakeLiveMixerController()
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.toggleAppAudioSource(bundleID: "com.apple.Music")

        assertEqual(controller.startCount, 1)
        assertEqual(controller.lastStartedConfiguration?.captureMode, .selectedApps)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(model.sessionState, .ready)
        assertEqual(model.liveMixerState, .running)
    }

    @MainActor
    func testEditingSelectedAppsWhileInAllAppsDoesNotRestartMixerUntilModeSwitch() async {
        let controller = FakeLiveMixerController()
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .globalSystemAudio
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.toggleAppAudioSource(bundleID: "com.apple.Music")

        assertEqual(controller.startCount, 1)
        assertEqual(controller.lastStartedConfiguration?.captureMode, .globalSystemAudio)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, [])
        assertEqual(model.selectedAppBundleIDs, ["com.apple.Music"])

        model.selectCaptureMode(.selectedApps)

        assertEqual(controller.startCount, 2)
        assertEqual(controller.lastStartedConfiguration?.captureMode, .selectedApps)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music"])
    }

    @MainActor
    func testSelectedAppDisplayListHidesUnselectedAppsAndKeepsUnavailableSelections() async {
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music", "com.example.Missing"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            appAudioSourceCatalog: FakeAppAudioSourceCatalog(
                sources: [
                    AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
                    AppAudioSource(bundleID: "com.apple.Safari", name: "Safari"),
                ]
            ),
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()

        assertEqual(model.selectedAppAudioSourceItems.map(\.bundleID), ["com.apple.Music", "com.example.Missing"])
        assertEqual(model.selectedAppAudioSourceItems.map(\.isAvailable), [true, false])
    }

    @MainActor
    func testUnrelatedAppLaunchDoesNotRestartSelectedAppMixer() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeAppAudioSourceCatalog(
            sources: [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        )
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = [
            AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
            AppAudioSource(bundleID: "com.apple.Safari", name: "Safari"),
        ]
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(controller.startCount, 1)
        assertEqual(controller.stopCount, 0)
        assertEqual(model.appAudioSourceItems.map(\.bundleID), ["com.apple.Music", "com.apple.Safari"])
    }

    @MainActor
    func testSelectedAppLaunchRestartsSelectedAppMixer() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeAppAudioSourceCatalog(sources: [])
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(controller.startCount, 2)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedAppQuitRestartsDegradesAndKeepsSelection() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeAppAudioSourceCatalog(
            sources: [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        )
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = []
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(controller.startCount, 2)
        assertEqual(appStore.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(model.selectedAppAudioSourceItems.map(\.bundleID), ["com.apple.Music"])
        assertEqual(model.selectedAppAudioSourceItems.map(\.isAvailable), [false])
        assertEqual(model.sessionState, .degraded)
    }

    @MainActor
    func testSelectedAppRelaunchCapturesAgainWithoutReselecting() async {
        let controller = FakeLiveMixerController()
        let catalog = MutableFakeAppAudioSourceCatalog(sources: [])
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(appStore.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(controller.startCount, 2)
        assertEqual(controller.lastStartedConfiguration?.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedAppProcessRestoreFallsBackOnSelectedAppRelaunch() async {
        let controller = FakeLiveMixerController()
        controller.supportsSelectedAppProcessRestore = true
        let catalog = MutableFakeAppAudioSourceCatalog(sources: [])
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["com.apple.Music"])
        catalog.sources = []
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["com.apple.Music"])
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["com.apple.Music"])

        assertEqual(controller.startCount, 3)
        assertEqual(controller.stopCount, 2)
        assertEqual(appStore.selectedAppBundleIDs, ["com.apple.Music"])
        assertEqual(model.selectedAppAudioSourceItems.map(\.bundleID), ["com.apple.Music"])
        assertEqual(model.selectedAppAudioSourceItems.map(\.isAvailable), [true])
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedAppProcessRestoreFallsBackWhenAvailabilityLagsLaunch() async {
        let controller = FakeLiveMixerController()
        controller.supportsSelectedAppProcessRestore = true
        let catalog = MutableFakeAppAudioSourceCatalog(sources: [])
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["com.apple.Music"])
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(controller.startCount, 2)
        assertEqual(controller.stopCount, 1)
        assertEqual(model.selectedAppAudioSourceItems.map(\.isAvailable), [true])
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedAppProcessRestoreDelayedFallbackExpiresWhenAppStaysUnavailable() async {
        let controller = FakeLiveMixerController()
        controller.supportsSelectedAppProcessRestore = true
        let catalog = MutableFakeAppAudioSourceCatalog(sources: [])
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["com.apple.Music"])
        model.recoverAfterApplicationAudioSourceChange()
        model.recoverAfterApplicationAudioSourceChange()
        catalog.sources = [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        model.recoverAfterApplicationAudioSourceChange()

        assertEqual(controller.startCount, 1)
        assertEqual(controller.stopCount, 0)
        assertEqual(model.selectedAppAudioSourceItems.map(\.isAvailable), [true])
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedAppProcessRestoreIgnoresUnrelatedAppChurn() async {
        let controller = FakeLiveMixerController()
        controller.supportsSelectedAppProcessRestore = true
        let catalog = MutableFakeAppAudioSourceCatalog(
            sources: [AppAudioSource(bundleID: "com.apple.Music", name: "Music")]
        )
        let appStore = InMemoryAppAudioSelectionStore()
        appStore.captureMode = .selectedApps
        appStore.selectedAppBundleIDs = ["com.apple.Music"]
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            appAudioSourceCatalog: catalog,
            appAudioSelectionStore: appStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        catalog.sources = [
            AppAudioSource(bundleID: "com.apple.Music", name: "Music"),
            AppAudioSource(bundleID: "org.mozilla.firefox", name: "Firefox"),
        ]
        model.recoverAfterApplicationAudioSourceChange(changedBundleIDs: ["org.mozilla.firefox"])

        assertEqual(controller.startCount, 1)
        assertEqual(controller.stopCount, 0)
        assertEqual(model.sessionState, .ready)
    }

    @MainActor
    func testSelectedMicrophoneUnplugUsesTemporaryFallback() async {
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

    @MainActor
    func testSelectedMicrophoneReturnRestoresSavedSelection() async {
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

    @MainActor
    func testSelectedMicrophoneUnplugWithoutFallbackNeedsAttention() async {
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

    @MainActor
    func testMicrophonePermissionRevocationStopsMixerAndNeedsSetup() async {
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

    @MainActor
    func testDeviceConfigurationRecoveryRestartsMixerEvenWhenMicIsUnchanged() async {
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

    @MainActor
    func testMicrophonePriorityChoosesFirstAvailableDevice() async {
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

    @MainActor
    func testMicrophonePriorityFallsBackAndRestoresTopPriority() async {
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

    @MainActor
    func testSelectedMicrophoneCanBeLowerThanTopPriority() async {
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

    @MainActor
    func testSelectingLowerPriorityMicrophoneDoesNotReseedMissingStoredPriority() async {
        let controller = FakeLiveMixerController()
        let store = AppMicrophoneSelectionStore(defaults: isolatedDefaults())
        store.selectedMicrophoneID = "built-in"
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
        model.selectMicrophone(id: "usb")

        assertEqual(model.preferredMicrophoneIDs, ["built-in", "usb"])
        assertEqual(store.preferredMicrophoneIDs, ["built-in", "usb"])
        assertEqual(model.selectedMicrophoneID, "usb")
        assertEqual(model.activeMicrophoneID, "usb")
        assertEqual(model.microphonePriorityItems.map(\.isSelected), [false, true])
        assertEqual(model.microphonePriorityItems.map(\.isActive), [false, true])
    }

    @MainActor
    func testMovingMicrophonePriorityDoesNotChangeSelectedActiveMic() async {
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

    @MainActor
    func testSelectedMicrophoneUnavailableFallsBackByPriorityThenRestores() async {
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

    @MainActor
    func testDroppingMicrophonePriorityBeforeTargetReordersOnce() async {
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

    @MainActor
    func testDroppingMicrophonePriorityAtInsertionIndexReordersOnce() async {
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

    @MainActor
    func testReorderingInactiveMicrophonesDoesNotRestartMixer() async {
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

    @MainActor
    func testDeferredPriorityReorderSeparatesVisualMoveFromMixerRestart() async {
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

    @MainActor
    func testMicrophonePriorityIgnoresInternalLiveMixerDevices() async {
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

    @MainActor
    func testChangingAudioLevelsUpdatesLiveMixerWithoutRestart() async {
        let controller = FakeLiveMixerController()
        let audioLevelStore = InMemoryAudioLevelSettingsStore(
            settings: AudioLevelSettings(systemDecibels: -6.0, microphoneDecibels: 6.0)
        )
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            audioLevelSettingsStore: audioLevelStore,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshPrerequisites()
        let startsAfterRefresh = controller.startCount

        model.setMicrophoneLevelDecibels(18.0)
        model.setEnhanceVoice(false)

        assertEqual(controller.startCount, startsAfterRefresh)
        assertEqual(controller.stopCount, 0)
        assertEqual(controller.setAudioLevelCount, 4)
        assertEqual(controller.lastAudioLevelSettings?.microphoneDecibels, AudioLevelSettings.maximumDecibels)
        assertEqual(controller.lastAudioLevelSettings?.enhanceVoice, false)
        assertEqual(audioLevelStore.settings.microphoneDecibels, AudioLevelSettings.maximumDecibels)
        assertEqual(audioLevelStore.settings.enhanceVoice, false)
    }

    private func readyChecker() -> FakePrerequisiteChecker {
        FakePrerequisiteChecker(snapshots: [readySnapshot()])
    }

    private func readySnapshot() -> PrerequisiteSnapshot {
        PrerequisiteSnapshot(
            driverStatus: .installed,
            microphonePermission: .granted,
            selectedMicStatus: .available,
            quickTimeDeviceStatus: .visible
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "com.minamiktr.mca.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    func testLiveHealthRefreshPublishesControllerSnapshot() async {
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

    @MainActor
    func testLiveHealthRefreshPublishesRecentMenuHealthSeparatelyFromCumulativeDiagnostics() async {
        let controller = FakeLiveMixerController()
        var snapshot = HealthSnapshot.cleanRunning
        snapshot.micUnderrunFrames = 512
        controller.healthSnapshot = snapshot
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshLiveMixerHealth()
        snapshot.framesMixed += 48_000
        controller.healthSnapshot = snapshot
        model.refreshLiveMixerHealth()

        XCTAssertEqual(model.healthSummary.severity, .degraded)
        XCTAssertEqual(model.recentHealthSummary.severity, .healthy)
        XCTAssertEqual(model.recentHealthSummary.title, "Healthy")
    }

    @MainActor
    func testLiveHealthRefreshIgnoresSharedRingOverrunWhenNoRecorderIsActive() async {
        let controller = FakeLiveMixerController()
        controller.virtualAudioDeviceRunning = false
        var snapshot = HealthSnapshot.cleanRunning
        controller.healthSnapshot = snapshot
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshLiveMixerHealth()
        snapshot.sharedRingFillFrames = 12_000
        snapshot.sharedRingFillErrorFrames = 9_600
        snapshot.sharedRingFillErrorAbsFrames = 9_600
        snapshot.sharedRingOverrunFrames = 91_200
        controller.healthSnapshot = snapshot
        model.refreshLiveMixerHealth()

        XCTAssertEqual(model.recentHealthSummary.severity, .healthy)
        XCTAssertEqual(model.recentHealthSummary.title, "Healthy")
    }

    @MainActor
    func testLiveHealthRefreshResetsRecentMenuHealthWhenControllerHasNoSnapshot() async {
        let controller = FakeLiveMixerController()
        controller.healthSnapshot = .cleanRunning
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        model.refreshLiveMixerHealth()
        controller.healthSnapshot = nil
        model.refreshLiveMixerHealth()

        XCTAssertEqual(model.recentHealthSummary, .noActiveSession)
    }

    @MainActor
    func testMenuHealthPresentationUsesStatusToneAndIcon() async {
        let healthy = MenuStatusPresentation(recentHealthSummary: .healthy)
        let degraded = MenuStatusPresentation(
            recentHealthSummary: RecentHealthSummary(
                severity: .degraded,
                title: "Degraded",
                detail: "Microphone underrun"
            )
        )
        let failed = MenuStatusPresentation(
            recentHealthSummary: RecentHealthSummary(
                severity: .failed,
                title: "Failed",
                detail: "Audio callback error"
            )
        )
        let neutral = MenuStatusPresentation(recentHealthSummary: .noActiveSession)

        XCTAssertEqual(healthy.value, "Healthy")
        XCTAssertEqual(healthy.tone, .good)
        XCTAssertEqual(healthy.systemImageName, "checkmark.circle.fill")
        XCTAssertEqual(degraded.value, "Degraded - Microphone underrun")
        XCTAssertEqual(degraded.tone, .warning)
        XCTAssertEqual(failed.value, "Failed - Audio callback error")
        XCTAssertEqual(failed.tone, .error)
        XCTAssertEqual(neutral.value, "No active session")
        XCTAssertEqual(neutral.tone, .neutral)
    }

    @MainActor
    func testStatusMenuActionsDoNotIncludeRefresh() async {
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )

        XCTAssertFalse(model.statusMenuActions.map(\.title).contains("Refresh"))
    }

    @MainActor
    func testStatusItemUsesVariableLengthWithFixedIconSize() {
        XCTAssertEqual(StatusItemLayout.length, NSStatusItem.variableLength)
    }

    @MainActor
    func testNativeStatusMenuBuildsStatusRowsAndActionsWithoutRefresh() async throws {
        let liveMixerController = FakeLiveMixerController()
        liveMixerController.virtualAudioDeviceRunning = true
        liveMixerController.healthSnapshot = HealthSnapshot(
            framesMixed: 96_000,
            systemUnderrunFrames: 0,
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
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: liveMixerController
        )
        model.refreshPrerequisites()
        model.selectedMicrophoneName = "MacBook Pro Microphone"
        model.systemAudioAccess = .receivingAudio
        model.liveMixerState = .running
        model.refreshLiveMixerHealth()

        let controller = StatusMenuController(model: model, openSetup: {}, terminate: {})
        controller.menuWillOpen(controller.menu)

        let rowViews = controller.menu.items.compactMap { $0.view as? StatusMenuStatusRowView }

        XCTAssertEqual(rowViews.map(\.titleText), ["Device", "Mic", "System", "Mixer", "Health"])
        XCTAssertEqual(rowViews.map(\.symbolName), Array(repeating: "checkmark.circle.fill", count: 5))
        XCTAssertNotNil(controller.menu.item(withTitle: "Launch at startup"))
        XCTAssertNotNil(controller.menu.item(withTitle: "Check System Audio"))
        XCTAssertNotNil(controller.menu.item(withTitle: "Open Setup"))
        XCTAssertNotNil(controller.menu.item(withTitle: "Quit"))
        XCTAssertNil(controller.menu.item(withTitle: "Refresh"))
    }

    @MainActor
    func testStatusItemControllerInstallsNativeMenuInsteadOfButtonAction() {
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )
        let controller = StatusItemController(model: model, openSetup: {})
        controller.install()
        defer { controller.uninstall() }

        let statusItem = controller.statusItemForTesting
        XCTAssertNotNil(statusItem.menu)
        XCTAssertNil(statusItem.button?.action)
        XCTAssertEqual(statusItem.length, NSStatusItem.variableLength)
    }

    @MainActor
    func testLaunchAtStartupToggleIsViewBackedToAvoidCommandMenuDismissal() async throws {
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )
        let controller = StatusMenuController(model: model, openSetup: {}, terminate: {})
        controller.menuWillOpen(controller.menu)

        let launchItem = try XCTUnwrap(controller.menu.item(withTitle: "Launch at startup"))

        XCTAssertNil(launchItem.action)
        XCTAssertNil(launchItem.target)
        XCTAssertNotNil(launchItem.view)
    }

    @MainActor
    func testLaunchAtStartupViewToggleUpdatesStateInPlace() async throws {
        let launchController = FakeLaunchAtStartupController(status: .disabled)
        launchController.nextSetResult = .success(.enabled)
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            launchAtStartupController: launchController
        )
        model.refreshLaunchAtStartupStatus()

        let controller = StatusMenuController(model: model, openSetup: {}, terminate: {})
        controller.menuWillOpen(controller.menu)
        let launchView = try XCTUnwrap(
            controller.menu.item(withTitle: "Launch at startup")?.view as? StatusMenuLaunchAtStartupView
        )
        let launchItem = try XCTUnwrap(controller.menu.item(withTitle: "Launch at startup"))

        XCTAssertFalse(launchView.isChecked)
        XCTAssertEqual(launchView.statusText, "Off")
        XCTAssertEqual(launchItem.toolTip, "Off")

        launchView.performToggleForTesting()

        XCTAssertEqual(launchController.lastSetEnabled, true)
        XCTAssertTrue(launchView.isChecked)
        XCTAssertEqual(launchView.statusText, "On")
        XCTAssertEqual(launchItem.toolTip, "On")
    }

    @MainActor
    func testNativeStatusMenuUpdatesVisibleRowsWhenModelStateChanges() async throws {
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )
        model.refreshPrerequisites()
        let controller = StatusMenuController(model: model, openSetup: {}, terminate: {})
        controller.menuWillOpen(controller.menu)
        let systemRow = try XCTUnwrap(
            controller.menu.items
                .compactMap { $0.view as? StatusMenuStatusRowView }
                .first { $0.titleText == "System" }
        )

        model.systemAudioAccess = .receivingAudio
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(systemRow.valueText, "Receiving audio")
        XCTAssertEqual(systemRow.symbolName, "checkmark.circle.fill")
    }

    @MainActor
    func testNativeStatusMenuUpdatesHeaderWhenPrimaryStatusChanges() async throws {
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio)
        )
        model.sessionState = .ready
        let controller = StatusMenuController(model: model, openSetup: {}, terminate: {})
        controller.menuWillOpen(controller.menu)
        let headerView = try XCTUnwrap(
            controller.menu.items
                .compactMap { $0.view as? StatusMenuHeaderView }
                .first
        )

        XCTAssertEqual(headerView.accessibilityLabel(), "MixedCaptureAudio, Ready")

        model.sessionState = .running
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(headerView.accessibilityLabel(), "MixedCaptureAudio, Running")
    }

    @MainActor
    func testLiveHealthRefreshShowsRecorderActiveWhenVirtualDeviceIsRunning() async {
        let controller = FakeLiveMixerController()
        controller.virtualAudioDeviceRunning = true
        controller.healthSnapshot = HealthSnapshot(
            framesMixed: 96_000,
            systemUnderrunFrames: 0,
            micUnderrunFrames: 0,
            clippedSamples: 0,
            systemQueueFrames: 0,
            micQueueFrames: 0,
            sourceFrameDelta: 0,
            sourceFrameDeltaAbs: 0,
            systemDriftDropFrames: 0,
            micDriftDropFrames: 0,
            callbackErrorCount: 0,
            sharedRingFillFrames: 12_000,
            sharedRingFillErrorFrames: 9_600,
            sharedRingFillErrorAbsFrames: 9_600,
            sharedRingOverrunFrames: 0
        )
        let model = AppStatusModel(
            prerequisiteChecker: readyChecker(),
            microphonePermissionRequester: FakeMicrophonePermissionRequester(granted: true),
            systemAudioAccessTester: FakeSystemAudioAccessTester(outcome: .receivingAudio),
            liveMixerController: controller,
            systemAudioAccessStore: InMemorySystemAudioAccessStore(hasVerifiedSystemAudioAccess: true)
        )

        for _ in 0..<6 {
            model.refreshLiveMixerHealth()
        }
        controller.healthSnapshot?.sharedRingOverrunFrames = 91_200
        model.refreshLiveMixerHealth()

        assertEqual(model.sharedRingStats.status, .recorderActive)
        assertStringContains(model.sharedRingStats.compactValue, "Recorder Active")
    }

    @MainActor
    func testLiveHealthRefreshClearsWhenControllerHasNoSnapshot() async {
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
        assertEqual(model.recentHealthSummary, .noActiveSession)
    }

    @MainActor
    func testLaunchAtStartupStateRefreshesFromController() async {
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

    @MainActor
    func testLaunchAtStartupToggleUpdatesControllerAndState() async {
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

    @MainActor
    func testLaunchAtStartupToggleFailureIsReported() async {
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
    private(set) var stopSynchronouslyCount = 0
    private(set) var discardSharedMemoryCount = 0
    private(set) var setAudioLevelCount = 0
    private(set) var lastStartedMicrophoneID: String?
    private(set) var lastStartedConfiguration: LiveMixerStartConfiguration?
    private(set) var lastAudioLevelSettings: AudioLevelSettings?
    var supportsSelectedAppProcessRestore = false
    var startResult: LiveMixerStartResult = .started
    var healthSnapshot: HealthSnapshot?
    var sourceLevelSnapshot: SourceLevelMeterSnapshot?
    var virtualAudioDeviceRunning = false
    private var isRunning = false
    private var startCompletions: [@MainActor (LiveMixerStartResult) -> Void] = []
    private var stopCompletions: [@MainActor () -> Void] = []

    init(automaticallyComplete: Bool = true) {
        self.automaticallyComplete = automaticallyComplete
    }

    @MainActor func start(
        configuration: LiveMixerStartConfiguration,
        completion: @MainActor @escaping (LiveMixerStartResult) -> Void
    ) {
        if isRunning {
            stopCount += 1
        }
        startCount += 1
        lastStartedMicrophoneID = configuration.microphoneID
        lastStartedConfiguration = configuration
        if automaticallyComplete {
            isRunning = startResult.isStarted
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

    @MainActor func stopSynchronouslyForTermination() {
        stopSynchronouslyCount += 1
        isRunning = false
    }

    @MainActor func discardSharedMemory() {
        discardSharedMemoryCount += 1
        isRunning = false
    }

    @MainActor func setAudioLevels(_ settings: AudioLevelSettings) {
        setAudioLevelCount += 1
        lastAudioLevelSettings = settings
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        healthSnapshot
    }

    @MainActor func currentSourceLevelSnapshot() -> SourceLevelMeterSnapshot? {
        sourceLevelSnapshot
    }

    @MainActor func isVirtualAudioDeviceRunning() -> Bool {
        virtualAudioDeviceRunning
    }

    @MainActor func completeStart(at index: Int, result: LiveMixerStartResult) {
        let completion = startCompletions[index]
        startCompletions.remove(at: index)
        isRunning = result.isStarted
        completion(result)
    }

    @MainActor func completeStop(at index: Int) {
        let completion = stopCompletions[index]
        stopCompletions.remove(at: index)
        isRunning = false
        completion()
    }
}

private extension LiveMixerStartResult {
    var isStarted: Bool {
        switch self {
        case .started:
            true
        case .failed:
            false
        }
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

private struct FakeAppAudioSourceCatalog: AppAudioSourceCataloging {
    let sources: [AppAudioSource]

    func availableAppAudioSources() -> [AppAudioSource] {
        sources
    }
}

private final class MutableFakeAppAudioSourceCatalog: AppAudioSourceCataloging {
    var sources: [AppAudioSource]

    init(sources: [AppAudioSource]) {
        self.sources = sources
    }

    func availableAppAudioSources() -> [AppAudioSource] {
        sources
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

private final class InMemoryAppAudioSelectionStore: AppAudioSelectionStoring {
    var captureMode: ProgramAudioCaptureMode = .globalSystemAudio
    var selectedAppBundleIDs: [String] = []
}

private final class InMemoryAudioLevelSettingsStore: AudioLevelSettingsStoring {
    var settings: AudioLevelSettings

    init(settings: AudioLevelSettings = AudioLevelSettings()) {
        self.settings = settings
    }
}

private final class InMemorySystemAudioAccessStore: SystemAudioAccessStoring {
    var hasVerifiedSystemAudioAccess: Bool

    init(hasVerifiedSystemAudioAccess: Bool = false) {
        self.hasVerifiedSystemAudioAccess = hasVerifiedSystemAudioAccess
    }
}

@MainActor
private func startLiveMixer(_ controller: AppLiveMixerController) async -> LiveMixerStartResult {
    await withCheckedContinuation { continuation in
        controller.start(
            configuration: LiveMixerStartConfiguration(
                microphoneID: nil,
                captureMode: .globalSystemAudio,
                selectedAppBundleIDs: []
            )
        ) { result in
            continuation.resume(returning: result)
        }
    }
}

@MainActor
private func stopLiveMixer(_ controller: AppLiveMixerController) async {
    await withCheckedContinuation { continuation in
        controller.stop {
            continuation.resume()
        }
    }
}

private final class FakeAppLiveMixerNativeClient: AppLiveMixerNativeControlling, @unchecked Sendable {
    var startStatus: Int32
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var discardSharedMemoryCount = 0

    init(startStatus: Int32) {
        self.startStatus = startStatus
    }

    func start(
        microphoneID: String?,
        captureMode: Int32,
        selectedAppBundleIDs: String
    ) -> Int32 {
        startCount += 1
        return startStatus
    }

    func stop() {
        stopCount += 1
    }

    func discardSharedMemory() -> Int32 {
        discardSharedMemoryCount += 1
        return 0
    }

    func setAudioLevels(systemGain: Float, microphoneGain: Float) -> Int32 {
        0
    }

    func setVoiceEnhancement(enabled: Bool) -> Int32 {
        0
    }

    func copyHealthCounters(_ counters: UnsafeMutableBufferPointer<UInt64>) -> Int32 {
        0
    }

    func copyLevels(outSystemPeak: UnsafeMutablePointer<Float>, outMicPeak: UnsafeMutablePointer<Float>) -> Int32 {
        0
    }

    func supportsSelectedAppProcessRestore() -> Bool {
        true
    }
}

private final class FakeLiveMixerActivityAssertion: LiveMixerActivityAsserting, @unchecked Sendable {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var isActive = false

    func begin() {
        beginCount += 1
        isActive = true
    }

    func end() {
        endCount += 1
        isActive = false
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func assertStringContains(_ value: String, _ expected: String, file: StaticString = #file, line: UInt = #line) {
    if !value.contains(expected) {
        XCTFail("Expected string to contain \(expected)", file: file, line: line)
    }
}

private func assertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(condition, file: file, line: line)
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertFalse(condition, file: file, line: line)
}
