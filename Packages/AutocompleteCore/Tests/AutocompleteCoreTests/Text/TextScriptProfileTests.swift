import AutocompleteCore
import XCTest

final class TextScriptProfileTests: XCTestCase {
    func testDetectsCJKAtTheCaret() {
        XCTAssertEqual(TextScriptProfile.lastSubstantiveScript(in: "为什么"), .cjk)
        XCTAssertEqual(TextScriptProfile.firstSubstantiveScript(in: "，为什么"), .cjk)
    }

    func testDetectsLatinAfterPunctuationAndWhitespace() {
        XCTAssertEqual(TextScriptProfile.firstSubstantiveScript(in: ", weishenme"), .latin)
        XCTAssertEqual(TextScriptProfile.lastSubstantiveScript(in: "hello "), .latin)
    }

    func testMajorScriptChangeBetweenAnchorAndLiveContext() {
        let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        let anchor = TextFieldContext(beforeCursor: "我", target: target)
        let live = TextFieldContext(beforeCursor: "我z", target: target)

        XCTAssertTrue(TextScriptProfile.hasMajorScriptChange(anchor: anchor, live: live))
    }
}
