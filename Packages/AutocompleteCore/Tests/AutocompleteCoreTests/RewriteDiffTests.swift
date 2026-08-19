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
