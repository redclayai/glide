import AutocompleteCore
import XCTest

final class ReservedSystemShortcutTests: XCTestCase {
    func testScreenCaptureShortcutsMatchMacOSDefaults() {
        XCTAssertTrue(screenCapture(keyCode: 20, shift: true, command: true))
        XCTAssertTrue(screenCapture(keyCode: 21, shift: true, command: true))
        XCTAssertTrue(screenCapture(keyCode: 23, shift: true, command: true))
    }

    func testScreenCaptureClipboardVariantsAllowControl() {
        XCTAssertTrue(screenCapture(keyCode: 20, shift: true, control: true, command: true))
        XCTAssertTrue(screenCapture(keyCode: 21, shift: true, control: true, command: true))
        XCTAssertTrue(screenCapture(keyCode: 23, shift: true, control: true, command: true))
    }

    func testScreenCaptureRequiresShiftAndCommand() {
        XCTAssertFalse(screenCapture(keyCode: 21, shift: false, command: true))
        XCTAssertFalse(screenCapture(keyCode: 21, shift: true, command: false))
    }

    func testScreenCaptureRejectsOptionAndOtherNumberKeys() {
        XCTAssertFalse(screenCapture(keyCode: 21, shift: true, option: true, command: true))
        XCTAssertFalse(screenCapture(keyCode: 19, shift: true, command: true))
    }

    private func screenCapture(
        keyCode: Int64,
        shift: Bool = false,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false
    ) -> Bool {
        ReservedSystemShortcut.isScreenCapture(
            keyCode: keyCode,
            shift: shift,
            control: control,
            option: option,
            command: command
        )
    }
}
