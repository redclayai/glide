import XCTest
@testable import Proofreading

final class RewriteSentenceBoundaryTests: XCTestCase {
    func testWaitsForLookAhead() {
        XCTAssertNil(RewriteSentenceBoundary.finishedPrefix(in: "It costs 3.", matching: "It cost 3.14 dollars"))
        XCTAssertNil(RewriteSentenceBoundary.finishedPrefix(in: "It costs 3.14 dollars.", matching: "It cost 3.14 dollars"))
        XCTAssertEqual(RewriteSentenceBoundary.finishedPrefix(in: "It costs 3.14 dollars. More", matching: "It cost 3.14 dollars"), "It costs 3.14 dollars.")
    }

    func testAbbreviationIsNotASentence() {
        XCTAssertNil(RewriteSentenceBoundary.finishedPrefix(in: "Dr.", matching: "Doctor Smith are here."))
        XCTAssertNil(RewriteSentenceBoundary.finishedPrefix(in: "Dr. Smith is here.", matching: "Dr. Smith are here."))
        XCTAssertEqual(RewriteSentenceBoundary.finishedPrefix(in: "Dr. Smith is here. Extra", matching: "Dr. Smith are here."), "Dr. Smith is here.")
    }

    func testIncludesUnterminatedOriginalTail() {
        XCTAssertNil(RewriteSentenceBoundary.finishedPrefix(in: "She left. He stayed.", matching: "She left. He stay"))
        XCTAssertEqual(RewriteSentenceBoundary.finishedPrefix(in: "She left. He stayed. Extra", matching: "She left. He stay"), "She left. He stayed.")
    }

    func testKeepsClosingQuotationAndPunctuationRuns() {
        XCTAssertEqual(RewriteSentenceBoundary.finishedPrefix(in: "She said, “Go!” Then", matching: "She say, “Go!”"), "She said, “Go!”")
        XCTAssertEqual(RewriteSentenceBoundary.finishedPrefix(in: "Really?! Extra", matching: "Really?!"), "Really?!")
    }
}
