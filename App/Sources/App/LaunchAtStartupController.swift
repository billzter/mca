import Foundation
import ServiceManagement

final class AppLaunchAtStartupController: LaunchAtStartupControlling {
    func currentStatus() -> LaunchAtStartupStatus {
        guard #available(macOS 13.0, *) else {
            return .failed
        }
        return Self.map(status: SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtStartupSetResult {
        guard #available(macOS 13.0, *) else {
            return .failed("Launch at startup requires macOS 13 or later.")
        }

        do {
            if enabled {
                let currentStatus = SMAppService.mainApp.status
                if currentStatus != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                let currentStatus = SMAppService.mainApp.status
                if currentStatus != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            return .success(Self.map(status: SMAppService.mainApp.status))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @available(macOS 13.0, *)
    private static func map(status: SMAppService.Status) -> LaunchAtStartupStatus {
        switch status {
        case .enabled:
            .enabled
        case .notRegistered:
            .disabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .failed
        @unknown default:
            .failed
        }
    }
}
