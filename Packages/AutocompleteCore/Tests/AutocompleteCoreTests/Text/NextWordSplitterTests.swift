import AutocompleteCore
import XCTest

final class NextWordSplitterTests: XCTestCase {
    func testEmpty() {
        let (head, rest) = NextWordSplitter.split("")
        XCTAssertEqual(head, "")
        XCTAssertEqual(rest, "")
    }

    func testSingleWordAcceptsWholesale() {
        let (head, rest) = NextWordSplitter.split("tomorrow")
        XCTAssertEqual(head, "tomorrow")
        XCTAssertEqual(rest, "")
    }

    func testMidWordCompletionWithoutLeadingSpace() {
        // The word's trailing space stays with the rest so it leads the next word.
        let (head, rest) = NextWordSplitter.split("orrow to talk")
        XCTAssertEqual(head, "orrow")
        XCTAssertEqual(rest, " to talk")
    }

    func testLeadingWhitespaceTravelsWithFirstWord() {
        // Leading whitespace travels with the word it precedes; trailing whitespace does not.
        let (head, rest) = NextWordSplitter.split(" world today")
        XCTAssertEqual(head, " world")
        XCTAssertEqual(rest, " today")
    }

    func testSpaceLeadsEachWordNotTrails() {
        // "word word word." → ["word", " word", " word", "."].
        XCTAssertEqual(walk("word word word."), ["word", " word", " word", "."])
        // " word word word." → [" word", " word", " word", "."].
        XCTAssertEqual(walk(" word word word."), [" word", " word", " word", "."])
    }

    /// Repeatedly splits `text`, collecting each accepted head until the suggestion is exhausted.
    private func walk(_ text: String) -> [String] {
        var remaining = text
        var heads: [String] = []
        while !remaining.isEmpty {
            let (head, rest) = NextWordSplitter.split(remaining)
            XCTAssertFalse(head.isEmpty, "split must always make progress")
            heads.append(head)
            remaining = rest
        }
        return heads
    }

    func testRepeatedSplitWalksTheSuggestion() {
        var remaining = " quick brown fox"
        var accepted = ""
        while !remaining.isEmpty {
            let (head, rest) = NextWordSplitter.split(remaining)
            accepted += head
            remaining = rest
        }
        XCTAssertEqual(accepted, " quick brown fox")
    }

    func testChineseIsSegmentedNotTakenWholesale() {
        // ICU segments Chinese into words, so the first Tab should not swallow the whole string.
        let (head, rest) = NextWordSplitter.split("今天天气很好")
        XCTAssertFalse(head.isEmpty)
        XCTAssertFalse(rest.isEmpty)
        XCTAssertEqual(head + rest, "今天天气很好")
    }

    func testTrailingPeriodIsASeparateUnit() {
        // The reported case: "esses." should accept the word first, then the period.
        let (head, rest) = NextWordSplitter.split("esses.")
        XCTAssertEqual(head, "esses")
        XCTAssertEqual(rest, ".")
    }

    func testLeadingPunctuationAcceptsAlone() {
        let (head, rest) = NextWordSplitter.split(".")
        XCTAssertEqual(head, ".")
        XCTAssertEqual(rest, "")
    }

    func testCommaSplitsFromWordAndSpaceLeadsNextWord() {
        // "world, today" → "world", then "," (the comma alone), then " today" (space leads the word).
        let (firstHead, afterWord) = NextWordSplitter.split("world, today")
        XCTAssertEqual(firstHead, "world")
        XCTAssertEqual(afterWord, ", today")

        let (punctHead, afterPunct) = NextWordSplitter.split(afterWord)
        XCTAssertEqual(punctHead, ",")
        XCTAssertEqual(afterPunct, " today")
    }

    func testRunOfPunctuationIsOneUnit() {
        let (head, rest) = NextWordSplitter.split("really?!")
        XCTAssertEqual(head, "really")
        XCTAssertEqual(rest, "?!")

        let (punctHead, after) = NextWordSplitter.split(rest)
        XCTAssertEqual(punctHead, "?!")
        XCTAssertEqual(after, "")
    }

    func testWordSplitLeavesSeparatorWithNextWord() {
        // The separator after the first word leads the next word rather than trailing this one.
        let (head, rest) = NextWordSplitter.split("hello there friend")
        XCTAssertEqual(head, "hello")
        XCTAssertEqual(rest, " there friend")
    }

    func testWalkingASentenceWithPunctuationReconstructsIt() {
        var remaining = "we go, then stop."
        var accepted = ""
        var steps = 0
        while !remaining.isEmpty {
            let (head, rest) = NextWordSplitter.split(remaining)
            XCTAssertFalse(head.isEmpty, "split must always make progress")
            accepted += head
            remaining = rest
            steps += 1
            XCTAssertLessThan(steps, 50, "split is not terminating")
        }
        XCTAssertEqual(accepted, "we go, then stop.")
    }

    func testFullWidthPunctuationSplitsFromCJKWord() {
        // ICU segments CJK character-by-character here, so don't assume "你好" is one word — just
        // assert the full-width comma is confirmed as its own unit (never glued to a CJK character)
        // and the walk reconstructs the input.
        var remaining = "你好，今天"
        var heads: [String] = []
        var steps = 0
        while !remaining.isEmpty {
            let (head, rest) = NextWordSplitter.split(remaining)
            XCTAssertFalse(head.isEmpty)
            heads.append(head)
            remaining = rest
            steps += 1
            XCTAssertLessThan(steps, 50)
        }
        XCTAssertEqual(heads.joined(), "你好，今天")
        XCTAssertTrue(heads.contains("，"), "full-width comma should be its own accept unit")
    }
}
