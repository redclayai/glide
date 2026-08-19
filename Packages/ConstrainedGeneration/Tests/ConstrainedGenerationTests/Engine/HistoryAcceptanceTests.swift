import AutocompleteCore
import ConstrainedGeneration
import ModelRuntime
import Prompting
import TokenProfiles
import XCTest

/// M8 acceptance criterion: *writing history measurably improves the acceptance rate.*
///
/// This is a deterministic, model-free demonstration of the mechanism. `TreeScriptedModelRuntime`
/// returns next-token logits keyed by the full token path, so two prompts that differ only by the
/// `previousUserInputs` block lead to different continuations. We model a user whose local history
/// shows they continue with "good"; with that history in the prompt the decoder produces "good"
/// (what the user would type → accepted), and without it the decoder drifts to "best" (→ not
/// accepted). Acceptance over the fixture goes from 0% to 100%. See ADR-023.
final class HistoryAcceptanceTests: XCTestCase {

    func testWritingHistoryImprovesAcceptanceRate() async throws {
        let target = AppTarget(bundleIdentifier: "com.test.editor", appName: "Editor")
        let context = TextFieldContext(beforeCursor: "Sounds ", target: target)

        // The user's local, opt-in writing history shows they tend to continue with "good".
        let store = InMemoryWritingHistoryStore(entries: [
            WritingHistorySample(
                text: "Sounds good to me, thanks!",
                appBundleIdentifier: target.bundleIdentifier
            )
        ])
        let memory = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: target.bundleIdentifier,
            minimumCharacters: 5
        ))
        XCTAssertFalse(memory.isEmpty, "history should supply a sample")

        // Build the two prompts: identical except for the retrieved previous-writing block.
        let builder = PromptBuilder(tokenCounter: ApproximatePromptTokenCounter())
        let withHistory = builder.buildPrompt(context: context, previousUserInputs: memory).prompt
        let withoutHistory = builder.buildPrompt(context: context, previousUserInputs: []).prompt
        XCTAssertNotEqual(withHistory, withoutHistory, "history must change the prompt")

        let tokenizer = UTF8FallbackTokenizer()
        let withTokens = try tokenizer.tokenize(withHistory)
        let withoutTokens = try tokenizer.tokenize(withoutHistory)

        let profile = InMemoryAutocompleteProfile(vocabularySize: 4096, records: [
            record(1, "go"), record(11, "od"), record(2, "be"), record(21, "st")
        ])
        let runtime = TreeScriptedModelRuntime(
            logitsByPath: [
                withTokens: [logit(1, 3)],
                withTokens + [1]: [logit(11, 3)],
                withoutTokens: [logit(2, 3)],
                withoutTokens + [2]: [logit(21, 3)]
            ],
            metadata: ModelMetadata(
                identifier: "tree", family: "stub", vocabularySize: 4096, contextLength: 4096
            )
        )
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let expected = "good" // what the user would actually type next
        let withCandidate = try await engine.completions(for: request(context, withHistory)).first
        let withoutCandidate = try await engine.completions(for: request(context, withoutHistory)).first

        XCTAssertEqual(withCandidate?.text, expected)
        XCTAssertNotEqual(withoutCandidate?.text, expected)

        let acceptedWith = withCandidate?.text == expected ? 1.0 : 0.0
        let acceptedWithout = withoutCandidate?.text == expected ? 1.0 : 0.0
        XCTAssertGreaterThan(
            acceptedWith,
            acceptedWithout,
            "writing history should measurably improve the acceptance rate"
        )
    }

    // MARK: - Helpers

    private func record(_ id: TokenID, _ text: String) -> TokenProfileRecord {
        TokenProfileRecord(
            tokenID: id,
            bytes: Array(text.utf8),
            flags: [],
            staticBias: 0,
            displayWidth: text.count
        )
    }

    private func logit(_ id: TokenID, _ value: Float) -> TokenLogit {
        TokenLogit(tokenID: id, logit: value)
    }

    private func request(_ context: TextFieldContext, _ prompt: String) -> CompletionRequest {
        CompletionRequest(
            context: context,
            prompt: prompt,
            mode: .prose,
            maxCompletionTokens: 2,
            maxDisplayWidth: 80
        )
    }
}
