import Foundation

@_silgen_name("MCA_LiveMixerStart")
private func MCA_LiveMixerStart(
    _ microphoneID: UnsafePointer<CChar>?,
    _ captureMode: Int32,
    _ selectedAppBundleIDs: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("MCA_LiveMixerStop")
private func MCA_LiveMixerStop()

@_silgen_name("MCA_LiveMixerCopyHealthCounters")
private func MCA_LiveMixerCopyHealthCounters(
    _ outCounters: UnsafeMutablePointer<UInt64>,
    _ counterCount: UInt32
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
    static let count = 11

    static func healthSnapshot(from counters: [UInt64]) -> HealthSnapshot {
        precondition(counters.count >= count)
        return HealthSnapshot(
            framesMixed: counters[framesMixed],
            systemUnderrunFrames: counters[systemUnderrunFrames],
            micUnderrunFrames: counters[micUnderrunFrames],
            clippedSamples: counters[clippedSamples],
            systemQueueFrames: UInt32(clamping: counters[systemQueueFrames]),
            micQueueFrames: UInt32(clamping: counters[micQueueFrames]),
            sourceFrameDelta: Int32(clamping: Int64(bitPattern: counters[sourceFrameDelta])),
            sourceFrameDeltaAbs: UInt32(clamping: counters[sourceFrameDeltaAbs]),
            systemDriftDropFrames: counters[systemDriftDropFrames],
            micDriftDropFrames: counters[micDriftDropFrames],
            callbackErrorCount: counters[callbackErrorCount]
        )
    }
}

final class AppLiveMixerController: LiveMixerControlling {
    private let controlQueue = DispatchQueue(label: "com.minamiktr.mca.live-mixer-control")

    var supportsSelectedAppProcessRestore: Bool {
        MCA_LiveMixerSupportsSelectedAppProcessRestore() != 0
    }

    @MainActor func start(
        configuration: LiveMixerStartConfiguration,
        completion: @MainActor @escaping (LiveMixerStartResult) -> Void
    ) {
        let requestedConfiguration = configuration
        controlQueue.async {
            let captureMode = requestedConfiguration.captureMode == .selectedApps ? Int32(1) : Int32(0)
            let selectedBundleIDs = requestedConfiguration.selectedAppBundleIDs.joined(separator: "\n")

            let callNative: (UnsafePointer<CChar>?) -> Int32 = { microphonePointer in
                if selectedBundleIDs.isEmpty {
                    return MCA_LiveMixerStart(microphonePointer, captureMode, nil)
                }
                return selectedBundleIDs.withCString { bundlePointer in
                    MCA_LiveMixerStart(microphonePointer, captureMode, bundlePointer)
                }
            }

            let status: Int32
            if let requestedMicrophoneID = requestedConfiguration.microphoneID {
                status = requestedMicrophoneID.withCString { pointer in
                    callNative(pointer)
                }
            } else {
                status = callNative(nil)
            }
            DispatchQueue.main.async {
                completion(status == 0 ? .started : .failed)
            }
        }
    }

    @MainActor func stop(completion: @MainActor @escaping () -> Void) {
        controlQueue.async {
            MCA_LiveMixerStop()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    @MainActor func currentHealthSnapshot() -> HealthSnapshot? {
        var counters = Array(repeating: UInt64(0), count: MCALiveMixerHealthCounter.count)
        let status = counters.withUnsafeMutableBufferPointer { buffer in
            MCA_LiveMixerCopyHealthCounters(
                buffer.baseAddress!,
                UInt32(MCALiveMixerHealthCounter.count)
            )
        }
        guard status == 0 else {
            return nil
        }
        return MCALiveMixerHealthCounter.healthSnapshot(from: counters)
    }
}
