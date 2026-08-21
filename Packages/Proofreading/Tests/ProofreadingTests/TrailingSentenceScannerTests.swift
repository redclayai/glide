import AutocompleteCore
import XCTest
@testable import Proofreading

final class TrailingSentenceScannerTests: XCTestCase {
    // MARK: - Eligibility

    func testScansSentenceAfterCommittedTerminator() {
        let trailing = TrailingSentenceScanner.scanTerminated(beforeCursor: "i has went to the store. ")
        XCTAssertEqual(trailing?.sentence, "i has went to the store.")
        XCTAssertEqual(trailing?.boundary, " ")
    }

    func testAcceptsTerminatorWithNoTrailingSpace() {
        let trailing = TrailingSentenceScanner.scanTerminated(beforeCursor: "i has went to the store.")
        XCTAssertEqual(trailing?.sentence, "i has went to the store.")
        XCTAssertEqual(trailing?.boundary, "")
    }

    func testSpanEndsAtCaret() {
        let before = "Hi there. i has went to the store. "
        let span = TrailingSentenceScanner.scanTerminated(beforeCursor: before)?.span
        XCTAssertEqual(span?.original, "i has went to the store. ")
        XCTAssertTrue(before.hasSuffix(span?.original ?? "!"), "span must be a suffix of the text before the caret")
    }

    func testTerminatedScanIgnoresUnterminatedText() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "i has went to the store"))
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "i has went to the store "))
    }

    // MARK: - Unterminated sentences (offered only after a pause)

    /// Most chat messages never get their final period, so refusing to look at them meant the
    /// grammar pass almost never fired in practice.
    func testScansUnterminatedTextAtAWordBoundary() {
        let trailing = TrailingSentenceScanner.scanUnterminated(beforeCursor: "Ok I have think abo it ")
        XCTAssertEqual(trailing?.sentence, "Ok I have think abo it")
        XCTAssertEqual(trailing?.boundary, " ")
    }

    /// Someone who types a sentence and stops leaves the caret directly after the last letter, so
    /// requiring a trailing boundary meant the pass was never reachable in practice. The pause is
    /// the signal, not the space.
    func testScansUnterminatedTextWithTheCaretMidWord() {
        let trailing = TrailingSentenceScanner.scanUnterminated(beforeCursor: "Ok I have think abo it")
        XCTAssertEqual(trailing?.sentence, "Ok I have think abo it")
        XCTAssertEqual(trailing?.boundary, "")
    }

    func testUnterminatedScanStillRefusesAcrossNewline() {
        XCTAssertNil(TrailingSentenceScanner.scanUnterminated(beforeCursor: "Ok I have think abo it\n"))
    }

    func testUnterminatedScanStopsAtThePreviousSentence() {
        let trailing = TrailingSentenceScanner.scanUnterminated(beforeCursor: "That was fine. but he dont agree ")
        XCTAssertEqual(trailing?.sentence, "but he dont agree")
    }

    func testUnterminatedScanAppliesTheSameSizeAndProseGates() {
        XCTAssertNil(TrailingSentenceScanner.scanUnterminated(beforeCursor: "yes ok "))
        XCTAssertNil(TrailingSentenceScanner.scanUnterminated(beforeCursor: "see https://example.org/docs now "))
    }

    // MARK: - Dispatch

    func testScanReportsTermination() {
        let terminated = TrailingSentenceScanner.scan(beforeCursor: "i has went to the store. ")
        XCTAssertEqual(terminated?.termination, .terminated)

        let unterminated = TrailingSentenceScanner.scan(beforeCursor: "i has went to the store ")
        XCTAssertEqual(unterminated?.termination, .unterminated)
        XCTAssertEqual(unterminated?.sentence.sentence, "i has went to the store")

        // Mid-word now qualifies — the pause is what gates it, not a trailing space.
        let midWord = TrailingSentenceScanner.scan(beforeCursor: "i has went to the stor")
        XCTAssertEqual(midWord?.termination, .unterminated)

        // Still nothing to say about a fragment.
        XCTAssertNil(TrailingSentenceScanner.scan(beforeCursor: "yes ok"))
    }

    func testStopsAtPreviousSentence() {
        let trailing = TrailingSentenceScanner.scanTerminated(beforeCursor: "That was fine. But he don't agree with it. ")
        XCTAssertEqual(trailing?.sentence, "But he don't agree with it.")
    }

    /// "e.g." and "Dr." must not truncate the sentence they sit inside.
    func testAbbreviationsDoNotTruncateTheSentence() {
        let trailing = TrailingSentenceScanner.scanTerminated(beforeCursor: "We should ask Dr. Ramirez about it. ")
        XCTAssertEqual(trailing?.sentence, "We should ask Dr. Ramirez about it.")
    }

    func testRefusesAcrossNewline() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "All done.\n"))
    }

    // MARK: - Size and content gates

    func testRefusesFragments() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "Yes. "))
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "Sounds good. "))
    }

    func testRefusesSentencesTooLongToApply() {
        let long = String(repeating: "word ", count: 60) + "end. "
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: long))
    }

    /// An ordinary two-clause sentence must not be refused for length — the old 140-character cap
    /// rejected sentences this size, which read as the feature not working on real writing.
    func testAcceptsAnOrdinaryLongSentence() {
        let sentence = "I have one that is new construction but they moved things into the "
            + "apartment so it needs a review of record before we can close on it. "
        XCTAssertEqual(sentence.trimmingCharacters(in: .whitespaces).count, 134)
        XCTAssertNotNil(TrailingSentenceScanner.scanTerminated(beforeCursor: sentence))

        let longer = "We should confirm whether the affiliated lender covers all construction "
            + "renewals or just the ones we are waiving the review of record for, because the "
            + "answer changes the timeline. "
        XCTAssertNotNil(
            TrailingSentenceScanner.scanTerminated(beforeCursor: longer),
            "a 180-character sentence is ordinary prose, not an outlier"
        )
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

// MARK: - What counts as a finished sentence

/// A typed terminator now fires the check promptly, so a period that isn't a full stop shows up as a
/// spurious suggestion rather than being quietly absorbed by a longer wait.
final class SentenceTerminatorTests: XCTestCase {
    func testAbbreviationIsNotAFinishedSentence() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "We should ask Dr. "))
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "Use a wrench, e.g. "))
    }

    func testDecimalPointIsNotAFinishedSentence() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "The rate moved to 3.5 "))
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "We shipped version 1.2 "))
    }

    func testInitialIsNotAFinishedSentence() {
        XCTAssertNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "The author is J. "))
    }

    func testOrdinarySentenceStillCounts() {
        XCTAssertNotNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "i has went to the store. "))
        XCTAssertNotNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "did you send the files yet? "))
        XCTAssertNotNil(TrailingSentenceScanner.scanTerminated(beforeCursor: "that was not what we agreed! "))
    }

    /// The abbreviation must not block a sentence that legitimately ends after one.
    func testSentenceEndingAfterAnAbbreviationCounts() {
        let trailing = TrailingSentenceScanner.scanTerminated(
            beforeCursor: "We should ask Dr. Ramirez about it. "
        )
        XCTAssertEqual(trailing?.sentence, "We should ask Dr. Ramirez about it.")
    }
}
