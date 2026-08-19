import CryptoKit
import XCTest
@testable import ModelManagement

final class ModelFileValidatorTests: XCTestCase {

    private func makeTempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    func testValidateSizeMatches() throws {
        let url = try makeTempFile([1, 2, 3, 4, 5])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try ModelFileValidator.validateSize(of: url, expectedBytes: 5))
    }

    func testValidateSizeMismatchThrows() throws {
        let url = try makeTempFile([1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ModelFileValidator.validateSize(of: url, expectedBytes: 99)) { error in
            guard case ModelFileValidator.ValidationError.sizeMismatch(let expected, let actual) = error else {
                return XCTFail("Expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 99)
            XCTAssertEqual(actual, 3)
        }
    }

    func testValidateSizeNilExpectationIsNoOp() throws {
        let url = try makeTempFile([1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try ModelFileValidator.validateSize(of: url, expectedBytes: nil))
    }

    func testSHA256MatchesReference() throws {
        let bytes: [UInt8] = Array("keytype".utf8)
        let url = try makeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ModelFileValidator.sha256Hex(of: url), expected)
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: expected.uppercased()))
    }

    func testSHA256MismatchThrows() throws {
        let url = try makeTempFile(Array("keytype".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: String(repeating: "0", count: 64)))
    }

    func testSHA256NilOrEmptyExpectationIsNoOp() throws {
        let url = try makeTempFile(Array("keytype".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: nil))
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: ""))
    }
}
