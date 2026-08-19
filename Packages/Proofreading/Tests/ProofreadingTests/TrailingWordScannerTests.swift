import AutocompleteCore
import XCTest
@testable import Proofreading

final class TrailingWordScannerTests: XCTestCase {
    // MARK: - Eligibility

    func testScansWordAfterCommittedSpace() {
        let trailing = TrailingWordScanner.scan(beforeCursor: "i beleive ")
        XCTAssertEqual(trailing?.word, "beleive")
        XCTAssertEqual(trailing?.boundary, " ")
    }

    func testSpanEndsAtCaretByIncludingBoundary() {
        let trailing = TrailingWordScanner.scan(beforeCursor: "that seperate, ")
        XCTAssertEqual(trailing?.word, "seperate")
        XCTAssertEqual(trailing?.boundary, ", ")
        XCTAssertEqual(trailing?.span.original, "seperate, ")
    }

    /// While the caret is inside a word the completion path owns it.
    func testIgnoresWordStillBeingTyped() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "i belei"))
    }

    func testIgnoresEmptyInput() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: ""))
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "   "))
    }

    /// Replacement across a line break is unreliable, so the scanner refuses.
    func testRefusesAcrossNewline() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "done\n"))
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "done\n  "))
    }

    func testRefusesLongBoundaryRun() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "spaced     "))
    }

    // MARK: - Prose gating

    func testRejectsTooShortOrTooLongWords() {
        XCTAssertFalse(TrailingWordScanner.isProse("a"))
        XCTAssertFalse(TrailingWordScanner.isProse("to"))
        XCTAssertFalse(TrailingWordScanner.isProse(""))
        XCTAssertFalse(TrailingWordScanner.isProse(String(repeating: "a", count: 40)))
    }

    func testAcceptsOrdinaryWords() {
        XCTAssertTrue(TrailingWordScanner.isProse("beleive"))
        XCTAssertTrue(TrailingWordScanner.isProse("Danny"))
        XCTAssertTrue(TrailingWordScanner.isProse("don't"))
    }

    /// Apostrophes are word-internal: treating them as boundaries would reduce "don't" to "t".
    func testContractionsStayWhole() {
        XCTAssertEqual(TrailingWordScanner.scan(beforeCursor: "i don't ")?.word, "don't")
        XCTAssertEqual(TrailingWordScanner.scan(beforeCursor: "the team\u{2019}s ")?.word, "team\u{2019}s")
    }

    /// The separators inside emails and paths are boundaries too, so the scanner only ever sees the
    /// trailing fragment. What precedes the word is what identifies it as machine-readable.
    func testRejectsFragmentsOfMachineReadableTokens() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "email me at danny@example.com "))
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "open src/main.swift "))
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "call some_helper "))
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "see https://example.org "))
    }

    /// A sentence-ending period is not glue — the next sentence's words are still prose.
    func testOrdinaryPunctuationIsNotGlue() {
        XCTAssertEqual(TrailingWordScanner.scan(beforeCursor: "Done. Next thing ")?.word, "thing")
        XCTAssertEqual(TrailingWordScanner.scan(beforeCursor: "(aside) ")?.word, "aside")
    }

    func testSingleLettersAreLeftAlone() {
        XCTAssertNil(TrailingWordScanner.scan(beforeCursor: "grade a "))
    }
}
