import AppKit
import Foundation

struct DetachedUninstallLaunchRequest: Equatable {
    let appBundleURL: URL
    let driverURL: URL
    let status: ManualUninstallStatus
    let requiresRestart: Bool
}

protocol DetachedUninstallerLaunching: AnyObject {
    func launch(request: DetachedUninstallLaunchRequest) async -> AppUninstallOperationResult
}

final class CopiedDetachedUninstallerLauncher: DetachedUninstallerLaunching {
    typealias ApplicationRunner = (URL, [String]) async throws -> Void

    private let fileManager: FileManager
    private let embeddedHelperURL: URL
    private let copyRootURL: URL
    private let uuidProvider: () -> UUID
    private let processIdentifier: () -> Int32
    private let applicationRunner: ApplicationRunner

    init(
        fileManager: FileManager = .default,
        embeddedHelperURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("MixedCaptureAudioUninstaller.app", isDirectory: true),
        copyRootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.minamiktr.mca.uninstall", isDirectory: true),
        uuidProvider: @escaping () -> UUID = UUID.init,
        processIdentifier: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        processRunner: ApplicationRunner? = nil
    ) {
        self.fileManager = fileManager
        self.embeddedHelperURL = embeddedHelperURL
        self.copyRootURL = copyRootURL
        self.uuidProvider = uuidProvider
        self.processIdentifier = processIdentifier
        applicationRunner = processRunner ?? Self.openApplication(applicationURL:arguments:)
    }

    func launch(request: DetachedUninstallLaunchRequest) async -> AppUninstallOperationResult {
        guard fileManager.fileExists(atPath: embeddedHelperURL.path) else {
            return .failed("Uninstaller helper was not found inside the app bundle.")
        }

        let copyDirectoryURL = copyRootURL.appendingPathComponent(uuidProvider().uuidString, isDirectory: true)
        let helperCopyURL = copyDirectoryURL.appendingPathComponent(embeddedHelperURL.lastPathComponent, isDirectory: true)
        let manifestURL = copyDirectoryURL.appendingPathComponent(DetachedUninstallRequest.manifestFileName)
        let executableURL = helperCopyURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("MixedCaptureAudioUninstaller")

        do {
            try fileManager.createDirectory(
                at: copyDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: embeddedHelperURL, to: helperCopyURL)
            let manifest = DetachedUninstallRequest(
                appPath: request.appBundleURL.path,
                driverPath: request.driverURL.path,
                requiresRestart: request.requiresRestart,
                parentProcessIdentifier: processIdentifier()
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
            guard fileManager.isExecutableFile(atPath: executableURL.path) else {
                return .failed("Uninstaller helper executable was not found inside the helper app.")
            }
            try await applicationRunner(helperCopyURL, DetachedUninstallRequest.commandLineArguments(manifestURL: manifestURL))
        } catch {
            return .failed("Could not launch uninstaller helper: \(error.localizedDescription)")
        }

        return .success
    }

    private static func openApplication(applicationURL: URL, arguments: [String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true

        let completion = LaunchCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.setContinuation(continuation)
                NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                    if let error {
                        completion.resume(throwing: error)
                    } else {
                        completion.resume()
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    completion.resume(
                        throwing: CocoaError(
                            .fileReadUnknown,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out launching uninstaller helper."]
                        )
                    )
                }
            }
        } onCancel: {
            completion.resume(throwing: CancellationError())
        }
    }
}

private final class LaunchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var didResume = false

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !didResume else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func resume() {
        resume(returning: ())
    }

    func resume(returning value: Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
