import AppKit
@testable import MixedCaptureAudio
import XCTest

final class AppCommandMenuXCTests: XCTestCase {
    func testStandardEditMenuContainsTextEditingShortcuts() throws {
        let menu = AppCommandMenu.standardMainMenu()
        let editMenu = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)

        assertMenuItem(
            in: editMenu,
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        assertMenuItem(
            in: editMenu,
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        assertMenuItem(
            in: editMenu,
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        assertMenuItem(
            in: editMenu,
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
    }

    private func assertMenuItem(
        in menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let item = menu.item(withTitle: title) else {
            XCTFail("Expected \(title) menu item", file: file, line: line)
            return
        }

        XCTAssertEqual(item.action, action, file: file, line: line)
        XCTAssertEqual(item.keyEquivalent, keyEquivalent, file: file, line: line)
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command], file: file, line: line)
    }
}
