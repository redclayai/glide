import AutocompleteCore
import Foundation
import LlamaModelRuntime
import ModelRuntime
import ProfileBuilderCore
import TokenProfiles
import XCTest

/// Integration tests for the offline builder against the local Qwen GGUF. Gated by
/// `ModelContainer.defaultModelExists()` so a CI environment without the model file
/// can still pass.
final class QwenProfileBuilderTests: XCTestCase {

    private static let testFamily = "qwen3-v151936-test"

    private func skipIfModelMissing() throws {
        try XCTSkipUnless(ModelContainer.defaultModelExists(),
                          "Default Qwen GGUF not present at \(try? ModelContainer.modelURL().path ?? "?")")
    }

    private func tempOutputURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acpf-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Self.testFamily)-\(UUID().uuidString).acpf.bin")
        return url
    }

    /// Builds the Qwen profile end-to-end and verifies the file is non-empty + the
    /// self-check passes.
    func testBuildsQwenProfile() throws {
        try skipIfModelMissing()
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 256, reuseThreshold: 0)
        let introspector = runtime.makeIntrospector()
        let output = try tempOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }
        let summary = try BuildProfile.run(
            introspector: introspector,
            family: Self.testFamily,
            output: output,
            reporter: ConsoleReporter(isQuiet: true)
        )
        XCTAssertGreaterThan(summary.fileSize, 0)
        XCTAssertEqual(summary.vocabSize, introspector.vocabSize)
        XCTAssertGreaterThan(summary.trieNodeCount, 1) // at least root + one child.
        XCTAssertFalse(summary.tokenizerDigestHexPrefix.isEmpty)
    }

    /// Confirms the round-trip: every sampled token's raw bytes from the on-disk profile
    /// equal what `LlamaTokenizer.rawBytes` reports for the same id.
    func testMmapReaderRoundTrip() throws {
        try skipIfModelMissing()
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 256, reuseThreshold: 0)
        let introspector = runtime.makeIntrospector()
        let output = try tempOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try BuildProfile.run(
            introspector: introspector,
            family: Self.testFamily,
            output: output,
            reporter: ConsoleReporter(isQuiet: true)
        )
        let profile = try MmapAutocompleteProfile.open(
            at: output,
            expectedVocabSize: introspector.vocabSize,
            expectedModelFamily: Self.testFamily
        )
        let n = profile.vocabularySize
        let step = max(1, n / 1000)
        for id in stride(from: 0, to: n, by: step) {
            let tokenID = TokenID(id)
            let want = try introspector.bytes(for: tokenID)
            let got = profile.bytes(for: tokenID)
            XCTAssertEqual(want, got, "token \(id) bytes drift")
        }
    }

    /// Special tokens reported by the llama API (EOS/EOT/BOS/PAD) get the right
    /// classifier flags in the on-disk profile.
    func testSpecialIdsFlaggedAsExpected() throws {
        try skipIfModelMissing()
        let runtime = try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 256, reuseThreshold: 0)
        let introspector = runtime.makeIntrospector()
        let output = try tempOutputURL()
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try BuildProfile.run(
            introspector: introspector,
            family: Self.testFamily,
            output: output,
            reporter: ConsoleReporter(isQuiet: true)
        )
        let profile = try MmapAutocompleteProfile.open(
            at: output,
            expectedVocabSize: introspector.vocabSize,
            expectedModelFamily: Self.testFamily
        )
        // Find each known role and assert the spec-driven flags hold.
        for id in 0..<introspector.vocabSize {
            let tokenID = TokenID(id)
            guard let role = introspector.role(of: tokenID) else { continue }
            guard let record = profile.record(for: tokenID) else { continue }
            switch role {
            case .bos, .pad, .unk, .sep, .nl:
                XCTAssertTrue(record.flags.contains(.excluded), "role \(role) (id \(id)) must be excluded")
            case .eos, .eot:
                XCTAssertTrue(record.flags.contains(.stop), "role \(role) (id \(id)) must be stop")
            }
        }
    }
}
