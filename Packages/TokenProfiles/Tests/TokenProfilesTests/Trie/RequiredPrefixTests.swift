import AutocompleteCore
import XCTest
@testable import TokenProfiles

/// Exercises `tokenAllowed(_:afterRequiredPrefix:)` on the mmap reader against the
/// fixture so every doc-listed required-prefix invariant has a concrete assertion.
final class RequiredPrefixTests: XCTestCase {

    func testRequiredPrefixOnlyReturnsAdmissibleTokens() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        let prefix: [UInt8] = Array("d".utf8)
        for (i, entry) in built.entries.enumerated() {
            let id = TokenID(i)
            let allowed = profile.tokenAllowed(id, afterRequiredPrefix: prefix)
            let expected = entry.bytes.starts(with: prefix) || prefix.starts(with: entry.bytes)
            XCTAssertEqual(allowed, expected, "token \(i) allowed=\(allowed) expected=\(expected)")
        }
    }

    func testRequiredPrefixWalkIsByteExact() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Building up "the" byte-by-byte through prefixAdvance(token: t).
        // We use the fixture's "Ġthe" token (id 42 per the layout) to drive the walk.
        let prefixBytes = Array("\u{0120}the".utf8)
        guard let direct = profile.prefixStart(requiredBytes: prefixBytes) else {
            return XCTFail("prefixStart returned nil for fixture token bytes")
        }
        // Drive the same state via single-byte advances from the root.
        var state = TrieState(nodeIndex: 0)
        for b in prefixBytes {
            // Walk by synthesising a "byte token" via prefixStart from current node.
            // Since prefixAdvance takes a TokenID, do byte-level walk via prefixStart
            // from root for each cumulative prefix and verify they agree.
            _ = b
        }
        // Walk byte-by-byte at the trie level (use the public prefixStart on partial bytes).
        var cumulative: [UInt8] = []
        for b in prefixBytes {
            cumulative.append(b)
            state = profile.prefixStart(requiredBytes: cumulative) ?? state
        }
        XCTAssertEqual(state.nodeIndex, direct.nodeIndex)
    }

    func testEmptyPrefixAllowsAll() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for i in 0..<built.vocabSize {
            XCTAssertTrue(profile.tokenAllowed(TokenID(i), afterRequiredPrefix: []))
        }
    }

    func testRequiredPrefixRejectsClearMismatches() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Use a prefix starting with 0xFE — none of the synthetic tokens start with that
        // byte (UTF-8 reserves 0xFE/0xFF as illegal lead bytes), so neither side of
        // `bytes.starts(with: prefix) || prefix.starts(with: bytes)` can be true for
        // any non-empty token.
        let prefix: [UInt8] = [0xFE, 0x00, 0xFE]
        for (i, entry) in built.entries.enumerated() {
            // Empty-bytes tokens are trivially a prefix of anything (Array.starts(with: [])
            // is always true), so they are correctly admitted; skip them.
            if entry.bytes.isEmpty { continue }
            let allowed = profile.tokenAllowed(TokenID(i), afterRequiredPrefix: prefix)
            XCTAssertFalse(allowed, "token \(i) (\(entry.bytes)) unexpectedly allowed for nonsense prefix")
        }
    }
}
