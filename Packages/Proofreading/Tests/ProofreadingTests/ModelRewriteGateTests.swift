import XCTest
@testable import Proofreading

final class ModelRewriteGateTests: XCTestCase {
    // MARK: - Unwrapping

    func testStripsPreambles() {
        XCTAssertEqual(ModelRewriteGate.unwrap("Corrected: He doesn't agree."), "He doesn't agree.")
        XCTAssertEqual(ModelRewriteGate.unwrap("Here is the fixed sentence"), "the fixed sentence")
        XCTAssertEqual(ModelRewriteGate.unwrap("Sure, He doesn't agree."), "He doesn't agree.")
    }

    func testStripsWrappingQuotes() {
        XCTAssertEqual(ModelRewriteGate.unwrap("\"He doesn't agree.\""), "He doesn't agree.")
        XCTAssertEqual(ModelRewriteGate.unwrap("\u{201C}He doesn't agree.\u{201D}"), "He doesn't agree.")
    }

    /// Anything past the first line is commentary or an invented second sentence.
    func testKeepsOnlyTheFirstLine() {
        let raw = "He doesn't agree.\n\nI changed \"don't\" to \"doesn't\" for subject-verb agreement."
        XCTAssertEqual(ModelRewriteGate.unwrap(raw), "He doesn't agree.")
    }

    func testLeavesACleanSentenceAlone() {
        XCTAssertEqual(ModelRewriteGate.unwrap("  He doesn't agree.  "), "He doesn't agree.")
    }

    // MARK: - Acceptance

    func testAcceptsAGenuineGrammarFix() {
        XCTAssertTrue(ModelRewriteGate.accepts(
            candidate: "He doesn't agree with it.",
            original: "He don't agree with it."
        ))
        XCTAssertTrue(ModelRewriteGate.accepts(
            candidate: "I went to the store.",
            original: "I has went to the store."
        ))
    }

    func testRejectsUnchangedOrEmpty() {
        XCTAssertFalse(ModelRewriteGate.accepts(candidate: "He don't agree.", original: "He don't agree."))
        XCTAssertFalse(ModelRewriteGate.accepts(candidate: "", original: "He don't agree."))
    }

    /// A re-voicing is the Polish feature, which the user did not ask for here.
    func testRejectsAWholesaleRewrite() {
        XCTAssertFalse(ModelRewriteGate.accepts(
            candidate: "Unfortunately, he remains unconvinced by the proposal.",
            original: "He don't agree with it."
        ))
    }

    func testRejectsAnAnswerInsteadOfACorrection() {
        XCTAssertFalse(ModelRewriteGate.accepts(
            candidate: "Yes, the store closes at nine tonight.",
            original: "What time do the store close?"
        ))
    }

    func testRejectsAnInventedSecondSentence() {
        XCTAssertFalse(ModelRewriteGate.accepts(
            candidate: "He doesn't agree. Let me know your thoughts.",
            original: "He don't agree with it."
        ))
    }

    func testRejectsMaterialLengthChange() {
        XCTAssertFalse(ModelRewriteGate.accepts(candidate: "He disagrees.", original: "He don't agree with it at all."))
    }

    // MARK: - Helpers

    func testLevenshteinIsCorrect() {
        XCTAssertEqual(ModelRewriteGate.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(ModelRewriteGate.levenshtein("", "abc"), 3)
        XCTAssertEqual(ModelRewriteGate.levenshtein("same", "same"), 0)
    }

    func testSentenceCountIgnoresRepeatedTerminators() {
        XCTAssertEqual(ModelRewriteGate.sentenceCount("One thing."), 1)
        XCTAssertEqual(ModelRewriteGate.sentenceCount("One thing... really"), 1)
        XCTAssertEqual(ModelRewriteGate.sentenceCount("One. Two."), 2)
    }
}
