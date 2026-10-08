import XCTest
@testable import AutocompleteCore

final class RewriteDiffTests: XCTestCase {
    private func changed(_ diff: RewriteDiff) -> [String] {
        diff.segments.filter(\.isChanged).map { $0.text.trimmingCharacters(in: .whitespaces) }
    }

    /// Concatenating the segments must reproduce the replacement exactly, or the rendered
    /// suggestion would not match the text that gets inserted.
    func testSegmentsReconstructTheReplacement() {
        let replacement = "Okay, I am going to be honest."
        let diff = RewriteDiff.between(original: "Ok I am going t be honest", replacement: replacement)
        XCTAssertEqual(diff.segments.map(\.text).joined(), replacement)
    }

    func testMarksOnlyTheWordsThatChanged() {
        let diff = RewriteDiff.between(
            original: "He don't agree with it.",
            replacement: "He doesn't agree with it."
        )
        XCTAssertEqual(changed(diff), ["doesn't"])
    }

    func testMarksAnAddedWord() {
        let diff = RewriteDiff.between(
            original: "I am going be honest",
            replacement: "I am going to be honest"
        )
        XCTAssertEqual(changed(diff), ["to"])
    }

    /// Punctuation and case alone are not a word change — otherwise capitalising the first word
    /// would light up the whole sentence.
    func testIgnoresPunctuationAndCase() {
        let diff = RewriteDiff.between(
            original: "the team finished their work",
            replacement: "The team finished their work."
        )
        XCTAssertTrue(changed(diff).isEmpty)
    }

    func testEverythingChangedWhenNothingIsShared() {
        let diff = RewriteDiff.between(original: "alpha beta", replacement: "gamma delta")
        XCTAssertEqual(diff.changedWordCount, 1, "adjacent changed words merge into one segment")
        XCTAssertEqual(diff.segments.map(\.text).joined(), "gamma delta")
    }

    func testAdjacentChangesMergeIntoOneSegment() {
        let diff = RewriteDiff.between(original: "we was late", replacement: "we were very late")
        let segments = diff.segments
        XCTAssertEqual(segments.map(\.text).joined(), "we were very late")
        XCTAssertEqual(segments.filter(\.isChanged).count, 1)
    }

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(RewriteDiff.between(original: "", replacement: "").segments.isEmpty)
        XCTAssertEqual(RewriteDiff.between(original: "", replacement: "new text").changedWordCount, 1)
    }

    func testChangedCharacterCountMeasuresOnlyTheNewText() {
        let diff = RewriteDiff.between(original: "He don't agree", replacement: "He doesn't agree")
        XCTAssertEqual(diff.changedCharacterCount, "doesn't ".count)
    }
}

// MARK: - Two-sided edits

extension RewriteDiffTests {
    private func rendered(_ edits: [RewriteDiff.Edit]) -> String {
        edits.map { edit in
            switch edit {
            case let .kept(text): return text
            case let .inserted(text): return "{+\(text)+}"
            case let .removed(text): return "{-\(text)-}"
            }
        }.joined()
    }

    func testEditsShowBothSidesOfAWordSwap() {
        let edits = RewriteDiff.edits(original: "we can hear back on Scott",
                                      replacement: "we can hear back from Scott")
        XCTAssertEqual(rendered(edits), "we can hear back {-on -}{+from +}Scott")
    }

    func testEditsMarkPureInsertion() {
        let edits = RewriteDiff.edits(original: "they going to send it",
                                      replacement: "they are going to send it")
        XCTAssertEqual(rendered(edits), "they {+are +}going to send it")
    }

    func testEditsMarkPureDeletion() {
        let edits = RewriteDiff.edits(original: "we can just simply ship it",
                                      replacement: "we can ship it")
        // Adjacent removals merge into one run, which is the point of the merging step — two
        // separately-struck words read as two separate edits.
        XCTAssertEqual(rendered(edits), "we can {-just simply -}ship it")
    }

    func testIdenticalTextIsAllKept() {
        let edits = RewriteDiff.edits(original: "no change here", replacement: "no change here")
        XCTAssertEqual(edits, [.kept("no change here")])
    }

    /// Every kept and inserted run, concatenated, must reproduce the replacement exactly — otherwise
    /// the card is showing text that differs from what Replace would insert.
    func testKeptAndInsertedReproduceTheReplacement() {
        let original = "Worst case, if we cant access the APIs we can use automation."
        let replacement = "Worst case, if we can't access the APIs, we can use automation to extract it."
        let edits = RewriteDiff.edits(original: original, replacement: replacement)
        let reconstructed = edits.compactMap { edit -> String? in
            switch edit {
            case let .kept(text), let .inserted(text): return text
            case .removed: return nil
            }
        }.joined()
        XCTAssertEqual(reconstructed, replacement)
    }
}
