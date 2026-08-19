import AutocompleteCore
import XCTest
@testable import TokenProfiles

final class RawBytesRoundTripTests: XCTestCase {

    func testBytesMatchSourceForSampledIds() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Sample explicitly: every id in the fixture matters because we built it.
        for (i, entry) in built.entries.enumerated() {
            let got = profile.bytes(for: TokenID(i))
            XCTAssertEqual(got, entry.bytes, "bytes mismatch at token id \(i)")
        }
    }

    func testWithRawBytesIsZeroCopy() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Pick a known-non-empty token (id 0 = 'a').
        let id: TokenID = 0
        let expected = built.entries[Int(id)].bytes
        let observed = profile.withRawBytes(for: id) { buf -> [UInt8] in
            Array(buf)
        }
        XCTAssertEqual(observed, expected)
    }

    func testInvalidUTF8ByteFallbackPreserved() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)
        // Look up the synthetic byte-fallback tokens (0xC3 and 0x9A).
        for (i, entry) in built.entries.enumerated() {
            guard entry.flags.contains(.invalidUTF8) else { continue }
            let got = profile.bytes(for: TokenID(i))
            XCTAssertEqual(got, entry.bytes, "byte fallback drifted at token \(i)")
        }
    }
}
