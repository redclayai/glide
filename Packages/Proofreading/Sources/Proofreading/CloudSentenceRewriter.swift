//
//  CloudSentenceRewriter.swift
//  Proofreading
//
//  The grammar pass, answered by a hosted model instead of the one on this Mac.
//
//  Deliberately the same shape as the local path: the same `TrailingSentenceScanner` decides when
//  there is a question worth asking, the same debounce means a typist who keeps going never triggers
//  a request, and the same `ModelRewriteGate` judges the answer. Only the engine changes. That
//  matters for more than tidiness — a frontier model produces *better prose* than the 2B local one,
//  and better prose is exactly what the gate exists to reject. Someone who paused mid-sentence asked
//  for their errors fixed, not for their voice replaced.
//
//  Two properties worth keeping in mind while reading this:
//
//    - It costs money per request, so the request is made as late and as rarely as possible: only at
//      a sentence boundary, only after a pause, only when the spelling pass had nothing to say.
//    - It sends the sentence off the machine. That is a real change in what the app is, so it is
//      opt-in, requires a key the user pasted themselves, and says so in Settings.
//

import AutocompleteCore
import Foundation

public struct CloudRewriteError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Main-actor isolated, like `ModelSentenceRewriter`: the settings it reads are, and the `await` on
/// the network call releases the actor for the duration of the request anyway.
@MainActor
public final class CloudSentenceRewriter: SentenceRewriting {
    /// Injected so tests can exercise request building and response parsing without a network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let backend: RewriteBackend
    /// Read per request, not captured: the model is editable in Settings and a change should take
    /// effect on the next keystroke rather than the next launch.
    private let model: () -> String
    private let apiKey: () -> String?
    private let isEnabled: () -> Bool
    private let transport: Transport
    private let debounceNanoseconds: UInt64
    private let unterminatedDebounceNanoseconds: UInt64
    /// Where failures go. Without it every error was swallowed by a `try?` and the feature simply
    /// produced nothing — which is precisely how a retired model name shipped unnoticed.
    private let log: ((String) -> Void)?
    /// Set after a 429. A free-tier key is rate limited per minute, and hammering it turns one
    /// exhausted quota into a permanently broken feature.
    private var cooldownUntil: Date?

    public init(
        backend: RewriteBackend,
        model: @escaping () -> String,
        apiKey: @escaping () -> String?,
        isEnabled: @escaping () -> Bool = { true },
        transport: Transport? = nil,
        debounceNanoseconds: UInt64 = 400_000_000,
        unterminatedDebounceNanoseconds: UInt64 = 1_100_000_000,
        log: ((String) -> Void)? = nil
    ) {
        self.backend = backend
        self.model = model
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.transport = transport ?? { try await URLSession.shared.data(for: $0) }
        self.debounceNanoseconds = debounceNanoseconds
        self.unterminatedDebounceNanoseconds = unterminatedDebounceNanoseconds
        self.log = log
    }

    public func suggestion(for context: TextFieldContext) async -> RewriteSuggestion? {
        guard isEnabled(), backend.sendsTextOffTheMachine else { return nil }
        guard !context.traits.isSecureTextEntry, !context.traits.isPasswordField else { return nil }
        guard let key = apiKey() else {
            log?("REWRITE cloud=\(backend.rawValue) → SUPPRESS(noKey)")
            return nil
        }
        if let cooldownUntil, Date() < cooldownUntil {
            log?("REWRITE cloud=\(backend.rawValue) → SUPPRESS(rateLimited, \(Int(cooldownUntil.timeIntervalSinceNow))s left)")
            return nil
        }
        guard let scanned = TrailingSentenceScanner.scan(beforeCursor: context.beforeCursor) else { return nil }
        let trailing = scanned.sentence

        let debounce = scanned.termination == .terminated
            ? debounceNanoseconds
            : unterminatedDebounceNanoseconds
        try? await Task.sleep(nanoseconds: debounce)
        guard !Task.isCancelled else { return nil }

        let raw: String
        do {
            raw = try await rewrite(trailing.sentence, key: key)
        } catch {
            // Reported, not swallowed. A wrong key, a renamed model and an exhausted quota are three
            // different problems that all present as "nothing happens".
            log?("REWRITE cloud=\(backend.rawValue) model=\(model()) → FAILED(\(error.localizedDescription))")
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let candidate = ModelRewriteGate.unwrap(raw)
        guard ModelRewriteGate.accepts(candidate: candidate, original: trailing.sentence) else {
            log?("REWRITE cloud=\(backend.rawValue) → SUPPRESS(gate) \"\(candidate)\"")
            return nil
        }

        return RewriteSuggestion(
            span: trailing.span,
            replacement: candidate + trailing.boundary,
            origin: .model
        )
    }

    /// Exposed so Settings can offer a "Test" button that reports the provider's actual error —
    /// a wrong key or a renamed model is otherwise indistinguishable from "the feature is broken".
    public func check() async throws -> String {
        guard let key = apiKey() else { throw CloudRewriteError("No API key saved.") }
        let result = try await rewrite("She dont know the answer yet.", key: key)
        let candidate = ModelRewriteGate.unwrap(result)
        guard !candidate.isEmpty else { throw CloudRewriteError("The model returned nothing.") }
        return candidate
    }

    // MARK: - Requests

    /// How long to stop asking after a 429. Long enough to clear a per-minute free-tier window
    /// without the user having to do anything.
    nonisolated static let rateLimitCooldown: TimeInterval = 75

    nonisolated static let instruction = """
    Fix only the grammar, spelling and punctuation of the sentence below. Keep the wording, meaning \
    and tone. Do not rephrase, do not improve the style, do not add or remove information. Reply \
    with the corrected sentence and nothing else.
    """

    func rewrite(_ sentence: String, key: String) async throws -> String {
        let request = try buildRequest(sentence: sentence, key: key)
        let (data, response) = try await transport(request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 429 {
                cooldownUntil = Date().addingTimeInterval(Self.rateLimitCooldown)
            }
            throw CloudRewriteError(Self.errorMessage(status: http.statusCode, body: data))
        }
        cooldownUntil = nil
        return try Self.parse(data, backend: backend)
    }

    func buildRequest(sentence: String, key: String) throws -> URLRequest {
        // Output is capped tightly: the reply is one corrected sentence, and a cap is the cheapest
        // protection against paying for a model that decides to explain itself.
        let maxTokens = min(400, max(64, sentence.count))

        switch backend {
        case .local:
            throw CloudRewriteError("The local backend does not make requests.")

        case .anthropic:
            guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                throw CloudRewriteError("Bad URL.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model(),
                "max_tokens": maxTokens,
                "system": Self.instruction,
                "messages": [["role": "user", "content": sentence]],
            ])
            return request

        case .gemini:
            // The key goes in a header, not the query string: a URL with a credential in it lands in
            // logs, crash reports and proxy history.
            guard let url = URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/\(model()):generateContent"
            ) else {
                throw CloudRewriteError("Bad URL — check the model name.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": Self.instruction]]],
                "contents": [["role": "user", "parts": [["text": sentence]]]],
                "generationConfig": ["maxOutputTokens": maxTokens, "temperature": 0],
            ])
            return request
        }
    }

    // MARK: - Responses

    nonisolated static func parse(_ data: Data, backend: RewriteBackend) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudRewriteError("The response was not JSON.")
        }

        switch backend {
        case .local:
            throw CloudRewriteError("The local backend does not make requests.")

        case .anthropic:
            // content is a list of blocks; take the text ones.
            let blocks = root["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw CloudRewriteError("No text in the response.") }
            return text

        case .gemini:
            let candidates = root["candidates"] as? [[String: Any]] ?? []
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else {
                // A blocked or truncated candidate carries a reason rather than text; surfacing it
                // is the difference between a fixable problem and a mystery.
                let reason = candidates.first?["finishReason"] as? String
                throw CloudRewriteError(reason.map { "No text returned (\($0))." } ?? "No text in the response.")
            }
            return text
        }
    }

    /// Providers put their message in different places; dig for it rather than showing a bare code.
    nonisolated static func errorMessage(status: Int, body: Data) -> String {
        let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let nested = root?["error"] as? [String: Any]
        let message = (nested?["message"] as? String)
            ?? (root?["message"] as? String)
            ?? String(data: body, encoding: .utf8)?.prefix(200).description

        let hint: String
        switch status {
        case 401, 403: hint = "Check the API key."
        case 404: hint = "Check the model name."
        case 429: hint = "Rate limited or out of quota."
        default: hint = ""
        }

        return [
            "HTTP \(status).",
            message?.isEmpty == false ? message : nil,
            hint.isEmpty ? nil : hint,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}
