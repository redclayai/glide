import AutocompleteCore
import XCTest
@testable import TokenProfiles

final class TriePresenceTests: XCTestCase {

    func testEveryNonExcludedTokenAppearsInTrie() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for (i, entry) in built.entries.enumerated() {
            if entry.flags.contains(.excluded) { continue }
            if entry.bytes.isEmpty { continue }
            guard let state = profile.prefixStart(requiredBytes: entry.bytes) else {
                return XCTFail("token \(i) (\(entry.bytes)) not reachable")
            }
            XCTAssertEqual(profile.terminalTokenID(at: state), TokenID(i),
                           "token \(i) reached state \(state.nodeIndex) but terminal != \(i)")
        }
    }

    func testExcludedTokensAreNotTerminals() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for (i, entry) in built.entries.enumerated() {
            guard entry.flags.contains(.excluded) else { continue }
            guard !entry.bytes.isEmpty else { continue }
            // Either the trie has no path for the excluded bytes, or the path's
            // terminal token id is something else (or none). The key invariant: the
            // excluded id must NOT be the terminal at the node reached by walking
            // its own bytes from the root.
            if let state = profile.prefixStart(requiredBytes: entry.bytes) {
                XCTAssertNotEqual(profile.terminalTokenID(at: state), TokenID(i),
                                  "excluded token \(i) is the terminal at \(state.nodeIndex)")
            }
        }
    }

    func testPrefixStartEmptyReturnsRoot() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        let state = profile.prefixStart(requiredBytes: [])
        XCTAssertEqual(state?.nodeIndex, 0)
    }

    func testPrefixAdvanceMatchesPrefixStart() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Pick a non-excluded token and assert that prefixAdvance(state, by: t) starting
        // from the root lands at the same node as prefixStart(t.bytes).
        for (i, entry) in built.entries.enumerated() {
            if entry.flags.contains(.excluded) { continue }
            if entry.bytes.isEmpty { continue }
            let root = TrieState(nodeIndex: 0)
            guard let advanced = profile.prefixAdvance(root, by: TokenID(i)) else {
                return XCTFail("could not advance by token \(i)")
            }
            guard let direct = profile.prefixStart(requiredBytes: entry.bytes) else {
                return XCTFail("could not prefixStart token \(i)")
            }
            XCTAssertEqual(advanced.nodeIndex, direct.nodeIndex, "token \(i) advanced=\(advanced.nodeIndex) direct=\(direct.nodeIndex)")
        }
    }
}
