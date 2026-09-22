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
}
