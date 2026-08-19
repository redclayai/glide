import AutocompleteCore
import XCTest
@testable import TokenProfiles

final class TokenTableTests: XCTestCase {

    func testRecordSizesMatchSpec() {
        XCTAssertEqual(ACPF.tokenRecordSize, 32)
        XCTAssertEqual(ACPF.sectionRawSize, 24)
        XCTAssertEqual(ACPF.headerRawSize, 48 + 7 * 24)
        XCTAssertEqual(ACPF.trieNodeSize, 12)
        XCTAssertEqual(ACPF.trieEdgeSize, 8)
    }

    func testEveryIDHasExactlyOneRecord() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        let blobLen = profile.bytesSectionLength
        for id in 0..<built.vocabSize {
            let tokenID = TokenID(id)
            let record = profile.record(for: tokenID)
            XCTAssertNotNil(record, "missing record for token id \(id)")
            // Each record's bytes must fit in the bytes blob.
            let bytes = profile.bytes(for: tokenID)
            XCTAssertLessThanOrEqual(bytes.count, blobLen)
        }
    }

    func testFirstByteSentinel() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for (i, entry) in built.entries.enumerated() {
            let tokenID = TokenID(i)
            let record = profile.record(for: tokenID)
            XCTAssertNotNil(record)
            // We can't read the firstByte field through the public API, but we can
            // re-derive it from the bytes — the on-disk store is internal.
            if entry.bytes.isEmpty {
                XCTAssertEqual(record?.bytes.count, 0)
            } else {
                XCTAssertEqual(record?.bytes.first, entry.bytes.first)
            }
        }
    }

    func testReservedHoldsTrieTerminalIndex() throws {
        // Indirect check that the writer correctly stored each non-excluded token's
        // terminal node index: `prefixStart(t.bytes)` lands at a trie node whose
        // terminal id is `t`.
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for (i, entry) in built.entries.enumerated() {
            if entry.flags.contains(.excluded) { continue }
            if entry.bytes.isEmpty { continue }
            let tokenID = TokenID(i)
            guard let state = profile.prefixStart(requiredBytes: entry.bytes) else {
                return XCTFail("trie has no path for token id \(i) (\(entry.bytes))")
            }
            XCTAssertEqual(profile.terminalTokenID(at: state), tokenID, "token \(i) terminal mismatch")
        }
    }

    func testRoundTripFlags() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        for (i, entry) in built.entries.enumerated() {
            let tokenID = TokenID(i)
            let record = profile.record(for: tokenID)
            XCTAssertEqual(record?.flags, entry.flags, "flags drifted for token \(i)")
            XCTAssertEqual(record?.staticBias, entry.staticBias, "static bias drifted for token \(i)")
            XCTAssertEqual(record?.displayWidth, entry.displayWidth, "display width drifted for token \(i)")
        }
    }
}
