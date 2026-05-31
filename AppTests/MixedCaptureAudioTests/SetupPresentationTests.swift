import Foundation
@testable import MixedCaptureAudio
import XCTest

final class SetupPresentationTests: XCTestCase {

    func testSuccessfulStatusesAreComplete() {
        let completeStatuses = [
            AudioDeviceStatus.installed.rawValue,
            PermissionStatus.granted.rawValue,
            SystemAudioAccessStatus.receivingAudio.rawValue,
            SelectedDeviceStatus.available.rawValue,
            QuickTimeDeviceStatus.visible.rawValue,
        ]

        for status in completeStatuses {
            assertTrue(SetupStepPresentation(status: status).isComplete)
        }
    }

    func testIncompleteStatusesRemainIncomplete() {
        let incompleteStatuses = [
            AudioDeviceStatus.installedButNeedsReload.rawValue,
            PermissionStatus.denied.rawValue,
            SystemAudioAccessStatus.silent.rawValue,
            SelectedDeviceStatus.missing.rawValue,
            QuickTimeDeviceStatus.notVisible.rawValue,
        ]

        for status in incompleteStatuses {
            assertFalse(SetupStepPresentation(status: status).isComplete)
        }
    }

    func testUserFacingStatusLabelsAreFriendly() {
        let cases = [
            (SystemAudioAccessStatus.receivingAudio.rawValue, "Receiving audio"),
            (SystemAudioAccessStatus.notTested.rawValue, "Not checked"),
            (SystemAudioAccessStatus.deniedOrUnavailable.rawValue, "Needs permission"),
            (AudioDeviceStatus.installedButNeedsReload.rawValue, "Restart required"),
            (AudioDeviceStatus.incompatible.rawValue, "Needs update"),
            (PermissionStatus.notDetermined.rawValue, "Needs approval"),
            (QuickTimeDeviceStatus.notVisible.rawValue, "Not visible"),
        ]

        for (status, expected) in cases {
            assertEqual(SetupStepPresentation(status: status).displayStatus, expected)
        }
    }

    func testChecklistPresentationShowsAllRowsWhenNoneComplete() {
        let presentation = SetupChecklistPresentation(rows: [
            checklistRow(id: .virtualAudioDevice, status: AudioDeviceStatus.missing.rawValue),
            checklistRow(id: .microphone, status: PermissionStatus.denied.rawValue),
            checklistRow(id: .systemAudio, status: SystemAudioAccessStatus.notTested.rawValue),
            checklistRow(id: .quickTimeInput, status: QuickTimeDeviceStatus.notVisible.rawValue),
        ])

        assertEqual(presentation.completeCount, 0)
        assertEqual(presentation.defaultVisibleRows.map(\.id), [
            .virtualAudioDevice,
            .microphone,
            .systemAudio,
            .quickTimeInput,
        ])
        assertEqual(presentation.completedRows, [])
    }

    func testChecklistPresentationHidesCompletedRowsByDefault() {
        let presentation = SetupChecklistPresentation(rows: [
            checklistRow(id: .virtualAudioDevice, status: AudioDeviceStatus.installed.rawValue),
            checklistRow(id: .microphone, status: PermissionStatus.granted.rawValue),
            checklistRow(id: .systemAudio, status: SystemAudioAccessStatus.notTested.rawValue),
            checklistRow(id: .quickTimeInput, status: QuickTimeDeviceStatus.visible.rawValue),
        ])

        assertEqual(presentation.completeCount, 3)
        assertEqual(presentation.defaultVisibleRows.map(\.id), [.systemAudio])
        assertEqual(presentation.completedRows.map(\.id), [
            .virtualAudioDevice,
            .microphone,
            .quickTimeInput,
        ])
    }

    func testChecklistPresentationCollapsesAllRowsWhenComplete() {
        let presentation = SetupChecklistPresentation(rows: [
            checklistRow(id: .virtualAudioDevice, status: AudioDeviceStatus.installed.rawValue),
            checklistRow(id: .microphone, status: PermissionStatus.granted.rawValue),
            checklistRow(id: .systemAudio, status: SystemAudioAccessStatus.receivingAudio.rawValue),
            checklistRow(id: .quickTimeInput, status: QuickTimeDeviceStatus.visible.rawValue),
        ])

        assertEqual(presentation.completeCount, 4)
        assertEqual(presentation.defaultVisibleRows, [])
        assertEqual(presentation.isComplete, true)
    }

    func testChecklistPresentationShowsCompleteHeaderStatusWhenComplete() {
        let presentation = SetupChecklistPresentation(rows: [
            checklistRow(id: .virtualAudioDevice, status: AudioDeviceStatus.installed.rawValue),
            checklistRow(id: .microphone, status: PermissionStatus.granted.rawValue),
            checklistRow(id: .systemAudio, status: SystemAudioAccessStatus.receivingAudio.rawValue),
            checklistRow(id: .quickTimeInput, status: QuickTimeDeviceStatus.visible.rawValue),
        ])

        assertEqual(presentation.headerStatus, "Complete")
    }

    func testChecklistPresentationTreatsProceedUnverifiedAsComplete() {
        let presentation = SetupChecklistPresentation(rows: [
            checklistRow(id: .systemAudio, status: SystemAudioAccessStatus.proceedUnverified.rawValue),
        ])

        assertEqual(presentation.completeCount, 1)
        assertEqual(presentation.defaultVisibleRows, [])
    }

    func testSystemAudioPanelIsPrioritizedUntilVerified() {
        assertTrue(SetupActionPanelPlacement.prioritizesSystemAudio(.notTested))
        assertTrue(SetupActionPanelPlacement.prioritizesSystemAudio(.silent))
        assertTrue(SetupActionPanelPlacement.prioritizesSystemAudio(.deniedOrUnavailable))
        assertFalse(SetupActionPanelPlacement.prioritizesSystemAudio(.receivingAudio))
        assertFalse(SetupActionPanelPlacement.prioritizesSystemAudio(.proceedUnverified))
    }

    func testReopenAfterSetupPresentationSuppressesDefaultWindow() {
        assertFalse(SetupWindowReopenPolicy.shouldAllowSystemDefaultWindowCreation)
    }

    func testAppLifecycleDoesNotExposeSystemSettingsScene() {
        assertFalse(AppLifecyclePresentation.exposesSystemSettingsScene)
    }

    func testAppLifecycleUsesExplicitAppKitDelegateMain() {
        assertTrue(AppLifecyclePresentation.usesExplicitAppKitDelegateMain)
    }

    func testAppTerminationDoesNotFinalDiscardSharedMemory() {
        assertFalse(AppTerminationSharedMemoryPolicy.shouldDiscardSharedMemory())
    }

    func testAdvancedUninstallPresentationExplainsScopeAndRestart() {
        let presentation = SetupAdvancedUninstallPresentation.default

        XCTAssertEqual(presentation.title, "Advanced")
        XCTAssertEqual(presentation.actionTitle, "Uninstall MixedCaptureAudio...")
        XCTAssertTrue(presentation.isDestructive)
        XCTAssertTrue(presentation.confirmationRemovedItems.contains("App settings and support files"))
        XCTAssertTrue(presentation.confirmationManualItems.contains("MixedCaptureAudio app"))
        XCTAssertTrue(presentation.confirmationManualItems.contains("MixedCaptureAudio audio driver"))
        XCTAssertTrue(presentation.confirmationKeptItems.contains("Microphone and system-audio privacy choices"))
        XCTAssertTrue(presentation.confirmationMessage.contains("Finish Uninstalling"))
        XCTAssertTrue(presentation.confirmationMessage.contains("Finder may ask for administrator approval"))
        XCTAssertTrue(presentation.confirmationMessage.contains("Restart your Mac"))
        XCTAssertTrue(presentation.confirmationMessage.contains("\n- Open a Finish Uninstalling window"))
        XCTAssertTrue(presentation.confirmationMessage.contains("\n- Microphone and system-audio privacy choices"))
        XCTAssertFalse(presentation.confirmationMessage.contains("Removes:"))
        XCTAssertFalse(presentation.confirmationMessage.contains("Keeps:"))
        XCTAssertFalse(presentation.completionMessage(requiresRestart: true).contains("- "))
        XCTAssertTrue(presentation.completionMessage(requiresRestart: true).contains("Restart your Mac"))
        XCTAssertFalse(presentation.completionMessage(requiresRestart: false).contains("Restart your Mac"))
    }

    func testManualUninstallPresentationShowsFinderDrivenChecklist() {
        let presentation = ManualUninstallPresentation.default

        XCTAssertEqual(presentation.title, "Finish Uninstalling")
        XCTAssertTrue(presentation.message.contains("Drag each remaining item"))
        XCTAssertTrue(presentation.message.contains("Finder may ask for an administrator password"))
        XCTAssertEqual(presentation.orderedItems.map(\.title), [
            "MixedCaptureAudio.driver",
            "MixedCaptureAudio.app",
        ])
        XCTAssertEqual(presentation.appItem.title, "MixedCaptureAudio.app")
        XCTAssertEqual(presentation.driverItem.title, "MixedCaptureAudio.driver")
        XCTAssertEqual(presentation.revealButtonTitle, "Show in Finder")
        XCTAssertEqual(presentation.checkAgainButtonTitle, "Check Again")
    }

    func testDetachedUninstallerRequestUsesManifestArgumentAndHALFirstPresentation() throws {
        let request = DetachedUninstallRequest(
            appPath: "/Applications/MixedCaptureAudio.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver",
            requiresRestart: true,
            parentProcessIdentifier: 1234
        )
        let manifestURL = URL(fileURLWithPath: "/tmp/mca-uninstall/request.json")

        XCTAssertEqual(
            DetachedUninstallRequest.commandLineArguments(manifestURL: manifestURL),
            ["--request", "/tmp/mca-uninstall/request.json"]
        )
        XCTAssertEqual(DetachedUninstallRequest.requestManifestURL(from: ["helper", "--request", manifestURL.path]), manifestURL)

        let presentation = DetachedUninstallerPresentation(request: request)
        XCTAssertEqual(presentation.items.map(\.title), [
            "MixedCaptureAudio.driver",
            "MixedCaptureAudio.app",
        ])
        XCTAssertEqual(presentation.items.map(\.path), [request.driverPath, request.appPath])
        XCTAssertEqual(presentation.completionItems, [
            "MixedCaptureAudio app and audio driver are no longer installed.",
            "Restart your Mac to finish unloading the audio driver.",
        ])
        XCTAssertTrue(presentation.completionMessage.contains("Restart your Mac"))
    }

    func testDetachedUninstallerPresentationShowsNextStepsBeforeCompletion() {
        let request = DetachedUninstallRequest(
            appPath: "/Applications/MixedCaptureAudio.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver",
            requiresRestart: true,
            parentProcessIdentifier: 1234
        )
        let presentation = DetachedUninstallerPresentation(request: request)

        XCTAssertEqual(presentation.inProgressTitle, "Next steps")
        XCTAssertEqual(presentation.inProgressItems, [
            "Move each listed item to Trash in Finder.",
            "Click Check Again after Trash accepts the items.",
            "Restart your Mac after uninstall if the audio driver was installed.",
        ])
    }

    func testDetachedUninstallerLifecycleUsesDockRecoverableAppPresentation() throws {
        XCTAssertTrue(DetachedUninstallerLifecyclePresentation.usesRegularAppActivationPolicy)

        let plist = try builtDetachedUninstallerInfoPlist()

        XCTAssertNil(plist["LSUIElement"])
    }

    func testDetachedUninstallerRegularAppMenuPresentationProvidesQuitAndWindowMenu() {
        let presentation = DetachedUninstallerCommandMenuPresentation.default

        XCTAssertEqual(presentation.applicationMenuTitle, "Finish Uninstalling MCA")
        XCTAssertEqual(presentation.quitTitle, "Quit Finish Uninstalling MCA")
        XCTAssertEqual(presentation.quitKeyEquivalent, "q")
        XCTAssertEqual(presentation.windowMenuTitle, "Window")
        XCTAssertEqual(presentation.minimizeTitle, "Minimize")
        XCTAssertEqual(presentation.minimizeKeyEquivalent, "m")
        XCTAssertEqual(presentation.zoomTitle, "Zoom")
        XCTAssertEqual(presentation.bringAllToFrontTitle, "Bring All to Front")
    }

    func testDetachedUninstallerWindowLifecycleKeepsIncompleteWindowRecoverable() {
        let quitConfirmation = DetachedUninstallerQuitConfirmationPresentation.default

        XCTAssertEqual(quitConfirmation.messageText, "Quit before uninstall finishes?")
        XCTAssertEqual(quitConfirmation.informativeText, "MixedCaptureAudio may still be installed. Continue uninstalling, or quit the helper now and finish later.")
        XCTAssertEqual(quitConfirmation.continueButtonTitle, "Continue Uninstalling")
        XCTAssertEqual(quitConfirmation.quitButtonTitle, "Quit Anyway")
        XCTAssertEqual(
            DetachedUninstallerWindowLifecyclePresentation.terminationDecision(isComplete: false),
            .confirmBeforeTerminating(quitConfirmation)
        )
        XCTAssertFalse(DetachedUninstallerWindowLifecyclePresentation.shouldCloseWindow(isComplete: false))
        XCTAssertFalse(DetachedUninstallerWindowLifecyclePresentation.shouldTerminateAfterLastWindowClosed(isComplete: false))
        XCTAssertEqual(DetachedUninstallerWindowLifecyclePresentation.terminationDecision(isComplete: true), .allow)
        XCTAssertTrue(DetachedUninstallerWindowLifecyclePresentation.shouldCloseWindow(isComplete: true))
        XCTAssertTrue(DetachedUninstallerWindowLifecyclePresentation.shouldTerminateAfterLastWindowClosed(isComplete: true))
    }

    func testDetachedUninstallerUsesFreshDockBundleIdentity() throws {
        let plist = try builtDetachedUninstallerInfoPlist()

        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.minamiktr.mca.uninstall")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "Finish Uninstalling MCA")
    }

    func testDetachedUninstallerPresentationKeepsAppRowUnavailableWhileParentRuns() {
        let request = DetachedUninstallRequest(
            appPath: "/Applications/MixedCaptureAudio.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver",
            requiresRestart: true,
            parentProcessIdentifier: 1234
        )
        let presentation = DetachedUninstallerPresentation(request: request)

        let rows = presentation.itemRows(
            installedPaths: [request.driverPath, request.appPath],
            parentProcessIsRunning: true
        )

        XCTAssertEqual(rows.map(\.item.kind), [.driver, .app])
        XCTAssertTrue(rows[0].isRemovalAvailable)
        XCTAssertEqual(rows[0].detail, request.driverPath)
        XCTAssertFalse(rows[0].allowsMultilineDetail)
        XCTAssertFalse(rows[1].isRemovalAvailable)
        XCTAssertEqual(rows[1].detail, "Waiting for MixedCaptureAudio to quit...")
        XCTAssertTrue(rows[1].allowsMultilineDetail)
    }

    func testDetachedUninstallerPresentationShowsManualQuitBackstopWhenParentWaitTimesOut() {
        let request = DetachedUninstallRequest(
            appPath: "/Applications/MixedCaptureAudio.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver",
            requiresRestart: true,
            parentProcessIdentifier: 1234
        )
        let presentation = DetachedUninstallerPresentation(request: request)

        let rows = presentation.itemRows(
            installedPaths: [request.driverPath, request.appPath],
            parentProcessIsRunning: true,
            parentProcessWaitTimedOut: true
        )

        XCTAssertTrue(rows[0].isRemovalAvailable)
        XCTAssertFalse(rows[1].isRemovalAvailable)
        XCTAssertEqual(
            rows[1].detail,
            "MixedCaptureAudio is still running. Quit it manually, then click Check Again."
        )
        XCTAssertTrue(rows[1].allowsMultilineDetail)
    }

    func testDetachedUninstallerPresentationEnablesAppRowAfterParentExits() {
        let request = DetachedUninstallRequest(
            appPath: "/Applications/MixedCaptureAudio.app",
            driverPath: "/Library/Audio/Plug-Ins/HAL/MixedCaptureAudio.driver",
            requiresRestart: true,
            parentProcessIdentifier: 1234
        )
        let presentation = DetachedUninstallerPresentation(request: request)

        let rows = presentation.itemRows(
            installedPaths: [request.driverPath, request.appPath],
            parentProcessIsRunning: false
        )

        XCTAssertTrue(rows[1].isRemovalAvailable)
        XCTAssertEqual(rows[1].detail, request.appPath)
        XCTAssertFalse(rows[1].allowsMultilineDetail)
    }
}

private func checklistRow(id: SetupChecklistRowPresentation.ID, status: String) -> SetupChecklistRowPresentation {
    SetupChecklistRowPresentation(
        id: id,
        title: "\(id)",
        primary: "Primary",
        status: status
    )
}

private func assertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(condition, file: file, line: line)
}

private func assertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    XCTAssertFalse(condition, file: file, line: line)
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual)", file: file, line: line)
    }
}

private func builtDetachedUninstallerInfoPlist() throws -> [String: Any] {
    let plistURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/MixedCaptureAudioUninstaller.app/Contents/Info.plist")
    let data = try Data(contentsOf: plistURL)
    return try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    )
}
