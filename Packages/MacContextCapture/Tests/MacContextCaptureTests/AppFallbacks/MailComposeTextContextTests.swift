import CoreGraphics
import XCTest
@testable import MacContextCapture

final class MailComposeTextContextTests: XCTestCase {
    @MainActor
    func testEstimatedCursorRectTracksCurrentLine() {
        let field = CGRect(x: 100, y: 200, width: 500, height: 300)

        let firstLine = MailComposeTextContext.estimatedCursorRect(beforeCursor: "Hello", in: field)
        let secondLine = MailComposeTextContext.estimatedCursorRect(beforeCursor: "Hello\nagain", in: field)

        XCTAssertGreaterThan(firstLine.minX, field.minX)
        XCTAssertLessThan(firstLine.maxX, field.maxX)
        XCTAssertLessThan(secondLine.minY, firstLine.minY)
    }
}
