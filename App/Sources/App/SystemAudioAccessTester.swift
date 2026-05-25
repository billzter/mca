import Foundation

struct AppSystemAudioAccessTester: SystemAudioAccessTesting {
    private let testSeconds: Double

    init(testSeconds: Double = 3.0) {
        self.testSeconds = testSeconds
    }

    func runSystemAudioAccessTest() async -> SystemAudioAccessTestOutcome {
        await Task.detached(priority: .userInitiated) {
            var result = MCASystemAudioProbeResult()
            let status = MCA_RunSystemAudioAccessProbe(self.testSeconds, 0.0001, &result)
            guard status == 0 else {
                return .failed
            }
            if result.badBuffer != 0 {
                return .failed
            }
            if result.callbackCount == 0 || result.frameCount == 0 {
                return .deniedOrUnavailable
            }
            if result.nonzeroSampleCount == 0 || result.maxAbsSample <= 0.0001 {
                return .silent
            }
            return .receivingAudio
        }.value
    }
}

struct MCASystemAudioProbeResult {
    var callbackCount: UInt64 = 0
    var frameCount: UInt64 = 0
    var nonzeroSampleCount: UInt64 = 0
    var maxAbsSample: Float = 0
    var badBuffer: Int32 = 0
    var status: Int32 = 0
}

@_silgen_name("MCA_RunSystemAudioAccessProbe")
private func MCA_RunSystemAudioAccessProbe(
    _ seconds: Double,
    _ nonzeroThreshold: Float,
    _ result: UnsafeMutablePointer<MCASystemAudioProbeResult>
) -> Int32
