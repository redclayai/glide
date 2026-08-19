import CryptoKit
import Foundation

/// Validates a freshly downloaded (or imported) GGUF before it is committed into the Models
/// directory. A partial or corrupt download must never replace a good model, so both checks run
/// against the staging file and any failure aborts the commit.
public enum ModelFileValidator {

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch(expected: String, actual: String)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .sizeMismatch(expected, actual):
                return "Downloaded file size \(actual) bytes did not match expected \(expected) bytes."
            case .checksumMismatch:
                return "Downloaded file failed its SHA-256 integrity check."
            case let .unreadable(message):
                return "Could not read the downloaded file: \(message)"
            }
        }
    }

    /// Throws when the file's byte size differs from `expectedBytes`. A `nil` expectation is a
    /// no-op (used for entries whose size has not been pinned yet).
    public static func validateSize(of url: URL, expectedBytes: Int64?) throws {
        guard let expectedBytes else { return }
        let actual = try fileSize(of: url)
        guard actual == expectedBytes else {
            throw ValidationError.sizeMismatch(expected: expectedBytes, actual: actual)
        }
    }

    /// Throws when the file's SHA-256 differs from `expectedSHA256` (case-insensitive hex). A `nil`
    /// expectation is a no-op.
    public static func validateSHA256(of url: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256, !expectedSHA256.isEmpty else { return }
        let actual = try sha256Hex(of: url)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ValidationError.checksumMismatch(expected: expectedSHA256.lowercased(), actual: actual)
        }
    }

    /// Streaming SHA-256 so multi-gigabyte GGUFs are never fully resident in memory.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ValidationError.unreadable(error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw ValidationError.unreadable(error.localizedDescription)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch {
            throw ValidationError.unreadable(error.localizedDescription)
        }
    }
}
