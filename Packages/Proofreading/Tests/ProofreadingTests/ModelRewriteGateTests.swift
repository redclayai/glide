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

    /// The case that exposed character distance as the wrong measure: every word the writer chose
    /// survives, corrected in place, but half the characters change.
    func testAcceptsACorrectionThatRewritesManyCharacters() {
        XCTAssertTrue(ModelRewriteGate.accepts(
            candidate: "Okay, I have thought about it.",
            original: "Ok I have think abo it"
        ))
        XCTAssertGreaterThan(
            ModelRewriteGate.editRatio(candidate: "Okay, I have thought about it.", original: "Ok I have think abo it"),
            0.34,
            "this is exactly the correction the old character threshold rejected"
        )
    }

    func testAcceptsPunctuationOnlyFixesOnUnterminatedText() {
        XCTAssertTrue(ModelRewriteGate.accepts(candidate: "Can you send me the file?", original: "can you send me the file"))
        XCTAssertTrue(ModelRewriteGate.accepts(candidate: "Let's meet at 3pm tomorrow.", original: "Lets meet at 3pm tomorrow"))
    }

    // MARK: - Word retention

    func testRetentionSeparatesCorrectionFromRevoicing() {
        let correction = ModelRewriteGate.wordRetention(
            candidate: "Okay, I have thought about it.", original: "Ok I have think abo it"
        )
        let revoicing = ModelRewriteGate.wordRetention(
            candidate: "He disagrees with it.", original: "He don't agree with it."
        )
        XCTAssertGreaterThanOrEqual(correction, ModelRewriteGate.minimumWordRetention)
        XCTAssertLessThan(revoicing, ModelRewriteGate.minimumWordRetention)
    }

    func testWordsAreTheSameWhenCorrectedInPlace() {
        XCTAssertTrue(ModelRewriteGate.isSameWord("abo", "about"))
        XCTAssertTrue(ModelRewriteGate.isSameWord("finish", "finished"))
        XCTAssertTrue(ModelRewriteGate.isSameWord("agree", "agree"))
        XCTAssertFalse(ModelRewriteGate.isSameWord("agree", "disagrees"))
        XCTAssertFalse(ModelRewriteGate.isSameWord("cat", "dog"))
    }

    func testRetentionIsZeroAgainstUnrelatedText() {
        XCTAssertEqual(
            ModelRewriteGate.wordRetention(candidate: "Completely different words here.", original: "He don't agree."),
            0,
            accuracy: 0.01
        )
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
