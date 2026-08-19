import AutocompleteCore
import XCTest
@testable import TokenProfiles

/// Random-input invariants. The trie cursor must NEVER trap, regardless of the byte
/// sequence we feed it — adversarial / corrupt input is expected at runtime once user
/// prefixes drive the prefix walk. Returning `nil` is fine; precondition failures /
/// out-of-bounds dereferences are not.
final class TrieFuzzTests: XCTestCase {

    func testRandomPrefixesNeverTrap() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        var rng = SystemRandomNumberGenerator()
        let iterations = 10_000
        for _ in 0..<iterations {
            let len = Int.random(in: 0...64, using: &rng)
            var bytes = [UInt8](repeating: 0, count: len)
            for i in 0..<len { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            // We just need to make sure this returns without trapping. Either some
            // state or nil is fine; we don't assert any structural property.
            _ = profile.prefixStart(requiredBytes: bytes)
        }
    }

    func testRandomAdvancePreservesInvariant() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        var rng = SystemRandomNumberGenerator()
        let maxNode = UInt32(profile.trieNodeCountValue)
        for _ in 0..<5_000 {
            let randomNode = UInt32.random(in: 0..<max(1, maxNode), using: &rng)
            let state = TrieState(nodeIndex: randomNode)
            let randomID = TokenID.random(in: 0..<TokenID(built.vocabSize), using: &rng)
            // Either returns a valid (in-range) state or nil. Crash = test fail.
            if let next = profile.prefixAdvance(state, by: randomID) {
                XCTAssertLessThan(next.nodeIndex, maxNode)
            }
        }
    }

    func testTokenAllowedNeverTraps() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        var rng = SystemRandomNumberGenerator()
        let maxNode = UInt32(profile.trieNodeCountValue)
        for _ in 0..<5_000 {
            let randomNode = UInt32.random(in: 0..<max(1, maxNode), using: &rng)
            let state = TrieState(nodeIndex: randomNode)
            let randomID = TokenID.random(in: -10..<TokenID(built.vocabSize + 10), using: &rng)
            _ = profile.tokenAllowed(randomID, in: state)
            _ = profile.tokenAllowed(randomID, afterRequiredPrefix: [UInt8.random(in: 0...255, using: &rng)])
        }
    }
}
