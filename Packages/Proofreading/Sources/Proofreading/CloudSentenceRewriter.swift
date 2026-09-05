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

/// What the caller is asking for. The distinction is whether the writer's wording may change:
/// `grammar` repairs, `polish` rephrases. Keeping both in one place means the on-device path and the
/// hosted path ask for the same thing in the same words.
/// An instruction plus, optionally, worked examples.
///
/// The examples exist for base models. Measured against the shipped `Qwen3.5-2B-Base`, a ChatML
/// instruction to shorten or change register returned the input verbatim every time, where three
/// worked examples produced a correct rewrite. A chat model needs only the instruction, so the cloud
/// path ignores `examples` entirely.
public struct RewriteInstruction: Sendable, Equatable, Codable {
    public var instruction: String
    /// `(original, rewritten)` pairs, plus the short header that introduces them.
    public var fewShotHeader: String?
    public var examples: [RewriteExample]

    public init(instruction: String, fewShotHeader: String? = nil, examples: [RewriteExample] = []) {
        self.instruction = instruction
        self.fewShotHeader = fewShotHeader
        self.examples = examples
    }

    public var hasExamples: Bool { !examples.isEmpty && fewShotHeader != nil }
}

public struct RewriteExample: Sendable, Equatable, Codable {
    public var original: String
    public var rewritten: String

    public init(original: String, rewritten: String) {
        self.original = original
        self.rewritten = rewritten
    }
}

/// `Equatable` is declared rather than synthesized — an enum loses the free conformance as soon as
/// one case carries an associated value.
public enum CloudRewriteStyle: Sendable, Equatable {
    case grammar
    case polish
    /// An arbitrary instruction, optionally with worked examples for an engine that cannot follow
    /// one. Every prompt-kind selection action arrives this way, so provider plumbing, retry handling
    /// and rate-limit reporting are shared with the two built-in styles rather than duplicated per
    /// action. A cloud model ignores the examples — it does not need them.
    case custom(RewriteInstruction)

    var instruction: String {
        switch self {
        case .grammar:
            return """
            Fix only the grammar, spelling and punctuation of the text below. Keep the wording, \
            meaning and tone. Do not rephrase, do not improve the style, do not add or remove \
            information. Reply with the corrected text and nothing else.
            """
        case .polish:
            return """
            Rewrite the text below to be clearer and better written, keeping the original meaning \
            and a natural tone in the author's voice. Do not add information, do not change what is \
            being claimed, and do not make it longer. Reply with the rewritten text and nothing else.
            """
        case let .custom(spec):
            return spec.instruction
        }
    }
}

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
        debounceNanoseconds: UInt64 = 150_000_000,
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

    /// Rewrite text the user selected deliberately.
    ///
    /// No sentence scan, no debounce and no `ModelRewriteGate`, and all three omissions are correct
    /// here: the selection *is* the text, the user already asked, and for a polish, rephrasing is
    /// the entire point — the thing the gate exists to reject on the inline path. Errors surface to
    /// the caller rather than being swallowed, because the user is watching a spinner.
    public func rewriteSelection(_ text: String, style: CloudRewriteStyle) async throws -> String {
        guard let key = apiKey() else { throw CloudRewriteError("No API key saved for \(backend.title).") }
        if let cooldownUntil, Date() < cooldownUntil {
            throw CloudRewriteError("Rate limited — try again in \(Int(cooldownUntil.timeIntervalSinceNow))s.")
        }
        let raw = try await rewrite(text, key: key, style: style)
        let candidate = ModelRewriteGate.unwrap(raw)
        guard !candidate.isEmpty else { throw CloudRewriteError("The model returned nothing.") }
        return candidate
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

    /// Fallback cooldown after a 429 when the provider does not say when to retry. Providers usually
    /// do say, and `retryDelay(in:)` prefers their answer — a blanket wait sits out quota the user
    /// has already got back.
    nonisolated static let rateLimitCooldown: TimeInterval = 60

    /// Longest we will sit out on a provider's say-so, in case one reports something absurd.
    nonisolated static let maximumCooldown: TimeInterval = 15 * 60

    /// Pull the retry delay out of a 429 body. Gemini reports a `retryDelay` in its error details and
    /// also says "Please retry in 41.1s" in the message; Anthropic uses a `retry-after` header,
    /// which the caller checks first.
    nonisolated static func retryDelay(in body: Data) -> TimeInterval? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        for pattern in [#"retryDelay\D+([0-9.]+)s"#, #"retry in ([0-9.]+)s"#] {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let digits = text[range].filter { $0.isNumber || $0 == "." }
            if let seconds = Double(digits), seconds > 0 { return seconds }
        }
        return nil
    }

    /// The quota bucket the provider counted the request against, when it says so. Surfaced because
    /// "free_tier" in this string is the difference between "rate limited, wait a moment" and
    /// "billing is not enabled on this key" — which need completely different fixes.
    nonisolated static func quotaMetric(in body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8),
              let range = text.range(of: #"metric: [a-zA-Z0-9._/]+"#, options: .regularExpression)
        else { return nil }
        return String(text[range].dropFirst("metric: ".count))
    }

    func rewrite(_ sentence: String, key: String, style: CloudRewriteStyle = .grammar) async throws -> String {
        let request = try buildRequest(sentence: sentence, key: key, style: style)
        let (data, response) = try await transport(request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 429 {
                // Honour what the provider says rather than guessing: it knows when the window
                // reopens, and a blanket wait either returns too early or wastes quota.
                let advised = (http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init))
                    ?? Self.retryDelay(in: data)
                let wait = min(max(advised ?? Self.rateLimitCooldown, 1), Self.maximumCooldown)
                cooldownUntil = Date().addingTimeInterval(wait)
                let metric = Self.quotaMetric(in: data) ?? "unspecified"
                log?("REWRITE cloud=" + backend.rawValue + " -> RATE LIMITED "
                     + String(Int(wait)) + "s (quota: " + metric + ")")
            }
            throw CloudRewriteError(Self.errorMessage(status: http.statusCode, body: data))
        }
        cooldownUntil = nil
        return try Self.parse(data, backend: backend)
    }

    func buildRequest(sentence: String, key: String, style: CloudRewriteStyle = .grammar) throws -> URLRequest {
        // Capped, as the cheapest protection against paying for a model that decides to explain
        // itself — but generously enough for a polish, which may legitimately restructure a
        // paragraph rather than repair a clause.
        let maxTokens = min(1200, max(128, sentence.count * 2))

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
                "system": style.instruction,
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
                "systemInstruction": ["parts": [["text": style.instruction]]],
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
        case 429:
            // Naming the bucket turns a vague "out of quota" into something actionable.
            if let metric = quotaMetric(in: body), metric.contains("free_tier") {
                hint = "This key is metered on the free tier - check that billing is enabled on its project."
            } else {
                hint = "Rate limited or out of quota."
            }
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
