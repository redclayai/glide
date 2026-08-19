import AutocompleteCore
import XCTest
@testable import TokenProfiles

final class ACPFHeaderValidationTests: XCTestCase {

    func testAcceptsHappyPath() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let profile = try MmapAutocompleteProfile(data: data, expectedVocabSize: built.vocabSize, expectedModelFamily: built.modelFamily, expectedTokenizerDigest: built.digest)
        XCTAssertEqual(profile.vocabularySize, built.vocabSize)
        XCTAssertEqual(profile.modelFamily, built.modelFamily)
        XCTAssertEqual(profile.tokenizerDigest, built.digest)
    }

    func testRejectsWrongMagic() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        var corrupted = data
        corrupted[0] = 0x42 // flip 'A' to 'B'
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: corrupted)) { err in
            guard case ACPFOpenError.badMagic = err else {
                return XCTFail("expected .badMagic, got \(err)")
            }
        }
    }

    func testRejectsWrongEndianSentinel() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        var corrupted = data
        // endian field is at offset 6 (after magic[4] + version[2]). Write 0x0201 LE.
        corrupted[6] = 0x01
        corrupted[7] = 0x02
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: corrupted)) { err in
            guard case ACPFOpenError.endianMismatch = err else {
                return XCTFail("expected .endianMismatch, got \(err)")
            }
        }
    }

    func testRejectsWrongSchemaVersion() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        var corrupted = data
        // version is at offset 4 as UInt16 LE.
        corrupted[4] = 0xFF
        corrupted[5] = 0xFF
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: corrupted)) { err in
            guard case ACPFOpenError.unsupportedVersion = err else {
                return XCTFail("expected .unsupportedVersion, got \(err)")
            }
        }
    }

    func testRejectsVocabSizeMismatch() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        XCTAssertThrowsError(
            try MmapAutocompleteProfile(data: data, expectedVocabSize: built.vocabSize + 1)
        ) { err in
            guard case ACPFOpenError.vocabSizeMismatch = err else {
                return XCTFail("expected .vocabSizeMismatch, got \(err)")
            }
        }
    }

    func testRejectsTokenizerDigestMismatch() throws {
        let (built, data) = try SyntheticVocabFixture.buildAndEncode()
        let wrong = ACPFTokenizerDigestValue(lo: built.digest.lo &+ 1, hi: built.digest.hi)
        XCTAssertThrowsError(
            try MmapAutocompleteProfile(data: data, expectedTokenizerDigest: wrong)
        ) { err in
            guard case ACPFOpenError.tokenizerDigestMismatch = err else {
                return XCTFail("expected .tokenizerDigestMismatch, got \(err)")
            }
        }
    }

    func testRejectsModelFamilyMismatch() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        XCTAssertThrowsError(
            try MmapAutocompleteProfile(data: data, expectedModelFamily: "definitely-not-the-family")
        ) { err in
            guard case ACPFOpenError.modelFamilyMismatch = err else {
                return XCTFail("expected .modelFamilyMismatch, got \(err)")
            }
        }
    }

    func testRejectsSectionOutOfBounds() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        var corrupted = data
        // Corrupt TOKEN_TABLE (section 0) length to a value that overflows the file.
        // The section descriptor lives at offset 48 in the header; `length` is at +8 (UInt64 LE).
        let sectionDescriptorOffset = 48
        let lengthOffset = sectionDescriptorOffset + 8
        var bigLen = UInt64(data.count + 1).littleEndian
        Swift.withUnsafeBytes(of: &bigLen) { buf in
            for (i, b) in buf.enumerated() { corrupted[lengthOffset + i] = b }
        }
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: corrupted)) { err in
            guard case ACPFOpenError.sectionOutOfBounds = err else {
                return XCTFail("expected .sectionOutOfBounds, got \(err)")
            }
        }
    }

    func testRejectsUnalignedSection() throws {
        let (_, data) = try SyntheticVocabFixture.buildAndEncode()
        var corrupted = data
        // TOKEN_TABLE descriptor's offset field is the first 8 bytes of its 24-byte block,
        // sitting at offset 48 in the header.
        let sectionDescriptorOffset = 48
        var unaligned = UInt64(65).littleEndian // not multiple of 64
        Swift.withUnsafeBytes(of: &unaligned) { buf in
            for (i, b) in buf.enumerated() { corrupted[sectionDescriptorOffset + i] = b }
        }
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: corrupted)) { err in
            guard case ACPFOpenError.sectionMisaligned = err else {
                return XCTFail("expected .sectionMisaligned, got \(err)")
            }
        }
    }

    func testFileTooSmall() throws {
        let tiny = Data([0x41, 0x43, 0x50, 0x46]) // just the magic, nothing else
        XCTAssertThrowsError(try MmapAutocompleteProfile(data: tiny)) { err in
            guard case ACPFOpenError.fileTooSmall = err else {
                return XCTFail("expected .fileTooSmall, got \(err)")
            }
        }
    }
}
