import AutocompleteCore
import XCTest
@testable import Proofreading

final class TrailingSentenceScannerTests: XCTestCase {
    // MARK: - Eligibility

    func testScansSentenceAfterCommittedTerminator() {
        let trailing = TrailingSentenceScanner.scan(beforeCursor: "i has went to the store. ")
        XCTAssertEqual(trailing?.sentence, "i has went to the store.")
        XCTAssertEqual(trailing?.boundary, " ")
    }

    func testAcceptsTerminatorWithNoTrailingSpace() {
        let trailing = TrailingSentenceScanner.scan(beforeCursor: "i has went to the store.")
        XCTAssertEqual(trailing?.sentence, "i has went to the store.")
        XCTAssertEqual(trailing?.boundary, "")
    }

    func testSpanEndsAtCaret() {
        let before = "Hi there. i has went to the store. "
        let span = TrailingSentenceScanner.scan(beforeCursor: before)?.span
        XCTAssertEqual(span?.original, "i has went to the store. ")
        XCTAssertTrue(before.hasSuffix(span?.original ?? "!"), "span must be a suffix of the text before the caret")
    }

    /// Mid-sentence the user is still writing the clause; a correction there argues with them.
    func testIgnoresUnterminatedText() {
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "i has went to the store"))
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "i has went to the store "))
    }

    func testStopsAtPreviousSentence() {
        let trailing = TrailingSentenceScanner.scan(beforeCursor: "That was fine. But he don't agree with it. ")
        XCTAssertEqual(trailing?.sentence, "But he don't agree with it.")
    }

    /// "e.g." and "Dr." must not truncate the sentence they sit inside.
    func testAbbreviationsDoNotTruncateTheSentence() {
        let trailing = TrailingSentenceScanner.scan(beforeCursor: "We should ask Dr. Ramirez about it. ")
        XCTAssertEqual(trailing?.sentence, "We should ask Dr. Ramirez about it.")
    }

    func testRefusesAcrossNewline() {
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "All done.\n"))
    }

    // MARK: - Size and content gates

    func testRefusesFragments() {
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "Yes. "))
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "Sounds good. "))
    }

    func testRefusesSentencesTooLongToApply() {
        let long = String(repeating: "word ", count: 60) + "end. "
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: long))
    }

    /// The scanner's cap has to stay under the replacement keystroke bound, or it could propose a
    /// fix that the keystroke fallback is unable to apply.
    func testMaximumStaysWithinTheReplacementBound() {
        XCTAssertLessThan(TrailingSentenceScanner.maximumCharacters, maximumReplacementKeystrokes)
    }

    func testRefusesCodeAndAddresses() {
        XCTAssertFalse(TrailingSentenceScanner.isProse("call foo() with {x: 1}."))
        XCTAssertFalse(TrailingSentenceScanner.isProse("read https://example.org/docs now."))
        XCTAssertFalse(TrailingSentenceScanner.isProse("mail danny@example.com today."))
        XCTAssertTrue(TrailingSentenceScanner.isProse("i has went to the store."))
    }
}
