import AVFoundation
import Foundation

struct AppMicrophonePermissionRequester: MicrophonePermissionRequesting {
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
