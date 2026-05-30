import Foundation

@_silgen_name("MCA_LiveMixerStart")
private func MCA_LiveMixerStart(
    _ microphoneID: UnsafePointer<CChar>?,
    _ captureMode: Int32,
    _ selectedAppBundleIDs: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("MCA_LiveMixerStop")
private func MCA_LiveMixerStop()

@_silgen_name("MCA_LiveMixerDiscardSharedMemory")
private func MCA_LiveMixerDiscardSharedMemory() -> Int32

@_silgen_name("MCA_LiveMixerSetLevels")
private func MCA_LiveMixerSetLevels(
    _ systemGain: Float,
    _ microphoneGain: Float
) -> Int32

@_silgen_name("MCA_LiveMixerSetVoiceEnhancement")
private func MCA_LiveMixerSetVoiceEnhancement(_ enabled: Int32) -> Int32

@_silgen_name("MCA_LiveMixerCopyHealthCounters")
private func MCA_LiveMixerCopyHealthCounters(
    _ outCounters: UnsafeMutablePointer<UInt64>,
    _ counterCount: UInt32
) -> Int32

@_silgen_name("MCA_LiveMixerCopyLevels")
private func MCA_LiveMixerCopyLevels(
    _ outSystemPeak: UnsafeMutablePointer<Float>,
    _ outMicPeak: UnsafeMutablePointer<Float>
) -> Int32

@_silgen_name("MCA_LiveMixerSupportsSelectedAppProcessRestore")
private func MCA_LiveMixerSupportsSelectedAppProcessRestore() -> Int32

private enum MCALiveMixerHealthCounter {
    static let framesMixed = 0
    static let systemUnderrunFrames = 1
    static let micUnderrunFrames = 2
    static let clippedSamples = 3
    static let systemQueueFrames = 4
    static let micQueueFrames = 5
    static let sourceFrameDelta = 6
    static let sourceFrameDeltaAbs = 7
    static let systemDriftDropFrames = 8
    static let micDriftDropFrames = 9
    static let callbackErrorCount = 10
    static let sharedRingFillFrames = 11
    static let sharedRingFillErrorFrames = 12
    static let sharedRingFillErrorAbsFrames = 13
    static let sharedRingOverrunFrames = 14
    static let systemQueueDroppedFrames = 15
    static let micQueueDroppedFrames = 16
    static let systemQueueOverflowFrames = 17
    static let micQueueOverflowFrames = 18
    static let count = 19

    static func healthSnapshot(from counters: [UInt64]) -> HealthSnapshot {
        precondition(counters.count >= count)
        return HealthSnapshot(
            framesMixed: counters[framesMixed],
            systemUnderrunFrames: counters[systemUnderrunFrames],
            micUnderrunFrames: counters[micUnderrunFrames],
            clippedSamples: counters[clippedSamples],
            systemQueueFrames: UInt32(clamping: counters[systemQueueFrames]),
            micQueueFrames: UInt32(clamping: counters[micQueueFrames]),
            systemQueueDroppedFrames: counters[systemQueueDroppedFrames],
            micQueueDroppedFrames: counters[micQueueDroppedFrames],
            systemQueueOverflowFrames: counters[systemQueueOverflowFrames],
            micQueueOverflowFrames: counters[micQueueOverflowFrames],
            sourceFrameDelta: Int32(clamping: Int64(bitPattern: counters[sourceFrameDelta])),
            sourceFrameDeltaAbs: UInt32(clamping: counters[sourceFrameDeltaAbs]),
            systemDriftDropFrames: counters[systemDriftDropFrames],
            micDriftDropFrames: counters[micDriftDropFrames],
            callbackErrorCount: counters[callbackErrorCount],
            sharedRingFillFrames: UInt32(clamping: counters[sharedRingFillFrames]),
            sharedRingFillErrorFrames: Int32(clamping: Int64(bitPattern: counters[sharedRingFillErrorFrames])),
            sharedRingFillErrorAbsFrames: UInt32(clamping: counters[sharedRingFillErrorAbsFrames]),
            sharedRingOverrunFrames: counters[sharedRingOverrunFrames]
        )
    }
}

private enum MCALiveMixerCaptureMode {
    // Keep these values in sync with App/Sources/Audio/LiveMixerABI.h.
    static let globalSystemAudio = Int32(0)
    static let selectedApps = Int32(1)
}

protocol AppLiveMixerNativeControlling: AnyObject, Sendable {
    func start(
        microphoneID: String?,
        captureMode: Int32,
        selectedAppBundleIDs: String
    ) -> Int32
    func stop()
    func discardSharedMemory() -> Int32
    func setAudioLevels(systemGain: Float, microphoneGain: Float) -> Int32
    func setVoiceEnhancement(enabled: Bool) -> Int32
    func copyHealthCounters(_ counters: UnsafeMutableBufferPointer<UInt64>) -> Int32
    func copyLevels(
        outSystemPeak: UnsafeMutablePointer<Float>,
        outMicPeak: UnsafeMutablePointer<Float>
    ) -> Int32
    func supportsSelectedAppProcessRestore() -> Bool
}

protocol LiveMixerActivityAsserting: AnyObject, Sendable {
    func begin()
    func end()
}

private final class AppLiveMixerNativeClient: AppLiveMixerNativeControlling {
    func start(
        microphoneID: String?,
        captureMode: Int32,
        selectedAppBundleIDs: String
    ) -> Int32 {
        let callNative: (UnsafePointer<CChar>?) -> Int32 = { microphonePointer in
            if selectedAppBundleIDs.isEmpty {
                return MCA_LiveMixerStart(microphonePointer, captureMode, nil)
            }
            return selectedAppBundleIDs.withCString { bundlePointer in
                MCA_LiveMixerStart(microphonePointer, captureMode, bundlePointer)
            }
        }

        if let microphoneID {
            return microphoneID.withCString { pointer in
                callNative(pointer)
            }
        }
        return callNative(nil)
    }

    func stop() {
        MCA_LiveMixerStop()
    }

    func discardSharedMemory() -> Int32 {
        MCA_LiveMixerDiscardSharedMemory()
    }

    func setAudioLevels(systemGain: Float, microphoneGain: Float) -> Int32 {
        MCA_LiveMixerSetLevels(systemGain, microphoneGain)
    }

    func setVoiceEnhancement(enabled: Bool) -> Int32 {
        MCA_LiveMixerSetVoiceEnhancement(enabled ? 1 : 0)
    }

    func copyHealthCounters(_ counters: UnsafeMutableBufferPointer<UInt64>) -> Int32 {
        MCA_LiveMixerCopyHealthCounters(counters.baseAddress!, UInt32(counters.count))
    }

    func copyLevels(
        outSystemPeak: UnsafeMutablePointer<Float>,
        outMicPeak: UnsafeMutablePointer<Float>
    ) -> Int32 {
        MCA_LiveMixerCopyLevels(outSystemPeak, outMicPeak)
    }

    func supportsSelectedAppProcessRestore() -> Bool {
        MCA_LiveMixerSupportsSelectedAppProcessRestore() != 0
    }
}

private final class ProcessInfoLiveMixerActivityAssertion: LiveMixerActivityAsserting, @unchecked Sendable {
    private var token: NSObjectProtocol?

    func begin() {
        guard token == nil else {
            return
        }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Mixed Capture Audio live mixing"
        )
    }

    func end() {
        guard let token else {
            return
        }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

final class AppLiveMixerController: LiveMixerControlling {
    private let controlQueue = DispatchQueue(label: "com.minamiktr.mca.live-mixer-control")
    private let mixedCaptureDeviceUID = "com.minamiktr.mca.device.MixedCaptureAudio"
    private let nativeClient: AppLiveMixerNativeControlling
    private let activityAssertion: LiveMixerActivityAsserting

    init(
        nativeClient: AppLiveMixerNativeControlling = AppLiveMixerNativeClient(),
        activityAssertion: LiveMixerActivityAsserting = ProcessInfoLiveMixerActivityAssertion()
    ) {
        self.nativeClient = nativeClient
        self.activityAssertion = activityAssertion
    }

    var supportsSelectedAppProcessRestore: Bool {
        nativeClient.supportsSelectedAppProcessRestore()
    }

    @MainActor func start(
        configuration: LiveMixerStartConfiguration,
        completion: @MainActor @escaping (LiveMixerStartResult) -> Void
    ) {
        let requestedConfiguration = configuration
        let nativeClient = nativeClient
        let activityAssertion = activityAssertion
        controlQueue.async {
            let captureMode = requestedConfiguration.captureMode == .selectedApps
                ? MCALiveMixerCaptureMode.selectedApps
                : MCALiveMixerCaptureMode.globalSystemAudio
            let selectedBundleIDs = requestedConfiguration.selectedAppBundleIDs.joined(separator: "\n")

            let status = nativeClient.start(
                microphoneID: requestedConfiguration.microphoneID,
                captureMode: captureMode,
                selectedAppBundleIDs: selectedBundleIDs
            )
            if status == 0 {
                activityAssertion.begin()
            } else {
                activityAssertion.end()
            }
            DispatchQueue.main.async {
                completion(status == 0 ? .started : .failed(statusCode: status))
            }
        }
    }

    @MainActor func stop(completion: @MainActor @escaping () -> Void) {
        let nativeClient = nativeClient
        let activityAssertion = activityAssertion
        controlQueue.async {
            nativeClient.stop()
            activityAssertion.end()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    @MainActor func stopSynchronouslyForTermination() {
        let nativeClient = nativeClient
        let activityAssertion = activityAssertion
        controlQueue.sync {
            nativeClient.stop()
            activityAssertion.end()
        }
    }

    @MainActor func discardSharedMemory() {
        let nativeClient = nativeClient
        let activityAssertion = activityAssertion
        controlQueue.sync {
            _ = nativeClient.discardSharedMemory()
            activityAssertion.end()
        }
    }

    @MainActor func setAudioLevels(_ settings: AudioLevelSettings) {
        let requestedSettings = settings
        let nativeClient = nativeClient
        controlQueue.async {
            _ = nativeClient.setAudioLevels(
                systemGain: requestedSettings.systemGain,
                microphoneGain: requestedSettings.microphoneGain
            )
            _ = nativeClient.setVoiceEnhancement(enabled: requestedSettings.enhanceVoice)
        }
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        var counters = Array(repeating: UInt64(0), count: MCALiveMixerHealthCounter.count)
        let status = counters.withUnsafeMutableBufferPointer { buffer in
            nativeClient.copyHealthCounters(buffer)
        }
        guard status == 0 else {
            return nil
        }
        return MCALiveMixerHealthCounter.healthSnapshot(from: counters)
    }

    @MainActor func currentSourceLevelSnapshot() -> SourceLevelMeterSnapshot? {
        var systemPeak: Float = 0.0
        var micPeak: Float = 0.0
        let status = nativeClient.copyLevels(outSystemPeak: &systemPeak, outMicPeak: &micPeak)
        guard status == 0 else {
            return nil
        }
        return SourceLevelMeterSnapshot(systemPeak: systemPeak, microphonePeak: micPeak)
    }

    @MainActor func isVirtualAudioDeviceRunning() -> Bool {
        CoreAudioDeviceLookup.device(uid: mixedCaptureDeviceUID)?.isRunningSomewhere == true
    }
}
