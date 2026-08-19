import AutocompleteCore
import XCTest
@testable import TokenProfiles

final class SpecialListsTests: XCTestCase {

    func testKnownSpecialsExcludedOrStopOnly() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)

        for (i, entry) in built.entries.enumerated() {
            // BOS/PAD/UNK and chat markers must be excluded.
            if entry.flags.contains(.chatMarker) {
                XCTAssertTrue(entry.flags.contains(.excluded),
                              "chat marker token \(i) must be excluded")
                XCTAssertTrue(profile.isExcluded(TokenID(i), mode: .prose),
                              "chat marker token \(i) must be runtime-excluded")
            }
            // BOS/PAD/UNK roles get excluded by classifier.
            let probe = built.probeByID[TokenID(i)]!
            if probe.role == .bos || probe.role == .pad || probe.role == .unk {
                XCTAssertTrue(entry.flags.contains(.excluded),
                              "token \(i) with role \(probe.role!) must be excluded")
            }
            // EOS/EOT get STOP flag and never appear directly as displayable candidates.
            if probe.role == .eos || probe.role == .eot || probe.isEOG {
                XCTAssertTrue(entry.flags.contains(.stop),
                              "token \(i) with EOG role/flag must have .stop")
                XCTAssertEqual(profile.stopBehavior(for: TokenID(i)), .stopAndSuppress,
                               "stop token \(i) must suppress, not display")
            }
        }
    }

    func testSpecialListsAreSortedAndComplete() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data)

        for list in SpecialList.allCases {
            let slice = profile.tokens(in: list)
            // Sorted strictly ascending.
            var prev: TokenID = -1
            for i in 0..<slice.count {
                let id = slice[i]
                XCTAssertGreaterThan(id, prev, "list \(list) not strictly sorted at \(i)")
                prev = id
            }
            // Cross-check with the entries' flag membership for that list.
            let expectedIDs: [TokenID] = built.entries.compactMap { entry in
                let f = entry.flags
                let inList: Bool
                switch list {
                case .excluded: inList = f.contains(.excluded)
                case .stop: inList = f.contains(.stop)
                case .newline: inList = f.contains(.newline)
                case .whitespace: inList = f.contains(.whitespace)
                case .sentenceEnd: inList = f.contains(.sentenceEnd)
                case .emoji: inList = f.contains(.emoji)
                case .chatMarker: inList = f.contains(.chatMarker)
                }
                return inList ? entry.tokenID : nil
            }.sorted()
            let observed = (0..<slice.count).map { slice[$0] }
            XCTAssertEqual(observed, expectedIDs, "list \(list) mismatch")
        }
    }
}
