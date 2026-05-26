import Combine
import Foundation

@MainActor
final class AppStatusModel: ObservableObject {
    private let prerequisiteChecker: PrerequisiteChecking
    private let microphonePermissionRequester: MicrophonePermissionRequesting
    private let systemAudioAccessTester: SystemAudioAccessTesting
    private let liveMixerController: LiveMixerControlling
    private let microphoneCatalog: MicrophoneCataloging
    private let microphoneSelectionStore: MicrophoneSelectionStoring
    private let appAudioSourceCatalog: AppAudioSourceCataloging
    private let appAudioSelectionStore: AppAudioSelectionStoring
    private let systemAudioAccessStore: SystemAudioAccessStoring
    private let launchAtStartupController: LaunchAtStartupControlling

    @Published var sessionState: CaptureSessionState = .stopped
    @Published var liveMixerState: LiveMixerState = .stopped
    @Published var driverStatus: AudioDeviceStatus = .unknown
    @Published var driverUpdateRequirement: DriverUpdateRequirement = .none
    @Published var microphonePermission: PermissionStatus = .unknown
    @Published var systemAudioAccess: SystemAudioAccessStatus = .notTested
    @Published var selectedMicStatus: SelectedDeviceStatus = .unknown
    @Published var quickTimeDeviceStatus: QuickTimeDeviceStatus = .unknown
    @Published var virtualAudioDeviceName: String?
    @Published var selectedMicrophoneName: String?
    @Published var activeMicrophoneName: String?
    @Published var availableMicrophones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID: String?
    @Published var activeMicrophoneID: String?
    @Published var preferredMicrophoneIDs: [String] = []
    @Published var microphonePriorityItems: [MicrophonePriorityItem] = []
    @Published var microphoneFault: MicrophoneFault = .none
    @Published var captureMode: ProgramAudioCaptureMode = .globalSystemAudio
    @Published var appAudioSourceItems: [AppAudioSourceItem] = []
    @Published var selectedAppAudioSourceItems: [AppAudioSourceItem] = []
    @Published var selectedAppBundleIDs: [String] = []
    @Published var lastHealthSnapshot: HealthSnapshot = .empty
    @Published var sharedRingStats: SharedRingStats = .empty
    @Published var launchAtStartupStatus: LaunchAtStartupStatus = .unknown
    @Published var launchAtStartupErrorMessage: String?
    private var runningMixerConfiguration: LiveMixerStartConfiguration?
    private var pendingMixerConfiguration: LiveMixerStartConfiguration?
    private var mixerCommandGeneration: UInt64 = 0
    private var lastKnownSelectedMicrophoneName: String?
    private var knownMicrophoneNames: [String: String] = [:]
    private var knownAppAudioSourceNames: [String: String] = [:]
    private var sharedRingStatsAccumulator = SharedRingStatsAccumulator()
    private var pendingSelectedAppRestoreFallbacks: [String: Int] = [:]
    private let selectedAppRestoreFallbackRecoveryPasses = 3

    init(
        prerequisiteChecker: PrerequisiteChecking,
        microphonePermissionRequester: MicrophonePermissionRequesting,
        systemAudioAccessTester: SystemAudioAccessTesting,
        liveMixerController: LiveMixerControlling = NullLiveMixerController(),
        microphoneCatalog: MicrophoneCataloging = EmptyMicrophoneCatalog(),
        microphoneSelectionStore: MicrophoneSelectionStoring = VolatileMicrophoneSelectionStore(),
        appAudioSourceCatalog: AppAudioSourceCataloging = EmptyAppAudioSourceCatalog(),
        appAudioSelectionStore: AppAudioSelectionStoring = VolatileAppAudioSelectionStore(),
        systemAudioAccessStore: SystemAudioAccessStoring = VolatileSystemAudioAccessStore(),
        launchAtStartupController: LaunchAtStartupControlling = NullLaunchAtStartupController()
    ) {
        self.prerequisiteChecker = prerequisiteChecker
        self.microphonePermissionRequester = microphonePermissionRequester
        self.systemAudioAccessTester = systemAudioAccessTester
        self.liveMixerController = liveMixerController
        self.microphoneCatalog = microphoneCatalog
        self.microphoneSelectionStore = microphoneSelectionStore
        self.appAudioSourceCatalog = appAudioSourceCatalog
        self.appAudioSelectionStore = appAudioSelectionStore
        self.systemAudioAccessStore = systemAudioAccessStore
        self.launchAtStartupController = launchAtStartupController
        captureMode = appAudioSelectionStore.captureMode
        selectedAppBundleIDs = appAudioSelectionStore.selectedAppBundleIDs
        refreshAppAudioSources()
        if systemAudioAccessStore.hasVerifiedSystemAudioAccess {
            systemAudioAccess = .proceedUnverified
        }
    }

    var healthSummary: HealthDiagnosticSummary {
        HealthDiagnosticSummary(snapshot: lastHealthSnapshot)
    }

    var menuBarSystemImage: String {
        switch healthSummary.severity {
        case .good:
            "waveform"
        case .degraded:
            "waveform.badge.exclamationmark"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var primaryStatusLine: String {
        switch sessionState {
        case .stopped:
            "Stopped"
        case .checkingPrerequisites:
            "Checking prerequisites"
        case .requestingPermissions:
            "Requesting permissions"
        case .ready:
            "Ready"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .degraded:
            "Degraded"
        case .stopping:
            "Stopping"
        case .failed:
            "Failed"
        }
    }

    var setupSummary: String {
        "Driver \(driverStatus.rawValue), microphone \(microphonePermission.rawValue), system audio \(systemAudioAccess.rawValue)"
    }

    var microphoneStatusText: String {
        switch microphoneFault {
        case .none:
            activeMicrophoneName ?? selectedMicrophoneName ?? "Choose a microphone"
        case let .usingFallback(_, fallbackName):
            "\(fallbackName) (temporary)"
        case let .selectedUnavailable(selectedName):
            "\(selectedName) unavailable"
        case .permissionRevoked:
            "Microphone access required"
        }
    }

    var microphoneChecklistStatus: String {
        switch microphoneFault {
        case .none:
            microphonePermission.rawValue
        case .usingFallback:
            CaptureSessionState.degraded.rawValue
        case .selectedUnavailable:
            SelectedDeviceStatus.missing.rawValue
        case .permissionRevoked:
            microphonePermission.rawValue
        }
    }

    var microphoneFaultGuidance: String? {
        switch microphoneFault {
        case .none:
            nil
        case let .usingFallback(selectedName, fallbackName):
            "\(selectedName) is unavailable. MixedCaptureAudio is temporarily using \(fallbackName) so QuickTime can keep recording."
        case let .selectedUnavailable(selectedName):
            "\(selectedName) is unavailable and no fallback microphone is available. Reconnect it or choose another microphone."
        case .permissionRevoked:
            "Microphone access is off. Open System Settings and allow MixedCaptureAudio to use the microphone."
        }
    }

    var canRequestMicrophoneAccess: Bool {
        switch microphonePermission {
        case .unknown, .notDetermined, .denied, .restricted, .failed:
            true
        case .requesting, .granted:
            false
        }
    }

    var microphoneDeniedGuidance: String? {
        switch microphonePermission {
        case .denied, .restricted:
            "Microphone access is off. Try requesting access here. If macOS does not show a prompt, open System Settings and allow MixedCaptureAudio to use the microphone."
        default:
            nil
        }
    }

    var liveMixerDisplayStatus: String {
        switch liveMixerState {
        case .stopped:
            "Standby"
        case .starting:
            "Starting"
        case .running:
            "Available"
        case .stopping:
            "Stopping"
        case .failed:
            "Needs attention"
        }
    }

    var canCheckSystemAudioAccess: Bool {
        switch systemAudioAccess {
        case .starting, .started, .waitingForSignal:
            false
        case .unknown, .notTested, .promptExpected, .receivingAudio, .silent, .proceedUnverified, .deniedOrUnavailable, .failed:
            true
        }
    }

    var launchAtStartupIsEnabled: Bool {
        launchAtStartupStatus == .enabled
    }

    var launchAtStartupDisplayStatus: String {
        switch launchAtStartupStatus {
        case .unknown:
            "Unknown"
        case .disabled:
            "Off"
        case .enabled:
            "On"
        case .requiresApproval:
            "Needs approval"
        case .failed:
            "Failed"
        }
    }

    var systemAudioGuidance: String? {
        switch systemAudioAccess {
        case .promptExpected:
            "The next step may show a macOS system audio recording prompt."
        case .waitingForSignal:
            "Play any sound to confirm system audio."
        case .silent:
            "Play any sound, then run the system audio test again."
        case .deniedOrUnavailable:
            "System audio access is off. Open System Settings, go to Privacy & Security, then Screen & System Audio Recording, and allow MixedCaptureAudio. Return here and click Check Again."
        case .failed:
            "System audio access appears unavailable. Check System Settings, then try again. If this continues, restart the app."
        default:
            nil
        }
    }

    func refreshPrerequisites() {
        sessionState = .checkingPrerequisites
        apply(snapshot: prerequisiteChecker.snapshot())
    }

    func refreshLaunchAtStartupStatus() {
        launchAtStartupStatus = launchAtStartupController.currentStatus()
        if launchAtStartupStatus != .failed {
            launchAtStartupErrorMessage = nil
        }
    }

    func toggleLaunchAtStartup() {
        let shouldEnable = launchAtStartupStatus != .enabled
        switch launchAtStartupController.setEnabled(shouldEnable) {
        case let .success(status):
            launchAtStartupStatus = status
            launchAtStartupErrorMessage = nil
        case let .failed(message):
            launchAtStartupStatus = .failed
            launchAtStartupErrorMessage = message
        }
    }

    func recoverAfterDeviceConfigurationChange() {
        sessionState = .checkingPrerequisites
        apply(snapshot: prerequisiteChecker.snapshot(), forceMixerRestart: true)
    }

    func recoverAfterApplicationAudioSourceChange(changedBundleIDs: Set<String> = []) {
        let previousSignature = selectedAppAvailabilitySignature
        refreshAppAudioSources()
        sessionState = resolvedSessionState(durableSetupComplete: hasCompletedDurableSetup)
        let selectedAppAvailabilityChanged = previousSignature != selectedAppAvailabilitySignature
        guard captureMode == .selectedApps else {
            pendingSelectedAppRestoreFallbacks.removeAll(keepingCapacity: true)
            return
        }

        if liveMixerController.supportsSelectedAppProcessRestore {
            rememberSelectedAppRestoreFallbacks(from: changedBundleIDs)
        }
        let delayedFallbackBundleIDs = consumeAvailableSelectedAppRestoreFallbacks()
        let shouldForceRestart =
            (selectedAppAvailabilityChanged && !liveMixerController.supportsSelectedAppProcessRestore) ||
            !delayedFallbackBundleIDs.isEmpty

        if shouldForceRestart {
            reconcileLiveMixer(forceRestart: true)
        }
    }

    func selectMicrophone(id: String) {
        guard availableMicrophones.contains(where: { $0.id == id }) else {
            return
        }
        microphoneSelectionStore.selectedMicrophoneID = id
        refreshAvailableMicrophones(
            fallbackName: selectedMicrophoneName,
            microphonePermission: microphonePermission
        )
        reconcileLiveMixer()
    }

    func selectCaptureMode(_ mode: ProgramAudioCaptureMode) {
        guard captureMode != mode else {
            return
        }
        captureMode = mode
        appAudioSelectionStore.captureMode = mode
        refreshAppAudioSources()
        pendingSelectedAppRestoreFallbacks.removeAll(keepingCapacity: true)
        sessionState = resolvedSessionState(durableSetupComplete: hasCompletedDurableSetup)
        reconcileLiveMixer()
    }

    func toggleAppAudioSource(bundleID: String) {
        guard appAudioSourceItems.contains(where: { $0.bundleID == bundleID }) else {
            return
        }
        var selected = selectedAppBundleIDs
        if let index = selected.firstIndex(of: bundleID) {
            selected.remove(at: index)
        } else {
            selected.append(bundleID)
        }
        appAudioSelectionStore.selectedAppBundleIDs = selected
        selectedAppBundleIDs = appAudioSelectionStore.selectedAppBundleIDs
        refreshAppAudioSources()
        pendingSelectedAppRestoreFallbacks.removeAll(keepingCapacity: true)
        sessionState = resolvedSessionState(durableSetupComplete: hasCompletedDurableSetup)
        reconcileLiveMixer()
    }

    func moveMicrophonePriority(id: String, direction: MicrophonePriorityMoveDirection) {
        var ids = normalizedPriorityIDs(from: microphoneSelectionStore.preferredMicrophoneIDs)
        guard let index = ids.firstIndex(of: id) else {
            return
        }

        let destination: Int
        switch direction {
        case .up:
            destination = ids.index(before: index)
        case .down:
            destination = ids.index(after: index)
        }
        guard ids.indices.contains(destination) else {
            return
        }

        ids.swapAt(index, destination)
        microphoneSelectionStore.preferredMicrophoneIDs = ids
        refreshAvailableMicrophones(
            fallbackName: selectedMicrophoneName,
            microphonePermission: microphonePermission
        )
        reconcileLiveMixer()
    }

    func moveMicrophonePriority(from source: IndexSet, to destination: Int) {
        var ids = normalizedPriorityIDs(from: microphoneSelectionStore.preferredMicrophoneIDs)
        moveElements(in: &ids, from: source, to: destination)
        microphoneSelectionStore.preferredMicrophoneIDs = ids
        refreshAvailableMicrophones(
            fallbackName: selectedMicrophoneName,
            microphonePermission: microphonePermission
        )
        reconcileLiveMixer()
    }

    func moveMicrophonePriority(draggedID: String, before targetID: String) {
        guard draggedID != targetID else {
            return
        }
        var ids = normalizedPriorityIDs(from: microphoneSelectionStore.preferredMicrophoneIDs)
        guard let draggedIndex = ids.firstIndex(of: draggedID) else {
            return
        }
        let dragged = ids.remove(at: draggedIndex)
        let targetIndex = ids.firstIndex(of: targetID) ?? ids.endIndex
        ids.insert(dragged, at: targetIndex)
        microphoneSelectionStore.preferredMicrophoneIDs = ids
        refreshAvailableMicrophones(
            fallbackName: selectedMicrophoneName,
            microphonePermission: microphonePermission
        )
        reconcileLiveMixer()
    }

    func moveMicrophonePriority(
        draggedID: String,
        toInsertionIndex insertionIndex: Int,
        reconcileMixer: Bool = true
    ) {
        var ids = normalizedPriorityIDs(from: microphoneSelectionStore.preferredMicrophoneIDs)
        guard let sourceIndex = ids.firstIndex(of: draggedID) else {
            return
        }

        var destinationIndex = insertionIndex
        if sourceIndex < insertionIndex {
            destinationIndex -= 1
        }
        destinationIndex = max(0, min(ids.count - 1, destinationIndex))
        guard destinationIndex != sourceIndex else {
            return
        }

        let dragged = ids.remove(at: sourceIndex)
        ids.insert(dragged, at: destinationIndex)
        microphoneSelectionStore.preferredMicrophoneIDs = ids
        refreshAvailableMicrophones(
            fallbackName: selectedMicrophoneName,
            microphonePermission: microphonePermission
        )
        if reconcileMixer {
            reconcileLiveMixer()
        }
    }

    func reconcileLiveMixerAfterPriorityChange() {
        reconcileLiveMixer()
    }

    private func moveElements<T>(in values: inout [T], from source: IndexSet, to destination: Int) {
        let moving = source.map { values[$0] }
        for index in source.sorted(by: >) {
            values.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = max(0, min(values.count, destination - removedBeforeDestination))
        values.insert(contentsOf: moving, at: insertionIndex)
    }

    func stopLiveMixer() {
        let shouldStop = liveMixerState == .running || liveMixerState == .starting || liveMixerState == .failed
        mixerCommandGeneration += 1
        let generation = mixerCommandGeneration
        pendingMixerConfiguration = nil
        runningMixerConfiguration = nil
        activeMicrophoneID = nil
        activeMicrophoneName = nil

        if shouldStop {
            let wasRunning = liveMixerState == .running || liveMixerState == .failed
        liveMixerState = wasRunning ? .stopping : .stopped
            liveMixerController.stop { [weak self] in
                self?.completeLiveMixerStop(generation: generation)
            }
        } else {
            liveMixerState = .stopped
        }
    }

    func refreshLiveMixerHealth() {
        guard let snapshot = liveMixerController.currentHealthSnapshot() else {
            sharedRingStatsAccumulator.reset()
            sharedRingStats = .empty
            if lastHealthSnapshot != .empty {
                lastHealthSnapshot = .empty
            }
            return
        }
        if snapshot != lastHealthSnapshot {
            lastHealthSnapshot = snapshot
        }
        if snapshot.framesMixed == 0 {
            sharedRingStatsAccumulator.reset()
        } else {
            sharedRingStatsAccumulator.record(
                snapshot: snapshot,
                recorderActive: liveMixerController.isVirtualAudioDeviceRunning()
            )
        }
        if sharedRingStats != sharedRingStatsAccumulator.summary {
            sharedRingStats = sharedRingStatsAccumulator.summary
        }
    }

    func requestMicrophoneAccess() async {
        guard canRequestMicrophoneAccess else {
            refreshPrerequisites()
            return
        }

        sessionState = .requestingPermissions
        microphonePermission = .requesting
        let granted = await microphonePermissionRequester.requestAccess()
        var snapshot = prerequisiteChecker.snapshot()
        if snapshot.microphonePermission == .unknown || snapshot.microphonePermission == .notDetermined {
            snapshot.microphonePermission = granted ? .granted : .denied
        }
        apply(snapshot: snapshot)
    }

    func checkSystemAudioAccess() async {
        guard canCheckSystemAudioAccess else {
            return
        }

        systemAudioAccess = .promptExpected
        sessionState = .checkingPrerequisites
        systemAudioAccess = .starting
        systemAudioAccess = .waitingForSignal
        let outcome = await systemAudioAccessTester.runSystemAudioAccessTest()
        switch outcome {
        case .receivingAudio:
            systemAudioAccess = .receivingAudio
            systemAudioAccessStore.hasVerifiedSystemAudioAccess = true
        case .silent:
            systemAudioAccess = .silent
        case .deniedOrUnavailable:
            systemAudioAccess = .deniedOrUnavailable
            systemAudioAccessStore.hasVerifiedSystemAudioAccess = false
        case .failed:
            systemAudioAccess = .failed
        }

        let snapshot = prerequisiteChecker.snapshot()
        apply(snapshot: snapshot)
    }

    private func apply(snapshot: PrerequisiteSnapshot, forceMixerRestart: Bool = false) {
        driverStatus = snapshot.driverStatus
        driverUpdateRequirement = snapshot.driverUpdateRequirement
        microphonePermission = snapshot.microphonePermission
        selectedMicStatus = snapshot.selectedMicStatus
        quickTimeDeviceStatus = snapshot.quickTimeDeviceStatus
        virtualAudioDeviceName = snapshot.virtualAudioDeviceName
        captureMode = appAudioSelectionStore.captureMode
        selectedAppBundleIDs = appAudioSelectionStore.selectedAppBundleIDs
        refreshAppAudioSources()
        refreshAvailableMicrophones(
            fallbackName: snapshot.selectedMicrophoneName,
            microphonePermission: snapshot.microphonePermission
        )
        selectedMicrophoneName = selectedMicrophoneName ?? snapshot.selectedMicrophoneName
        sessionState = resolvedSessionState(snapshot: snapshot)
        reconcileLiveMixer(forceRestart: forceMixerRestart)
    }

    private func resolvedSessionState(snapshot: PrerequisiteSnapshot) -> CaptureSessionState {
        resolvedSessionState(durableSetupComplete: hasCompletedDurableSetup(snapshot: snapshot))
    }

    private func resolvedSessionState(durableSetupComplete: Bool) -> CaptureSessionState {
        if appAudioSelectionBlocksMixer {
            return .stopped
        }
        switch microphoneFault {
        case .usingFallback:
            return durableSetupComplete ? .degraded : .stopped
        case .selectedUnavailable, .permissionRevoked:
            return .failed
        case .none:
            if durableSetupComplete && hasUnavailableSelectedAppSelection {
                return .degraded
            }
            return durableSetupComplete ? .ready : .stopped
        }
    }

    private var hasCompletedDurableSetup: Bool {
        driverStatus == .installed &&
            microphonePermission == .granted &&
            selectedMicStatus == .available &&
            quickTimeDeviceStatus == .visible
    }

    private func hasCompletedDurableSetup(snapshot: PrerequisiteSnapshot) -> Bool {
        snapshot.driverStatus == .installed &&
            snapshot.microphonePermission == .granted &&
            snapshot.selectedMicStatus == .available &&
            snapshot.quickTimeDeviceStatus == .visible
    }

    private var hasCompletedOperationalSetup: Bool {
        hasCompletedDurableSetup &&
            !microphoneFaultBlocksMixer &&
            !appAudioSelectionBlocksMixer
    }

    private var microphoneFaultBlocksMixer: Bool {
        switch microphoneFault {
        case .permissionRevoked:
            true
        case .none, .usingFallback, .selectedUnavailable:
            false
        }
    }

    private var appAudioSelectionBlocksMixer: Bool {
        captureMode == .selectedApps && selectedAppBundleIDs.isEmpty
    }

    private var hasUnavailableSelectedAppSelection: Bool {
        captureMode == .selectedApps && selectedAppAudioSourceItems.contains { !$0.isAvailable }
    }

    private var selectedAppAvailabilitySignature: [String: Bool] {
        Dictionary(uniqueKeysWithValues: selectedAppAudioSourceItems.map { ($0.bundleID, $0.isAvailable) })
    }

    private func rememberSelectedAppRestoreFallbacks(from bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else {
            return
        }
        for bundleID in bundleIDs where selectedAppBundleIDs.contains(bundleID) {
            pendingSelectedAppRestoreFallbacks[bundleID] = selectedAppRestoreFallbackRecoveryPasses
        }
    }

    private func consumeAvailableSelectedAppRestoreFallbacks() -> Set<String> {
        guard !pendingSelectedAppRestoreFallbacks.isEmpty else {
            return []
        }

        let availableSelectedBundleIDs = Set(
            selectedAppAudioSourceItems
                .filter(\.isAvailable)
                .map(\.bundleID)
        )
        let availableFallbacks = Set(
            pendingSelectedAppRestoreFallbacks.keys.filter { availableSelectedBundleIDs.contains($0) }
        )
        if !availableFallbacks.isEmpty {
            for bundleID in availableFallbacks {
                pendingSelectedAppRestoreFallbacks.removeValue(forKey: bundleID)
            }
            return availableFallbacks
        }

        for (bundleID, remainingPasses) in pendingSelectedAppRestoreFallbacks {
            if remainingPasses <= 1 {
                pendingSelectedAppRestoreFallbacks.removeValue(forKey: bundleID)
            } else {
                pendingSelectedAppRestoreFallbacks[bundleID] = remainingPasses - 1
            }
        }
        return []
    }

    private func refreshAppAudioSources() {
        let availableSources = appAudioSourceCatalog.availableAppAudioSources()
        for source in availableSources {
            knownAppAudioSourceNames[source.bundleID] = source.name
        }

        selectedAppBundleIDs = sanitizedAppBundleIDs(appAudioSelectionStore.selectedAppBundleIDs)
        if selectedAppBundleIDs != appAudioSelectionStore.selectedAppBundleIDs {
            appAudioSelectionStore.selectedAppBundleIDs = selectedAppBundleIDs
        }

        let availableByBundleID = Dictionary(uniqueKeysWithValues: availableSources.map { ($0.bundleID, $0) })
        var orderedBundleIDs = availableSources.map(\.bundleID)
        for bundleID in selectedAppBundleIDs where !orderedBundleIDs.contains(bundleID) {
            orderedBundleIDs.append(bundleID)
        }

        appAudioSourceItems = orderedBundleIDs.map { bundleID in
            let source = availableByBundleID[bundleID]
            return AppAudioSourceItem(
                bundleID: bundleID,
                name: source?.name ?? knownAppAudioSourceNames[bundleID] ?? bundleID,
                isAvailable: source != nil,
                isSelected: selectedAppBundleIDs.contains(bundleID)
            )
        }
        selectedAppAudioSourceItems = appAudioSourceItems.filter(\.isSelected)
    }

    private func sanitizedAppBundleIDs(_ bundleIDs: [String]) -> [String] {
        var result: [String] = []
        for bundleID in bundleIDs where !bundleID.isEmpty && !result.contains(bundleID) {
            result.append(bundleID)
        }
        return result
    }

    private func refreshAvailableMicrophones(fallbackName: String?, microphonePermission: PermissionStatus) {
        availableMicrophones = microphoneCatalog.availableMicrophones()
            .filter { isUserSelectableMicrophoneID($0.id) }
        for microphone in availableMicrophones {
            knownMicrophoneNames[microphone.id] = microphone.name
        }

        let storedIDsBeforeNormalization = microphoneSelectionStore.preferredMicrophoneIDs
        let storedIDs = sanitizedPriorityIDs(storedIDsBeforeNormalization)
        let normalizedIDs = normalizedPriorityIDs(from: storedIDs)
        if normalizedIDs != storedIDsBeforeNormalization {
            microphoneSelectionStore.preferredMicrophoneIDs = normalizedIDs
        }
        preferredMicrophoneIDs = normalizedIDs

        switch microphonePermission {
        case .denied, .restricted, .failed:
            selectedMicrophoneName = selectedMicrophoneName ?? fallbackName
            activeMicrophoneID = nil
            activeMicrophoneName = nil
            microphoneFault = .permissionRevoked
            microphonePriorityItems = priorityItems(from: normalizedIDs)
            return
        default:
            break
        }

        let availableByID = Dictionary(uniqueKeysWithValues: availableMicrophones.map { ($0.id, $0) })
        let selectedID = selectedMicrophoneID(from: normalizedIDs, availableByID: availableByID)
        selectedMicrophoneID = selectedID
        microphoneSelectionStore.selectedMicrophoneID = selectedID

        guard let selectedID else {
            selectedMicrophoneName = fallbackName
            activeMicrophoneID = nil
            activeMicrophoneName = nil
            microphoneFault = .none
            microphonePriorityItems = []
            return
        }

        if let selectedDevice = availableByID[selectedID] {
            selectedMicrophoneName = selectedDevice.name
            lastKnownSelectedMicrophoneName = selectedDevice.name
        } else {
            selectedMicrophoneName = knownMicrophoneNames[selectedID] ?? lastKnownSelectedMicrophoneName ?? fallbackName ?? "Selected microphone"
        }

        let fallbackIDs = normalizedIDs.filter { $0 != selectedID }
        let activeDevice = availableByID[selectedID] ?? fallbackIDs.compactMap { availableByID[$0] }.first
        if let activeDevice {
            activeMicrophoneID = activeDevice.id
            activeMicrophoneName = activeDevice.name
            if activeDevice.id == selectedID {
                microphoneFault = .none
            } else {
                microphoneFault = .usingFallback(
                    selectedName: selectedMicrophoneName ?? "Selected microphone",
                    fallbackName: activeDevice.name
                )
            }
        } else {
            activeMicrophoneID = nil
            activeMicrophoneName = nil
            microphoneFault = .selectedUnavailable(selectedName: selectedMicrophoneName ?? "Selected microphone")
        }

        microphonePriorityItems = priorityItems(from: normalizedIDs)
    }

    private func normalizedPriorityIDs(from storedIDs: [String]) -> [String] {
        var result: [String] = []
        func appendUnique(_ id: String?) {
            guard let id, isUserSelectableMicrophoneID(id), !result.contains(id) else {
                return
            }
            result.append(id)
        }

        for id in storedIDs {
            appendUnique(id)
        }
        appendUnique(microphoneSelectionStore.selectedMicrophoneID)
        for microphone in availableMicrophones {
            appendUnique(microphone.id)
        }
        return result
    }

    private func selectedMicrophoneID(
        from normalizedIDs: [String],
        availableByID: [String: MicrophoneDevice]
    ) -> String? {
        if let storedSelectedID = microphoneSelectionStore.selectedMicrophoneID,
           isUserSelectableMicrophoneID(storedSelectedID),
           normalizedIDs.contains(storedSelectedID) || knownMicrophoneNames[storedSelectedID] != nil {
            return storedSelectedID
        }
        return normalizedIDs.first ?? availableByID.keys.sorted().first
    }

    private func sanitizedPriorityIDs(_ ids: [String]) -> [String] {
        var result: [String] = []
        for id in ids where isUserSelectableMicrophoneID(id) && !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private func isUserSelectableMicrophoneID(_ id: String) -> Bool {
        !id.isEmpty &&
            id != LiveMixerMicrophoneID.noMicrophone &&
            !id.hasPrefix("com.minamiktr.mca.")
    }

    private func priorityItems(from ids: [String]) -> [MicrophonePriorityItem] {
        let availableByID = Dictionary(uniqueKeysWithValues: availableMicrophones.map { ($0.id, $0) })
        return ids.map { id in
            let device = availableByID[id]
            return MicrophonePriorityItem(
                id: id,
                name: device?.name ?? knownMicrophoneNames[id] ?? "Unavailable microphone",
                isAvailable: device != nil,
                isActive: id == activeMicrophoneID,
                isSelected: id == selectedMicrophoneID
            )
        }
    }

    private func reconcileLiveMixer(forceRestart: Bool = false) {
        guard hasCompletedOperationalSetup else {
            stopLiveMixer()
            return
        }

        let configuration = activeMixerConfiguration
        if !forceRestart && liveMixerState == .running && runningMixerConfiguration == configuration {
            return
        }
        if !forceRestart && liveMixerState == .starting && pendingMixerConfiguration == configuration {
            return
        }

        restartLiveMixerIfNeeded()
    }

    private func restartLiveMixerIfNeeded() {
        guard hasCompletedOperationalSetup else {
            stopLiveMixer()
            return
        }

        let configuration = activeMixerConfiguration
        mixerCommandGeneration += 1
        let generation = mixerCommandGeneration
        pendingMixerConfiguration = configuration
        liveMixerState = .starting

        liveMixerController.start(configuration: configuration) { [weak self] result in
            self?.completeLiveMixerStart(
                generation: generation,
                configuration: configuration,
                result: result
            )
        }
    }

    private func completeLiveMixerStart(
        generation: UInt64,
        configuration: LiveMixerStartConfiguration,
        result: LiveMixerStartResult
    ) {
        guard generation == mixerCommandGeneration else {
            return
        }
        pendingMixerConfiguration = nil
        switch result {
        case .started:
            runningMixerConfiguration = configuration
            liveMixerState = .running
        case .failed:
            runningMixerConfiguration = nil
            liveMixerState = .failed
            sessionState = .failed
            systemAudioAccess = .failed
        }
    }

    private func completeLiveMixerStop(generation: UInt64) {
        guard generation == mixerCommandGeneration else {
            return
        }
        pendingMixerConfiguration = nil
        runningMixerConfiguration = nil
        liveMixerState = .stopped
    }

    private var activeMixerConfiguration: LiveMixerStartConfiguration {
        LiveMixerStartConfiguration(
            microphoneID: activeMixerMicrophoneID,
            captureMode: captureMode,
            selectedAppBundleIDs: captureMode == .selectedApps ? selectedAppBundleIDs : []
        )
    }

    private var activeMixerMicrophoneID: String? {
        switch microphoneFault {
        case .selectedUnavailable:
            LiveMixerMicrophoneID.noMicrophone
        case .none, .usingFallback, .permissionRevoked:
            activeMicrophoneID
        }
    }
}

private final class NullLiveMixerController: LiveMixerControlling {
    var supportsSelectedAppProcessRestore: Bool {
        false
    }

    @MainActor func start(
        configuration: LiveMixerStartConfiguration,
        completion: @MainActor @escaping (LiveMixerStartResult) -> Void
    ) {
        _ = configuration
        completion(.started)
    }

    @MainActor func stop(completion: @MainActor @escaping () -> Void) {
        completion()
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        nil
    }

    @MainActor func isVirtualAudioDeviceRunning() -> Bool {
        false
    }
}

private struct EmptyMicrophoneCatalog: MicrophoneCataloging {
    func availableMicrophones() -> [MicrophoneDevice] {
        []
    }
}

private struct EmptyAppAudioSourceCatalog: AppAudioSourceCataloging {
    func availableAppAudioSources() -> [AppAudioSource] {
        []
    }
}

private final class VolatileMicrophoneSelectionStore: MicrophoneSelectionStoring {
    var selectedMicrophoneID: String?
    var preferredMicrophoneIDs: [String] = []
}

private final class VolatileAppAudioSelectionStore: AppAudioSelectionStoring {
    var captureMode: ProgramAudioCaptureMode = .globalSystemAudio
    var selectedAppBundleIDs: [String] = []
}

private final class VolatileSystemAudioAccessStore: SystemAudioAccessStoring {
    var hasVerifiedSystemAudioAccess = false
}

private final class NullLaunchAtStartupController: LaunchAtStartupControlling {
    func currentStatus() -> LaunchAtStartupStatus {
        .disabled
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtStartupSetResult {
        .success(enabled ? .enabled : .disabled)
    }
}

extension HealthSnapshot {
    static var empty: HealthSnapshot {
        HealthSnapshot(
            framesMixed: 0,
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
    }
}
