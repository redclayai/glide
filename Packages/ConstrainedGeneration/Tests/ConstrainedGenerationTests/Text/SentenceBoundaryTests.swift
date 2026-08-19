@testable import ConstrainedGeneration
import XCTest

final class SentenceBoundaryTests: XCTestCase {
    func testRealSentenceEndsAreTerminal() {
        for text in [
            "I went home.",
            "He said hello.",
            "Are you sure?",
            "Watch out!",
            "It trailed off…",
            "She whispered \"hi.\"",
            "(an aside.)"
        ] {
            XCTAssertTrue(SentenceBoundary.isTerminal(text), "expected terminal: '\(text)'")
        }
    }

    func testDigitPeriodIsNotTerminal() {
        // Numbered list markers and decimals.
        for text in ["you need 1.", "step 2.", "see item 10.", "that is 3.", "pi is 3."] {
            XCTAssertFalse(SentenceBoundary.isTerminal(text), "expected non-terminal: '\(text)'")
        }
    }

    func testAbbreviationsAreNotTerminal() {
        for text in [
            "Please see Mr.",
            "Ask Dr.",
            "for e.g.",
            "that is i.e.",
            "apples, oranges, etc.",
            "based in the U.S.",
            "meet at 9 a.m."
        ] {
            XCTAssertFalse(SentenceBoundary.isTerminal(text), "expected non-terminal: '\(text)'")
        }
    }

    func testSingleUppercaseInitialIsNotTerminal() {
        XCTAssertFalse(SentenceBoundary.isTerminal("signed, J."))
        XCTAssertFalse(SentenceBoundary.isTerminal("George W."))
    }

    func testNonPeriodTokensAreTerminal() {
        // Function is only consulted on flagged tokens; non-period content defaults to terminal.
        XCTAssertTrue(SentenceBoundary.isTerminal("hello"))
        XCTAssertTrue(SentenceBoundary.isTerminal(""))
    }

    func testNonLatinTerminatorsAreTerminal() {
        for text in [
            "これはペンです。",          // Japanese ideographic full stop
            "你好吗？",                  // Chinese fullwidth question
            "太好了！",                  // Chinese fullwidth exclamation
            "यह एक वाक्य है।",           // Hindi danda
            "هذا صحيح؟",                 // Arabic question mark
            "یہ درست ہے۔",               // Urdu Arabic full stop
            "「終わり」"                  // trailing CJK closing quote over a terminator
        ] {
            XCTAssertTrue(SentenceBoundary.isTerminal(text), "expected terminal: '\(text)'")
        }
    }

    func testGermanOrdinalIsNotTerminal() {
        // German ordinals are written "1." — a digit+period that is not a sentence end.
        XCTAssertFalse(SentenceBoundary.isTerminal("am 3."))
        XCTAssertFalse(SentenceBoundary.isTerminal("Heinrich der 8."))
    }

    func testNonEnglishAbbreviationsAreNotTerminal() {
        for text in [
            "zum Beispiel z.B.",   // German
            "und so weiter usw.",  // German
            "das heißt d.h.",      // German
            "par exemple p.ex.",   // French
            "voir cf.",            // French
            "el señor Sr."         // Spanish
        ] {
            XCTAssertFalse(SentenceBoundary.isTerminal(text), "expected non-terminal: '\(text)'")
        }
    }

    func testNonCasedScriptWordPeriodIsTerminal() {
        // A CJK word followed by an ASCII period has no abbreviation/initial ambiguity, so the
        // disambiguator must not suppress it.
        XCTAssertTrue(SentenceBoundary.isTerminal("これはペンです."))
    }
}
