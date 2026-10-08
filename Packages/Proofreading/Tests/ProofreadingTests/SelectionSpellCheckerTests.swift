import AppKit
import XCTest
@testable import Proofreading

/// Exercises the real `NSSpellChecker`, deliberately. The whole value of this type is which words the
/// system dictionary does and does not flag, and a stubbed checker would test only the traversal.
@MainActor
final class SelectionSpellCheckerTests: XCTestCase {
    private var checker: SelectionSpellChecker!

    override func setUp() async throws {
        checker = SelectionSpellChecker()
    }

    func testCorrectsPlainMisspellings() {
        XCTAssertEqual(checker.corrected("The recieved invoice was inccorect."),
                       "The received invoice was incorrect.")
    }

    /// The reported case. `checkSpelling(of:startingAt:)` does not flag this word in context at all,
    /// which is why the implementation uses `check(_:range:types:)` instead.
    func testCorrectsAWordCheckSpellingMisses() {
        XCTAssertEqual(checker.corrected("This is a testt."), "This is a test.")
    }

    func testCorrectsSeveralInOnePass() {
        XCTAssertEqual(
            checker.corrected("I'm definately going to seperate these."),
            "I'm definitely going to separate these."
        )
    }

    func testLeavesCleanTextAlone() {
        let clean = "No mistakes here at all."
        XCTAssertEqual(checker.corrected(clean), clean)
    }

    /// Capitalised mid-sentence words are names far more often than typos. Measured: the checker's
    /// first in-context guess for "Cueo" is "Cleo", which renames a product rather than fixing it.
    func testLeavesProperNounsAlone() {
        let text = "Danny Baute works at FCM on Millie and Cueo."
        XCTAssertEqual(checker.corrected(text), text)
    }

    /// But a sentence-initial word is fair game, and keeps its capital.
    func testCorrectsSentenceInitialWordsAndPreservesCase() {
        XCTAssertEqual(checker.corrected("Teh meeting is at noon."), "The meeting is at noon.")
    }

    /// Grammar is not this type's job — the model's half of the pass handles it.
    func testDoesNotAttemptGrammar() {
        let text = "we was late and i think we should of called."
        XCTAssertEqual(checker.corrected(text), text)
    }

    func testEmptyInput() {
        XCTAssertEqual(checker.corrected(""), "")
    }

    // MARK: - Pure helpers

    func testSentenceDetection() {
        let text = "One. Two" as NSString
        XCTAssertTrue(SelectionSpellChecker.startsSentence(at: 0, in: text))
        XCTAssertTrue(SelectionSpellChecker.startsSentence(at: 5, in: text), "after a terminator")
        XCTAssertFalse(SelectionSpellChecker.startsSentence(at: 1, in: text), "mid-word")
    }

    func testCaseCarriesOntoTheReplacement() {
        XCTAssertEqual(SelectionSpellChecker.matchingCase(of: "teh", in: "the"), "the")
        XCTAssertEqual(SelectionSpellChecker.matchingCase(of: "Teh", in: "the"), "The")
        XCTAssertEqual(SelectionSpellChecker.matchingCase(of: "TEH", in: "the"), "THE")
    }

    // MARK: - The agreement gate
    //
    // These went in when corrections started being applied the moment text is selected rather than
    // on request. Each case below was produced by one engine and rejected by the other, and each
    // would have silently replaced a word the user meant to write.

    func testOrdinaryTyposAreStillCorrected() {
        XCTAssertEqual(
            checker.corrected("I recieved your emial about the seperate departmant."),
            "I received your email about the separate department."
        )
        XCTAssertEqual(checker.corrected("Teh meetng is tommorow."), "The meeting is tomorrow.")
    }

    func testVerbFormErrorsAreLeftForTheModel() {
        // "sended" → guesses says "seeded", autocorrect says "ended". Neither is the word, and the
        // disagreement is what says so. Tense is grammar's job, and grammar runs next.
        for sentence in [
            "The report was sended to the client on Monday.",
            "She writed a letter and goed to the post office.",
        ] {
            XCTAssertEqual(checker.corrected(sentence), sentence)
        }
    }

    func testSeveralTyposCloseTogether() {
        // The checker reports this one as a single twelve-character span, "Teh meetng i", with no
        // guesses. Taken at face value it corrected nothing; skipped, it lost "Teh".
        XCTAssertEqual(checker.corrected("Teh meetng is tommorow."), "The meeting is tomorrow.")
    }

    func testProductNamesSurvive() {
        // "Supabase" attracted the guess "Superbness", which is the kind of correction that makes
        // the feature worse than not having it.
        let sentence = "Our kubernetes cluster uses Supabase and Sparkle."
        XCTAssertEqual(checker.corrected(sentence), sentence)
    }
}
