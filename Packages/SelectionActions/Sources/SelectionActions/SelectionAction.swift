//
//  SelectionAction.swift
//  SelectionActions
//
//  What the selection toolbar can do, as data rather than as code.
//
//  The toolbar used to be two hardcoded `NSButton`s and a two-case enum, which is why it had two
//  actions: every new one cost a property, a selector, a stack insertion and a switch arm. Describing
//  an action instead means a new one costs a value in an array, and — this is the part that actually
//  matters — means the user can write one. A built-in action and a user's own are the same type here,
//  differing only in `isBuiltIn`, so everything downstream (ranking, persistence, the settings list,
//  execution) works on both without knowing which it has.
//
//  Every case of `ActionKind` is `Codable` for the same reason: a custom action has to survive a
//  relaunch, so the *definition* is data, not a closure. Closures appear only in the runners, which
//  interpret these values.
//

import Foundation

// MARK: - Action

public struct SelectionAction: Identifiable, Codable, Equatable, Sendable {
    /// Stable across renames and reorders — it keys the user's enable/pin/order preferences and the
    /// usage history, so it must never be derived from the title.
    public var id: String
    public var title: String
    /// Shown in Settings only. The toolbar itself is text, because a floating callout over the user's
    /// own writing is furniture and Apple's does not carry icons (ADR-134).
    public var symbolName: String
    public var kind: ActionKind
    public var output: ActionOutput
    /// When this action is worth offering. An empty set of conditions means "always".
    public var conditions: ActionConditions
    /// Ships with the app. Users can disable, reorder and pin these but not delete or rewrite them —
    /// a corrupted built-in is a support problem, where a corrupted custom action is just the user's
    /// own to fix.
    public var isBuiltIn: Bool
    /// Worked examples for engines that cannot follow an instruction.
    ///
    /// Measured against the shipped on-device model (`Qwen3.5-2B-Base`), a *base* model: asked by
    /// ChatML instruction to shorten, expand, or change register, it returned the input **verbatim**
    /// every time. Given three worked examples and asked to continue the pattern, it shortened and
    /// re-registered correctly. That is the same finding the inline grammar pass already acts on, and
    /// the reason it is prompted few-shot.
    ///
    /// Optional, so an action can decline to offer any — and so the property can be added without
    /// invalidating a stored custom action, since a synthesized decoder treats a missing key for an
    /// Optional as nil.
    public var fewShot: FewShotPrompt?
    /// Tie-breaker among actions that match equally well. Higher wins. Only meaningful for built-ins;
    /// custom actions all start at zero and rise through use.
    public var priority: Int

    public init(
        id: String,
        title: String,
        symbolName: String = "sparkles",
        kind: ActionKind,
        output: ActionOutput = .replaceSelection,
        conditions: ActionConditions = .init(),
        fewShot: FewShotPrompt? = nil,
        isBuiltIn: Bool = false,
        priority: Int = 0
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.kind = kind
        self.output = output
        self.conditions = conditions
        self.fewShot = fewShot
        self.isBuiltIn = isBuiltIn
        self.priority = priority
    }

    /// Whether running this action can reach the network or the machine beyond the text itself.
    /// Surfaced in Settings next to the action, because "summarize this" and "run this shell command
    /// on this" deserve visibly different amounts of trust.
    public var sideEffects: ActionSideEffects {
        switch kind {
        case .transform:
            return .none
        case .javaScript:
            // Sandboxed to a bare JSContext with no host objects — see JavaScriptActionRunner.
            return .none
        case .prompt:
            return .sendsTextToModel
        case .url:
            return .opensURL
        case .shell, .appleScript:
            return .runsCode
        }
    }
}

/// A short header plus worked examples, for a base model that continues patterns rather than obeying
/// instructions. The header is separate from the action's `instruction` on purpose: the instruction
/// ends "Reply with the rewritten text and nothing else", which is addressed to a chat model and is
/// noise in front of a list of examples.
public struct FewShotPrompt: Codable, Equatable, Sendable {
    public var header: String
    public var examples: [PromptExample]

    public init(header: String, examples: [PromptExample]) {
        self.header = header
        self.examples = examples
    }
}

public struct PromptExample: Codable, Equatable, Sendable {
    public var original: String
    public var rewritten: String

    public init(_ original: String, _ rewritten: String) {
        self.original = original
        self.rewritten = rewritten
    }
}

public enum ActionSideEffects: String, Codable, Sendable {
    case none
    case sendsTextToModel
    case opensURL
    case runsCode
}

// MARK: - Kind

public enum ActionKind: Codable, Equatable, Sendable {
    /// An instruction handed to whichever model backend is configured, with the selection as input.
    case prompt(String)
    /// A pure-Swift text transformation. Free, instant, offline, and impossible to get wrong at
    /// runtime — most of the 35-action feeling comes from these rather than from AI.
    case transform(TextTransform)
    /// A JavaScript body evaluated with the selection bound to `text`; the completion value is the
    /// result. See `JavaScriptActionRunner` for what is and is not reachable from inside.
    case javaScript(String)
    /// A shell command run through `/bin/sh -c`, with the selection on stdin.
    case shell(String)
    case appleScript(String)
    /// A URL with `{{text}}` (and optionally `{{text|raw}}`) substituted from the selection.
    case url(String)

    /// For grouping in the editor and for choosing the right runner.
    public var label: String {
        switch self {
        case .prompt: return "AI prompt"
        case .transform: return "Built-in transform"
        case .javaScript: return "JavaScript"
        case .shell: return "Shell command"
        case .appleScript: return "AppleScript"
        case .url: return "Open URL"
        }
    }
}

/// The offline transformations. Deliberately a closed enum rather than a registry of closures: these
/// are persisted inside custom actions, so the set has to be nameable in JSON and stable across
/// versions.
public enum TextTransform: String, Codable, CaseIterable, Sendable {
    case uppercase
    case lowercase
    case titleCase
    case sentenceCase
    case trimWhitespace
    case collapseWhitespace
    case removeLineBreaks
    case slugify
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case sortLines
    case reverseLines
    case deduplicateLines
    case countCharactersAndWords

    public var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .sentenceCase: return "Sentence case"
        case .trimWhitespace: return "Trim whitespace"
        case .collapseWhitespace: return "Collapse spaces"
        case .removeLineBreaks: return "Remove line breaks"
        case .slugify: return "Slugify"
        case .base64Encode: return "Base64 encode"
        case .base64Decode: return "Base64 decode"
        case .urlEncode: return "URL encode"
        case .urlDecode: return "URL decode"
        case .sortLines: return "Sort lines"
        case .reverseLines: return "Reverse lines"
        case .deduplicateLines: return "Remove duplicate lines"
        case .countCharactersAndWords: return "Count"
        }
    }
}

// MARK: - Output

public enum ActionOutput: String, Codable, CaseIterable, Sendable {
    /// Write the result over the selection. The default, and the only one that changes the document.
    case replaceSelection
    /// Put the result on the clipboard and leave the document alone.
    case copyToClipboard
    /// Treat the result as a URL and open it.
    case openURL
    /// Show the result without applying it — for counts, lookups and anything the user wants to read
    /// rather than insert.
    case preview

    public var title: String {
        switch self {
        case .replaceSelection: return "Replace the selection"
        case .copyToClipboard: return "Copy to clipboard"
        case .openURL: return "Open URL"
        case .preview: return "Show result"
        }
    }

    public var changesTheDocument: Bool { self == .replaceSelection }
}

// MARK: - Conditions

/// When an action is worth offering, expressed declaratively so a custom action's conditions can be
/// stored in JSON and edited in a form. A predicate closure would be more expressive and could not be
/// persisted, which is the wrong trade for the one thing users most want to customise.
///
/// Every field is optional and nil means "don't care". All stated conditions must hold.
public struct ActionConditions: Codable, Equatable, Sendable {
    public var minimumWords: Int?
    public var maximumWords: Int?
    public var minimumCharacters: Int?
    public var maximumCharacters: Int?
    public var requiresURL: Bool?
    public var requiresEmail: Bool?
    public var requiresMultipleLines: Bool?
    public var requiresCodeLike: Bool?
    /// Restrict to (or exclude from) particular apps. Empty means every app.
    public var allowedBundleIdentifiers: [String]
    public var blockedBundleIdentifiers: [String]

    public init(
        minimumWords: Int? = nil,
        maximumWords: Int? = nil,
        minimumCharacters: Int? = nil,
        maximumCharacters: Int? = nil,
        requiresURL: Bool? = nil,
        requiresEmail: Bool? = nil,
        requiresMultipleLines: Bool? = nil,
        requiresCodeLike: Bool? = nil,
        allowedBundleIdentifiers: [String] = [],
        blockedBundleIdentifiers: [String] = []
    ) {
        self.minimumWords = minimumWords
        self.maximumWords = maximumWords
        self.minimumCharacters = minimumCharacters
        self.maximumCharacters = maximumCharacters
        self.requiresURL = requiresURL
        self.requiresEmail = requiresEmail
        self.requiresMultipleLines = requiresMultipleLines
        self.requiresCodeLike = requiresCodeLike
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.blockedBundleIdentifiers = blockedBundleIdentifiers
    }

    /// How many conditions this states at all. Reported in the editor so a user can see how narrow
    /// they have made an action; deliberately *not* what the ranker scores — see `discriminators`.
    public var specificity: Int {
        var count = 0
        for stated in [
            minimumWords != nil, maximumWords != nil,
            minimumCharacters != nil, maximumCharacters != nil,
            requiresURL != nil, requiresEmail != nil,
            requiresMultipleLines != nil, requiresCodeLike != nil,
        ] where stated {
            count += 1
        }
        if !allowedBundleIdentifiers.isEmpty { count += 1 }
        if !blockedBundleIdentifiers.isEmpty { count += 1 }
        return count
    }

    /// Conditions that assert something *positive* about the content — "this action is for text like
    /// this". Only these are evidence of fit, and only these are ranked.
    ///
    /// Length bounds are excluded on purpose. `maximumWords: 60` on Expand is a guard against being
    /// offered where it would be nonsense, not a claim that a 60-word paragraph is what Expand is
    /// *for*; scoring it as relevance put Expand above Summarize on a long paragraph. A negative
    /// predicate (`requiresMultipleLines: false`) is the same kind of guard and is excluded for the
    /// same reason.
    public var discriminators: Int {
        var count = 0
        for asserted in [requiresURL, requiresEmail, requiresMultipleLines, requiresCodeLike] {
            if asserted == true { count += 1 }
        }
        if !allowedBundleIdentifiers.isEmpty { count += 1 }
        return count
    }

    public func matches(_ context: SelectionContext) -> Bool {
        if let minimumWords, context.wordCount < minimumWords { return false }
        if let maximumWords, context.wordCount > maximumWords { return false }
        if let minimumCharacters, context.characterCount < minimumCharacters { return false }
        if let maximumCharacters, context.characterCount > maximumCharacters { return false }
        if let requiresURL, context.containsURL != requiresURL { return false }
        if let requiresEmail, context.containsEmail != requiresEmail { return false }
        if let requiresMultipleLines, context.isMultiline != requiresMultipleLines { return false }
        if let requiresCodeLike, context.looksLikeCode != requiresCodeLike { return false }

        let bundle = context.bundleIdentifier ?? ""
        if !allowedBundleIdentifiers.isEmpty, !allowedBundleIdentifiers.contains(bundle) { return false }
        if blockedBundleIdentifiers.contains(bundle) { return false }
        return true
    }
}
