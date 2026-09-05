//
//  ActionRunners.swift
//  SelectionActions
//
//  Executing an action. One runner per `ActionKind`, behind a single `ActionRunning` seam so the
//  controller never switches on kind.
//
//  The model runner is injected rather than implemented here: this package deliberately knows nothing
//  about `Proofreading`, HTTP, or which provider is configured. It takes a closure. That keeps the
//  action system testable without a network and keeps provider churn — which is constant, see the
//  retired `gemini-2.5-flash` in ADR-122 — out of a package that is otherwise pure logic.
//
//  On trust: shell and AppleScript actions execute arbitrary code as the user. They exist because
//  they are the reason a power user wants this feature at all, and because *the user wrote them* —
//  there is no marketplace, no import from a URL, nothing that lets a third party put code here. They
//  are still gated by `ActionSideEffects.runsCode` so the UI can mark them, and by
//  `ExecutionPolicy.allowsCodeExecution` so they can be switched off entirely.
//

import Foundation
import JavaScriptCore

// MARK: - Seam

public protocol ActionRunning: Sendable {
    func run(_ action: SelectionAction, on context: SelectionContext) async throws -> ActionResult
}

public struct ActionResult: Equatable, Sendable {
    /// What to do with `text` — normally the action's own `output`, but a runner may downgrade it
    /// (a failed transform should not replace the user's selection with an error message).
    public var output: ActionOutput
    public var text: String

    public init(output: ActionOutput, text: String) {
        self.output = output
        self.text = text
    }
}

public enum ActionError: LocalizedError, Equatable {
    case emptyResult
    /// The engine handed back exactly what it was given. Reported rather than applied: replacing a
    /// selection with itself looks identical to the action doing nothing, and the user deserves to be
    /// told which it was.
    case unchanged
    case codeExecutionDisabled
    case invalidURL(String)
    case scriptFailed(String)
    case modelUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .emptyResult: return "The action produced no text."
        case .unchanged: return "No change suggested."
        case .codeExecutionDisabled: return "Shell and AppleScript actions are turned off in Settings."
        case let .invalidURL(template): return "That action's URL isn't valid: \(template)"
        case let .scriptFailed(message): return message
        case .modelUnavailable: return "No model is configured for AI actions."
        case .timedOut: return "The action took too long and was stopped."
        }
    }
}

/// What the app is willing to let actions do. Enforced at execution, not at display, so a policy
/// change takes effect immediately without rebuilding anyone's action list.
public struct ExecutionPolicy: Equatable, Sendable {
    public var allowsCodeExecution: Bool
    public var scriptTimeout: TimeInterval

    public init(allowsCodeExecution: Bool = false, scriptTimeout: TimeInterval = 10) {
        self.allowsCodeExecution = allowsCodeExecution
        self.scriptTimeout = scriptTimeout
    }
}

// MARK: - Composite runner

public struct ActionRunner: ActionRunning {
    /// Answers a prompt action. Injected — see the file header.
    public typealias ModelResponder = @Sendable (
        _ instruction: String,
        _ fewShot: FewShotPrompt?,
        _ text: String
    ) async throws -> String

    private let policy: ExecutionPolicy
    private let model: ModelResponder?

    public init(policy: ExecutionPolicy = ExecutionPolicy(), model: ModelResponder? = nil) {
        self.policy = policy
        self.model = model
    }

    public func run(_ action: SelectionAction, on context: SelectionContext) async throws -> ActionResult {
        let text = try await produce(action, context: context)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActionError.emptyResult }
        // Only for actions meant to change the text. `Copy` legitimately returns the selection
        // unchanged, and a `.preview` answer that happens to echo the input is still an answer.
        if action.output == .replaceSelection,
           trimmed == context.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            throw ActionError.unchanged
        }
        return ActionResult(output: action.output, text: trimmed)
    }

    private func produce(_ action: SelectionAction, context: SelectionContext) async throws -> String {
        switch action.kind {
        case let .transform(transform):
            return TextTransformer.apply(transform, to: context.text)

        case let .prompt(instruction):
            guard let model else { throw ActionError.modelUnavailable }
            return try await model(instruction, action.fewShot, context.text)

        case let .javaScript(source):
            return try JavaScriptActionRunner.run(source, text: context.text)

        case let .url(template):
            return try URLActionRunner.resolve(template, context: context).absoluteString

        case let .shell(command):
            guard policy.allowsCodeExecution else { throw ActionError.codeExecutionDisabled }
            return try ProcessActionRunner.shell(command, input: context.text, timeout: policy.scriptTimeout)

        case let .appleScript(source):
            guard policy.allowsCodeExecution else { throw ActionError.codeExecutionDisabled }
            return try ProcessActionRunner.appleScript(source, input: context.text, timeout: policy.scriptTimeout)
        }
    }
}

// MARK: - Transforms

public enum TextTransformer {
    public static func apply(_ transform: TextTransform, to text: String) -> String {
        switch transform {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return titleCased(text)
        case .sentenceCase: return sentenceCased(text)
        case .trimWhitespace: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseWhitespace: return collapsed(text)
        case .removeLineBreaks: return collapsed(text.replacingOccurrences(of: "\n", with: " "))
        case .slugify: return slugified(text)
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else { return "" }
            return decoded
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        case .urlDecode:
            return text.removingPercentEncoding ?? text
        case .sortLines:
            return lines(text).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .reverseLines:
            return lines(text).reversed().joined(separator: "\n")
        case .deduplicateLines:
            var seen = Set<String>()
            return lines(text).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .countCharactersAndWords:
            let words = SelectionContext.countWords(in: text)
            let characters = text.count
            let lineCount = lines(text).count
            return "\(characters) character\(characters == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s") · \(lineCount) line\(lineCount == 1 ? "" : "s")"
        }
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Title case that leaves short joining words alone, which is what people mean by it. `capitalized`
    /// would give "The Meeting Is At The Office".
    static func titleCased(_ text: String) -> String {
        let minor: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "if", "in", "nor",
                                  "of", "on", "or", "so", "the", "to", "up", "via", "yet"]
        let words = text.lowercased().split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { index, word -> String in
            let string = String(word)
            guard !string.isEmpty else { return string }
            if index > 0, index < words.count - 1, minor.contains(string) { return string }
            return string.prefix(1).uppercased() + string.dropFirst()
        }.joined(separator: " ")
    }

    static func sentenceCased(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text.lowercased() {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    static func slugified(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive], locale: .current).lowercased()
        let allowed = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}

// MARK: - JavaScript

/// Runs a JavaScript body with the selection bound to `text`.
///
/// The context is bare. `JSContext` with no host objects installed has no filesystem, no network, no
/// timers and no `require` — the reachable surface is ECMAScript itself, which is exactly what a text
/// transform needs and nothing more. That is why a JS action is classified as having no side effects
/// while a shell action is not.
public enum JavaScriptActionRunner {
    public static func run(_ source: String, text: String) throws -> String {
        guard let context = JSContext() else { throw ActionError.scriptFailed("JavaScript is unavailable.") }

        var failure: String?
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "Unknown JavaScript error"
        }
        context.setObject(text, forKeyedSubscript: "text" as NSString)

        // Two shapes are accepted, because users write both: a bare expression
        // (`JSON.stringify(JSON.parse(text), null, 2)`) and a multi-statement body with an explicit
        // `return`. Rejecting either would be a support burden for no gain, and the difference is one
        // substring check — an expression gets wrapped in `return (...)`, a body is used as-is.
        let body = source.contains("return ") ? source : "return (\(source));"
        let value = context.evaluateScript("(function(text) { \"use strict\"; \(body) })(text)")

        if let failure { throw ActionError.scriptFailed(failure) }
        guard let value, !value.isUndefined, !value.isNull else { throw ActionError.emptyResult }
        return value.toString() ?? ""
    }
}

// MARK: - URL

public enum URLActionRunner {
    /// Substitutes `{{text}}` (percent-encoded) and `{{text|raw}}` (verbatim) in a template.
    public static func resolve(_ template: String, context: SelectionContext) throws -> URL {
        let raw = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw

        var filled = template
            .replacingOccurrences(of: "{{text|raw}}", with: raw)
            .replacingOccurrences(of: "{{text}}", with: encoded)

        // A bare "example.com" selection is a link to a person and should behave like one.
        if !filled.contains("://"), !filled.hasPrefix("mailto:"), !filled.hasPrefix("dict://") {
            filled = "https://" + filled
        }

        guard let url = URL(string: filled), url.scheme != nil else {
            throw ActionError.invalidURL(template)
        }
        return url
    }
}

// MARK: - Shell / AppleScript

enum ProcessActionRunner {
    static func shell(_ command: String, input: String, timeout: TimeInterval) throws -> String {
        try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            input: input,
            timeout: timeout
        )
    }

    static func appleScript(_ source: String, input: String, timeout: TimeInterval) throws -> String {
        // Via `osascript` rather than `NSAppleScript` so it inherits the same timeout and output
        // handling as a shell action, and so a script that blocks cannot wedge the main actor.
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-"],
            input: source.replacingOccurrences(of: "{{text}}", with: escapedForAppleScript(input)),
            timeout: timeout
        )
    }

    static func escapedForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(
        executable: URL,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ActionError.scriptFailed(error.localizedDescription)
        }

        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()

        // Read before waiting. A command that fills the 64KB pipe buffer blocks forever on write
        // while we block on `waitUntilExit`, and the two deadlock — the classic Process trap.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            throw ActionError.timedOut
        }

        let output = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError.scriptFailed(message.isEmpty ? "Exited with status \(process.terminationStatus)." : message)
        }
        return output
    }
}
