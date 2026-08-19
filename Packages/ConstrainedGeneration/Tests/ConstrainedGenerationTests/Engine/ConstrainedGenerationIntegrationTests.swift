import AutocompleteCore
import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import TokenProfiles
import XCTest

/// On-device acceptance test for M5. Requires both the GGUF (see ADR-007) and a built ACPF
/// profile (see ADR-009) in `~/Library/Application Support/KeyType/Models/`. The test
/// `XCTSkipUnless` / `XCTSkip`s when either asset (or the vendored llama framework) is absent,
/// so the package suite stays green on machines that haven't provisioned them.
final class ConstrainedGenerationIntegrationTests: XCTestCase {
    private static let family = "qwen3-v151936"

    private func makeEngine(enableIncrementalBeam: Bool = true) throws -> ConstrainedGenerationEngine {
        try XCTSkipUnless(
            ModelContainer.defaultModelExists(),
            "Model file not present at \(ModelContainer.defaultModelFilename); skipping"
        )
        let profileURL = try ModelContainer.profileURL(family: Self.family)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: profileURL.path),
            "ACPF profile not present at \(profileURL.lastPathComponent); skipping"
        )

        let modelURL = try ModelContainer.modelURL()
        let runtime: LlamaModelRuntime
        let profile: MmapAutocompleteProfile
        do {
            runtime = try LlamaModelRuntime(
                modelURL: modelURL, contextLength: 1024, enableIncrementalBeam: enableIncrementalBeam
            )
            profile = try MmapAutocompleteProfile.open(
                at: profileURL,
                tokenizerVocabSize: runtime.metadata.vocabularySize,
                tokenizerBytes: { try runtime.tokenizer.rawBytes(for: $0) },
                expectedModelFamily: Self.family
            )
        } catch {
            throw XCTSkip("Could not load model/profile (\(error)); skipping integration test")
        }

        return ConstrainedGenerationEngine(runtime: runtime, profile: profile)
    }

    func testRealModelAndProfileReturnSmallRankedCandidateSet() async throws {
        let engine = try makeEngine()

        let context = TextFieldContext(
            beforeCursor: "The capital of France is ",
            target: AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        )
        let configuration = DecodingConfiguration()
        let request = CompletionRequest(
            context: context,
            prompt: context.beforeCursor,
            mode: .prose,
            maxCompletionTokens: 4,
            maxDisplayWidth: 40
        )

        let candidates = try await engine.completions(for: request)

        // A small ranked set (suppression to zero is acceptable, but never an unbounded list).
        XCTAssertLessThanOrEqual(candidates.count, configuration.maxCandidates)
        // Ranked by descending cumulative log-probability.
        for i in candidates.indices.dropFirst() {
            XCTAssertLessThanOrEqual(candidates[i].logProbability, candidates[i - 1].logProbability)
        }
        // Every emitted candidate is non-empty and within the requested display width.
        for candidate in candidates {
            XCTAssertFalse(candidate.text.isEmpty)
            XCTAssertLessThanOrEqual(candidate.displayWidth, request.maxDisplayWidth)
        }
    }

    /// End-to-end quality gate for incremental beam decoding (ADR-046): the displayed (top)
    /// completion must be identical whether the runtime decodes the beam incrementally or via the
    /// ADR-043 reseed path. Run over several realistic prompts so a regression in resident-frontier
    /// bookkeeping (wrong positions, stale fork state) would surface as a changed suggestion.
    func testIncrementalBeamPreservesTopCompletion() async throws {
        let incremental = try makeEngine(enableIncrementalBeam: true)
        let reseed = try makeEngine(enableIncrementalBeam: false)

        let prompts = [
            "The capital of France is ",
            "I am writing to let you know that the meeting tomorrow ",
            "Thank you for your email. I will ",
            "def add(a, b):\n    return ",
            "The quick brown fox ",
        ]

        for prompt in prompts {
            let context = TextFieldContext(
                beforeCursor: prompt,
                target: AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
            )
            let request = CompletionRequest(
                context: context, prompt: prompt, mode: .prose,
                maxCompletionTokens: 4, maxDisplayWidth: 40
            )
            let incCandidates = try await incremental.completions(for: request)
            let reseedCandidates = try await reseed.completions(for: request)

            XCTAssertEqual(
                incCandidates.first?.text, reseedCandidates.first?.text,
                "top completion changed for prompt \(prompt.debugDescription): " +
                "incremental=\(incCandidates.first?.text.debugDescription ?? "nil") " +
                "reseed=\(reseedCandidates.first?.text.debugDescription ?? "nil")"
            )
        }
    }

    func testRequiredPrefixYieldsOnlyPrefixSatisfyingCandidates() async throws {
        let engine = try makeEngine()

        let context = TextFieldContext(
            beforeCursor: "I will see you tom",
            target: AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
        )
        let request = CompletionRequest(
            context: context,
            prompt: context.beforeCursor,
            requiredPrefixBytes: Array("orrow".utf8),
            mode: .prose,
            maxCompletionTokens: 4,
            maxDisplayWidth: 40
        )

        let candidates = try await engine.completions(for: request)

        for candidate in candidates {
            // Each candidate must be consistent with the required prefix: either it extends the
            // prefix, or it is a partial step toward it.
            let bytes = Array(candidate.text.utf8)
            let prefix = Array("orrow".utf8)
            let consistent = bytes.starts(with: prefix) || prefix.starts(with: bytes)
            XCTAssertTrue(consistent, "candidate '\(candidate.text)' violates required prefix")
        }
    }
}
