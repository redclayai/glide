import CoreGraphics
import AutocompleteCore
import XCTest
@testable import MacContextCapture

final class WeChatFallbackTextContextTests: XCTestCase {
    func testKeystrokeBufferAppendsBackspacesAndTrims() {
        var buffer = KeystrokeFallbackTextBuffer(maxCharacters: 5)

        buffer.append("hello")
        buffer.append("!")
        buffer.deleteBackward()

        XCTAssertEqual(buffer.beforeCursor, "ello")
        XCTAssertFalse(buffer.isEmpty)

        buffer.reset()
        XCTAssertTrue(buffer.isEmpty)
    }

    func testWeChatFallbackSnapshotBuildsEstimatedComposerContext() {
        let target = AppTarget(bundleIdentifier: WeChatFallbackTextContext.bundleIdentifier, appName: "WeChat")
        let window = CGRect(x: 100, y: 80, width: 1_000, height: 700)

        let snapshot = WeChatFallbackTextContext.snapshot(
            beforeCursor: "sounds good",
            target: target,
            windowFrame: window
        )

        XCTAssertEqual(snapshot?.context.beforeCursor, "sounds good")
        XCTAssertEqual(snapshot?.context.target, target)
        XCTAssertEqual(snapshot?.context.typingContext, "WeChat message composer (keystroke fallback)")
        XCTAssertEqual(snapshot?.context.geometry.cursorRectQuality, .estimated)
        XCTAssertNotNil(snapshot?.context.geometry.cursorRect)
        XCTAssertNotNil(snapshot?.context.geometry.fieldRect)
        XCTAssertEqual(snapshot?.caretSource, "wechatKeystrokeFallback")
    }

    func testWeChatFallbackSnapshotSuppressesEmptyPrefix() {
        let target = AppTarget(bundleIdentifier: WeChatFallbackTextContext.bundleIdentifier, appName: "WeChat")

        XCTAssertNil(WeChatFallbackTextContext.snapshot(
            beforeCursor: "   ",
            target: target,
            windowFrame: nil
        ))
    }

    func testWeChatFallbackSnapshotStillPlacesWithoutWindowFrame() {
        let target = AppTarget(bundleIdentifier: WeChatFallbackTextContext.bundleIdentifier, appName: "WeChat")

        let snapshot = WeChatFallbackTextContext.snapshot(
            beforeCursor: "hello",
            target: target,
            windowFrame: nil
        )

        XCTAssertNotNil(snapshot?.caretRect)
    }
}
