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
