import AutocompleteCore
import XCTest
@testable import Proofreading

/// Response builders live outside the test class: the transport closure is `@Sendable`, so its body
/// cannot call a main-actor-isolated helper.
private func httpOK(_ json: String) -> (Data, URLResponse) {
    (
        Data(json.utf8),
        HTTPURLResponse(url: URL(string: "https://example.org")!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!
    )
}

private func httpFailure(_ status: Int, _ json: String) -> (Data, URLResponse) {
    (
        Data(json.utf8),
        HTTPURLResponse(url: URL(string: "https://example.org")!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    )
}

@MainActor
final class CloudSentenceRewriterTests: XCTestCase {
    private func rewriter(
        backend: RewriteBackend,
        model: String? = nil,
        key: String? = "test-key",
        respond: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) -> CloudSentenceRewriter {
        CloudSentenceRewriter(
            backend: backend,
            model: { model ?? backend.defaultModel },
            apiKey: { key },
            transport: respond,
            debounceNanoseconds: 0,
            unterminatedDebounceNanoseconds: 0
        )
    }

    // MARK: - Request shape

    func testAnthropicRequestCarriesKeyAndVersionHeaders() throws {
        let request = try rewriter(backend: .anthropic) { _ in httpOK("{}") }
            .buildRequest(sentence: "She dont know.", key: "sk-test")

        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, RewriteBackend.anthropic.defaultModel)
        XCTAssertNotNil(body["max_tokens"], "max_tokens is required by the Messages API")
    }

    /// A credential in a query string ends up in logs and proxy history; it belongs in a header.
    func testGeminiKeyIsSentAsAHeaderNotInTheURL() throws {
        let request = try rewriter(backend: .gemini) { _ in httpOK("{}") }
            .buildRequest(sentence: "She dont know.", key: "AIza-secret")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("AIza-secret"))
        // Asserted against the constant, not a literal: a hardcoded model name here rots exactly
        // the way the shipped default did.
        XCTAssertTrue(
            request.url!.absoluteString.contains("\(RewriteBackend.gemini.defaultModel):generateContent")
        )
    }

    func testLocalBackendRefusesToBuildARequest() {
        XCTAssertThrowsError(
            try rewriter(backend: .local) { _ in httpOK("{}") }
                .buildRequest(sentence: "x", key: "k")
        )
    }

    // MARK: - Response parsing

    func testParsesAnthropicContentBlocks() throws {
        let json = """
        {"content":[{"type":"text","text":"She doesn't know the answer yet."}]}
        """
        XCTAssertEqual(
            try CloudSentenceRewriter.parse(Data(json.utf8), backend: .anthropic),
            "She doesn't know the answer yet."
        )
    }

    func testParsesGeminiCandidates() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"She doesn't know the answer yet."}]}}]}
        """
        XCTAssertEqual(
            try CloudSentenceRewriter.parse(Data(json.utf8), backend: .gemini),
            "She doesn't know the answer yet."
        )
    }

    /// A blocked or truncated Gemini candidate has no text but does carry a reason. Surfacing it is
    /// the difference between a fixable problem and a mystery.
    func testGeminiFinishReasonSurfacesWhenThereIsNoText() {
        let json = #"{"candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}"#
        XCTAssertThrowsError(try CloudSentenceRewriter.parse(Data(json.utf8), backend: .gemini)) { error in
            XCTAssertTrue("\(error)".contains("SAFETY"))
        }
    }

    func testNonJSONResponseFails() {
        XCTAssertThrowsError(try CloudSentenceRewriter.parse(Data("<html>".utf8), backend: .anthropic))
    }

    // MARK: - Errors

    func testErrorMessageIncludesTheProviderTextAndAHint() {
        let body = Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)
        let message = CloudSentenceRewriter.errorMessage(status: 401, body: body)
        XCTAssertTrue(message.contains("401"))
        XCTAssertTrue(message.contains("invalid x-api-key"))
        XCTAssertTrue(message.contains("Check the API key."))
    }

    func testModelNameHintOn404() {
        let message = CloudSentenceRewriter.errorMessage(status: 404, body: Data("{}".utf8))
        XCTAssertTrue(message.contains("Check the model name."))
    }

    // MARK: - End to end through the gate

    private func context(_ text: String) -> TextFieldContext {
        TextFieldContext(
            beforeCursor: text,
            target: AppTarget(bundleIdentifier: "com.test", appName: "Test")
        )
    }

    func testAcceptedCorrectionBecomesASuggestion() async {
        let json = """
        {"content":[{"type":"text","text":"She doesn't know the answer yet."}]}
        """
        let suggestion = await rewriter(backend: .anthropic) { _ in httpOK(json) }
            .suggestion(for: context("She dont know the answer yet. "))

        XCTAssertEqual(suggestion?.replacement, "She doesn't know the answer yet. ")
        XCTAssertEqual(suggestion?.origin, .model)
    }

    /// The gate applies to a hosted model exactly as it does to the local one — a frontier model is
    /// *more* likely to produce good prose, which is the thing being rejected.
    func testRephrasingIsStillRejected() async {
        let json = """
        {"content":[{"type":"text","text":"Regrettably, she remains unaware of the outcome."}]}
        """
        let suggestion = await rewriter(backend: .anthropic) { _ in httpOK(json) }
            .suggestion(for: context("She dont know the answer yet. "))
        XCTAssertNil(suggestion)
    }

    func testNoKeyMeansNoRequest() async {
        var called = false
        let rewriter = CloudSentenceRewriter(
            backend: .anthropic, model: { "claude-haiku-4-5" }, apiKey: { nil },
            transport: { _ in called = true; return httpOK("{}") },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0
        )
        let suggestion = await rewriter.suggestion(for: context("She dont know the answer yet. "))
        XCTAssertNil(suggestion)
        XCTAssertFalse(called, "a request that cannot succeed must not be sent")
    }

    func testSecureFieldsAreNeverSentAnywhere() async {
        var called = false
        let rewriter = CloudSentenceRewriter(
            backend: .anthropic, model: { "claude-haiku-4-5" }, apiKey: { "k" },
            transport: { _ in called = true; return httpOK("{}") },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0
        )
        let secure = TextFieldContext(
            beforeCursor: "She dont know the answer yet. ",
            target: AppTarget(bundleIdentifier: "com.test", appName: "Test"),
            traits: TextFieldTraits(isSecureTextEntry: true)
        )
        _ = await rewriter.suggestion(for: secure)
        XCTAssertFalse(called, "password fields must never leave the machine")
    }

    /// A free-tier key is rate limited per minute. Without a cooldown, one exhausted quota turns
    /// into a feature that hammers the endpoint and never recovers.
    func testRateLimitStopsFurtherRequestsForACooldown() async {
        var requests = 0
        let rewriter = CloudSentenceRewriter(
            backend: .gemini, model: { RewriteBackend.gemini.defaultModel }, apiKey: { "k" },
            transport: { _ in
                requests += 1
                return httpFailure(429, #"{"error":{"message":"quota"}}"#)
            },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0
        )

        _ = await rewriter.suggestion(for: context("She dont know the answer yet. "))
        XCTAssertEqual(requests, 1)

        _ = await rewriter.suggestion(for: context("He dont agree with it at all. "))
        XCTAssertEqual(requests, 1, "the second attempt must be suppressed by the cooldown")
    }

    func testFailuresAreReportedRatherThanSwallowed() async {
        var lines: [String] = []
        let rewriter = CloudSentenceRewriter(
            backend: .gemini, model: { "retired-model" }, apiKey: { "k" },
            transport: { _ in httpFailure(404, #"{"error":{"message":"model not found"}}"#) },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0,
            log: { lines.append($0) }
        )
        _ = await rewriter.suggestion(for: context("She dont know the answer yet. "))

        XCTAssertTrue(lines.contains { $0.contains("FAILED") && $0.contains("model not found") },
                      "a silent failure is how a retired model name shipped unnoticed")
    }

    func testHTTPFailureProducesNoSuggestion() async {
        let suggestion = await rewriter(backend: .gemini) { _ in
            httpFailure(429, #"{"error":{"message":"quota"}}"#)
        }.suggestion(for: context("She dont know the answer yet. "))
        XCTAssertNil(suggestion)
    }
}

// MARK: - Rate-limit handling

@MainActor
final class CloudRateLimitTests: XCTestCase {
    /// The real body Gemini returns, trimmed. It says when to retry and which bucket it counted
    /// against; both are more useful than a fixed guess.
    private static let geminiQuotaBody = Data("""
    {"error":{"code":429,"message":"You exceeded your current quota. \
    * Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, \
    limit: 20, model: gemini-3.6-flash\\nPlease retry in 41.114340752s.","status":"RESOURCE_EXHAUSTED"}}
    """.utf8)

    func testReadsTheProvidersRetryDelay() {
        let delay = CloudSentenceRewriter.retryDelay(in: Self.geminiQuotaBody)
        XCTAssertNotNil(delay)
        XCTAssertEqual(delay ?? 0, 41.11, accuracy: 0.5)
    }

    func testReadsARetryDelayFromStructuredDetails() {
        let body = Data(#"{"error":{"details":[{"@type":"...RetryInfo","retryDelay":"7s"}]}}"#.utf8)
        XCTAssertEqual(CloudSentenceRewriter.retryDelay(in: body) ?? 0, 7, accuracy: 0.01)
    }

    func testNoDelayWhenTheProviderDoesNotSay() {
        XCTAssertNil(CloudSentenceRewriter.retryDelay(in: Data(#"{"error":{"code":429}}"#.utf8)))
    }

    func testExtractsTheQuotaMetric() {
        XCTAssertEqual(
            CloudSentenceRewriter.quotaMetric(in: Self.geminiQuotaBody),
            "generativelanguage.googleapis.com/generate_content_free_tier_requests"
        )
    }

    /// The distinction that matters: a free-tier bucket means billing is not enabled on the key,
    /// which no amount of waiting fixes.
    func testFreeTierQuotaProducesABillingHint() {
        let message = CloudSentenceRewriter.errorMessage(status: 429, body: Self.geminiQuotaBody)
        XCTAssertTrue(message.contains("free tier"))
        XCTAssertTrue(message.contains("billing"))
    }

    func testUnattributedQuotaKeepsTheGenericHint() {
        let message = CloudSentenceRewriter.errorMessage(
            status: 429, body: Data(#"{"error":{"message":"slow down"}}"#.utf8)
        )
        XCTAssertTrue(message.contains("Rate limited"))
        XCTAssertFalse(message.contains("billing"))
    }
}

// MARK: - Styles

/// The whole distinction between the two selection actions lives in these instructions, so crossing
/// them would silently turn "fix my errors" into "rewrite my sentence".
@MainActor
final class CloudRewriteStyleTests: XCTestCase {
    private func rewriter(_ backend: RewriteBackend) -> CloudSentenceRewriter {
        CloudSentenceRewriter(
            backend: backend, model: { backend.defaultModel }, apiKey: { "k" },
            transport: { _ in httpOK("{}") },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0
        )
    }

    func testGrammarForbidsRephrasing() {
        let instruction = CloudRewriteStyle.grammar.instruction.lowercased()
        XCTAssertTrue(instruction.contains("do not rephrase"))
        XCTAssertTrue(instruction.contains("keep the wording"))
    }

    func testPolishAsksForRephrasingButNotEmbellishment() {
        let instruction = CloudRewriteStyle.polish.instruction.lowercased()
        XCTAssertTrue(instruction.contains("rewrite"))
        XCTAssertTrue(instruction.contains("do not add information"))
        XCTAssertFalse(instruction.contains("do not rephrase"), "that is the grammar instruction")
    }

    func testTheTwoStylesAreNotTheSameInstruction() {
        XCTAssertNotEqual(CloudRewriteStyle.grammar.instruction, CloudRewriteStyle.polish.instruction)
    }

    func testStyleReachesTheAnthropicSystemPrompt() throws {
        let request = try rewriter(.anthropic)
            .buildRequest(sentence: "Some text.", key: "k", style: .polish)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["system"] as? String, CloudRewriteStyle.polish.instruction)
    }

    func testStyleReachesTheGeminiSystemInstruction() throws {
        let request = try rewriter(.gemini)
            .buildRequest(sentence: "Some text.", key: "k", style: .grammar)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let system = body["systemInstruction"] as? [String: Any]
        let parts = system?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, CloudRewriteStyle.grammar.instruction)
    }

    /// The inline pass must keep asking for grammar — it is the one place the gate rejects rephrasing.
    func testInlinePathStillDefaultsToGrammar() throws {
        let request = try rewriter(.anthropic).buildRequest(sentence: "Some text.", key: "k")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["system"] as? String, CloudRewriteStyle.grammar.instruction)
    }

    /// A polish may legitimately restructure a paragraph; the cap must not truncate it.
    func testOutputCapAllowsForARewriteBeingLonger() throws {
        let text = String(repeating: "word ", count: 40)
        let request = try rewriter(.anthropic).buildRequest(sentence: text, key: "k", style: .polish)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertGreaterThan(body["max_tokens"] as? Int ?? 0, text.count)
    }

    func testSelectionRewriteFailsLoudlyWithoutAKey() async {
        let rewriter = CloudSentenceRewriter(
            backend: .gemini, model: { "m" }, apiKey: { nil },
            transport: { _ in httpOK("{}") },
            debounceNanoseconds: 0, unterminatedDebounceNanoseconds: 0
        )
        do {
            _ = try await rewriter.rewriteSelection("text", style: .polish)
            XCTFail("expected a thrown error — the user is watching a spinner")
        } catch {
            XCTAssertTrue("\(error)".contains("No API key"))
        }
    }
}
