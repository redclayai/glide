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
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
        XCTAssertNotNil(body["max_tokens"], "max_tokens is required by the Messages API")
    }

    /// A credential in a query string ends up in logs and proxy history; it belongs in a header.
    func testGeminiKeyIsSentAsAHeaderNotInTheURL() throws {
        let request = try rewriter(backend: .gemini) { _ in httpOK("{}") }
            .buildRequest(sentence: "She dont know.", key: "AIza-secret")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-secret")
        XCTAssertFalse(request.url!.absoluteString.contains("AIza-secret"))
        XCTAssertTrue(request.url!.absoluteString.contains("gemini-2.5-flash:generateContent"))
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

    func testHTTPFailureProducesNoSuggestion() async {
        let suggestion = await rewriter(backend: .gemini) { _ in
            httpFailure(429, #"{"error":{"message":"quota"}}"#)
        }.suggestion(for: context("She dont know the answer yet. "))
        XCTAssertNil(suggestion)
    }
}
