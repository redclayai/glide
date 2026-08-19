import XCTest
@testable import AutocompleteCore

/// Coverage for `SuffixOverlapGuard.nonDuplicatingPrefixLength`, which maps the suffix-overlap point
/// back to a character count of the original completion so the engine can *truncate* a duplicating
/// branch at the genuine "middle" instead of discarding it (ADR-057).
final class SuffixOverlapGuardTruncationTests: XCTestCase {
    private func keep(_ completion: String, before: String = "", after: String) -> Int? {
        SuffixOverlapGuard.nonDuplicatingPrefixLength(
            completion: completion,
            beforeCursor: before,
            afterCursor: after
        )
    }

    // MARK: - No overlap → keep the whole completion (nil)

    func testReturnsNilForGenuineMidLineInsertion() {
        XCTAssertNil(keep("like", before: "I really ", after: "this idea is great"))
    }

    func testReturnsNilForEndOfLineContinuation() {
        XCTAssertNil(keep(" world", before: "hello", after: ""))
    }

    // MARK: - Whole completion is a copy → keep nothing (0)

    func testReturnsZeroForBoundaryAlignedCopy() {
        XCTAssertEqual(
            keep(
                "performance to the RTX 5070, so it's",
                before: "This GPU has a similar level of ",
                after: "performance to the RTX 5070, so it's close to a mid-range GPU."
            ),
            0
        )
    }

    func testReturnsZeroForMidWordCopyWhollyInsideSuffix() {
        // Shape 3: the completion lies entirely within the suffix, so there is no salvageable middle.
        XCTAssertEqual(
            keep(
                " of performance to the RTX 5070, so it's",
                before: "This GPU has a similar lev",
                after: "el of performance to the RTX 5070, so it's close to a mid-range GPU."
            ),
            0
        )
    }

    // MARK: - Genuine middle then a suffix copy → keep the middle (n > 0)

    func testKeepsTheMiddleBeforeASuffixContainedCopy() {
        // The completion emits a real fill ("Paris, which ") and then re-types the suffix verbatim.
        let completion = "Paris, which is the largest city."
        let length = keep(completion, before: "The capital of ", after: "is the largest city.")
        let kept = length.map { String(completion.prefix($0)) }
        XCTAssertEqual(kept, "Paris, which ")
    }

    func testShortGarbagePrefixKeepsOnlyAFewChars() {
        // The known "ithub repo for KeyType." defect: only the leading "it" precedes the suffix copy
        // ("hub repo…"), so the salvaged length is tiny — the engine's minimum-length gate then drops it.
        let completion = "ithub repo for KeyType."
        let length = keep(completion, before: "Assume I will create a Git", after: "hub repo for KeyType.")
        XCTAssertEqual(length, 2)
    }

    // MARK: - Mapping helper

    func testOriginalPrefixCharacterCountCountsAlphanumericScalars() {
        // "Paris, which " has 10 alphanumerics across 13 characters (commas/spaces don't count).
        XCTAssertEqual(
            SuffixOverlapGuard.originalPrefixCharacterCount(of: "Paris, which is", keepingFirstAlphanumerics: 10),
            "Paris, which ".count
        )
        XCTAssertEqual(
            SuffixOverlapGuard.originalPrefixCharacterCount(of: "anything", keepingFirstAlphanumerics: 0),
            0
        )
    }
}
