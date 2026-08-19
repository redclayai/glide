import AutocompleteCore
@testable import ConstrainedGeneration
import XCTest

/// Unit coverage for `GenerationBranch.truncatedToText(prefixCharCount:)` — the token-aligned cut
/// used to salvage a suffix-overlapping mid-line branch (ADR-057).
final class GenerationBranchTruncationTests: XCTestCase {
    /// Builds a branch by emitting `(bytes, logProbability)` tokens in order.
    private func branch(_ tokens: [(id: TokenID, text: String, logProbability: Float)]) -> GenerationBranch {
        var current = GenerationBranch()
        for token in tokens {
            switch current.extending(
                withToken: token.id,
                bytes: Array(token.text.utf8),
                logProbability: token.logProbability,
                maxDisplayWidth: 1_000
            ) {
            case let .extended(next):
                current = next
            default:
                XCTFail("token \(token.id) unexpectedly rejected")
            }
        }
        return current
    }

    func testTruncatesAtTokenBoundaryAndRecomputesDerivedState() {
        let full = branch([
            (1, "Paris ", -1.0),
            (11, "the largest ", -1.0),
            (12, "city", -2.0)
        ])
        XCTAssertEqual(full.text, "Paris the largest city")

        // "Paris " is exactly 6 characters / 6 bytes — one whole token.
        let truncated = full.truncatedToText(prefixCharCount: 6)
        XCTAssertEqual(truncated.text, "Paris ")
        XCTAssertEqual(truncated.tokenIDs, [1])
        XCTAssertEqual(truncated.displayWidth, 6)
        XCTAssertEqual(truncated.score, -1.0, accuracy: 1e-6, "score is the sum of the retained tokens only")
    }

    func testRoundsDownWhenCharBoundaryFallsInsideAToken() {
        let full = branch([(1, "Paris ", -1.0), (11, "the largest ", -1.0)])
        // 9 characters would land inside the second token ("the largest "); round down to "Paris ".
        let truncated = full.truncatedToText(prefixCharCount: 9)
        XCTAssertEqual(truncated.text, "Paris ")
        XCTAssertEqual(truncated.tokenIDs, [1])
    }

    func testZeroPrefixYieldsEmptyBranch() {
        let full = branch([(1, "Paris ", -1.0)])
        let truncated = full.truncatedToText(prefixCharCount: 0)
        XCTAssertTrue(truncated.text.isEmpty)
        XCTAssertTrue(truncated.tokenIDs.isEmpty)
        XCTAssertEqual(truncated.score, 0)
    }

    func testPrefixCountAtOrBeyondLengthReturnsSelf() {
        let full = branch([(1, "Paris ", -1.0), (11, "city", -1.0)])
        XCTAssertEqual(full.truncatedToText(prefixCharCount: full.text.count), full)
        XCTAssertEqual(full.truncatedToText(prefixCharCount: 999), full)
    }
}
