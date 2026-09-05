//
//  ActionsSettingsModel.swift
//  KeyType
//
//  The observable layer over `ActionStore`.
//
//  `ActionStore` is a plain value-semantics type on purpose — it is testable without a run loop, and
//  the action engine has no business knowing about SwiftUI. This is the adapter: it republishes the
//  store for the Settings pane and translates edits back into store calls.
//
//  Every edit writes through immediately rather than on an explicit Save. A settings pane with a Save
//  button invites a user to close the window and lose their work, and the store already persists
//  atomically on every mutation, so there is nothing to batch.
//

import Combine
import Foundation
import SelectionActions
import SwiftUI

@MainActor
final class ActionsSettingsModel: ObservableObject {
    private let store: ActionStore
    private let settings: SettingsStore
    /// Runs an action for the Try-it field. Injected so the pane exercises the *same* runner the
    /// toolbar uses — a test button that takes a different path is worse than no test button.
    private let makeRunner: (Bool) -> ActionRunning

    @Published var selectedID: String?
    @Published private(set) var actions: [SelectionAction] = []
    @Published var sampleText: String = "we was late to the meeting and i think we should of called ahead."
    @Published private(set) var isTesting = false
    @Published private(set) var testResult: TestResult?

    @Published var allowsCodeExecution: Bool {
        didSet {
            guard allowsCodeExecution != oldValue else { return }
            settings.allowsActionCodeExecution = allowsCodeExecution
        }
    }

    struct TestResult: Equatable {
        var text: String
        var isFailure: Bool
    }

    init(
        store: ActionStore,
        settings: SettingsStore,
        makeRunner: @escaping (Bool) -> ActionRunning
    ) {
        self.store = store
        self.settings = settings
        self.makeRunner = makeRunner
        self.allowsCodeExecution = settings.allowsActionCodeExecution
        reload()
    }

    func reload() {
        actions = store.allActions
    }

    var selectedAction: SelectionAction? {
        actions.first { $0.id == selectedID }
    }

    var canDeleteSelection: Bool {
        selectedAction.map { !$0.isBuiltIn } ?? false
    }

    // MARK: - Arrangement

    func isEnabled(_ action: SelectionAction) -> Bool { store.preferences.isEnabled(action.id) }
    func isPinned(_ action: SelectionAction) -> Bool { store.preferences.isPinned(action.id) }

    func setEnabled(_ enabled: Bool, for action: SelectionAction) {
        store.update { $0.setEnabled(enabled, for: action.id) }
        objectWillChange.send()
    }

    func setPinned(_ pinned: Bool, for action: SelectionAction) {
        store.update { $0.setPinned(pinned, for: action.id) }
        objectWillChange.send()
    }

    /// Reordering persists the *whole* visible order, not just the moved item, because the stored
    /// order is a list of ids and a partial one would leave everything after the move sorting by
    /// catalogue position instead.
    func move(from source: IndexSet, to destination: Int) {
        var reordered = actions
        reordered.move(fromOffsets: source, toOffset: destination)
        let ids = reordered.map(\.id)
        store.update { $0.order = ids }
        actions = reordered
    }

    // MARK: - Authoring

    enum NewActionKind: CaseIterable {
        case transform, prompt, javaScript, shell, appleScript, url

        var title: String {
            switch self {
            case .transform: return "Text Transformation"
            case .prompt: return "AI Prompt"
            case .javaScript: return "JavaScript"
            case .shell: return "Terminal Command"
            case .appleScript: return "AppleScript"
            case .url: return "Link"
            }
        }

        /// A starting body that does something real, so a new action can be run immediately and
        /// edited from a working example rather than from a blank field.
        var starter: (kind: ActionKind, symbol: String, output: ActionOutput, name: String) {
            switch self {
            case .transform: return (.transform(.titleCase), "textformat", .replaceSelection, "My Transformation")
            case .prompt: return (.prompt("Rewrite the text below to be clearer. Reply with the rewritten text and nothing else."), "sparkles", .replaceSelection, "My Prompt")
            case .javaScript: return (.javaScript("function run(selected_text) {\n  return selected_text.trim();\n}"), "curlybraces", .replaceSelection, "My Script")
            case .shell: return (.shell("printf '%s' {{text}} | wc -w"), "terminal", .preview, "Word Count")
            case .appleScript: return (.appleScript("return \"{{text}}\""), "applescript", .preview, "My AppleScript")
            case .url: return (.url("https://duckduckgo.com/?q={{text}}"), "link", .openURL, "My Link")
            }
        }
    }

    func addCustomAction(_ kind: NewActionKind) {
        let starter = kind.starter
        let action = SelectionAction(
            id: ActionStore.newCustomID(),
            title: starter.name,
            symbolName: starter.symbol,
            kind: starter.kind,
            output: starter.output
        )
        store.upsertCustom(action)
        reload()
        selectedID = action.id
    }

    func deleteSelected() {
        guard let action = selectedAction, !action.isBuiltIn else { return }
        store.removeCustom(id: action.id)
        selectedID = nil
        reload()
    }

    private func update(_ action: SelectionAction, _ mutate: (inout SelectionAction) -> Void) {
        var copy = action
        mutate(&copy)
        store.upsertCustom(copy)
        reload()
    }

    func binding<Value>(
        for action: SelectionAction,
        _ keyPath: WritableKeyPath<SelectionAction, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (self.actions.first { $0.id == action.id } ?? action)[keyPath: keyPath] },
            set: { newValue in self.update(action) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// The editable body of whichever kind this action is. One binding rather than six, because the
    /// editor shows one text field and the kind only decides how it is interpreted.
    func bodyBinding(for action: SelectionAction) -> Binding<String> {
        Binding(
            get: { Self.body(of: (self.actions.first { $0.id == action.id } ?? action).kind) },
            set: { newValue in
                self.update(action) { $0.kind = Self.replacingBody(of: $0.kind, with: newValue) }
            }
        )
    }

    func transformBinding(for action: SelectionAction) -> Binding<TextTransform> {
        Binding(
            get: {
                if case let .transform(transform) = (self.actions.first { $0.id == action.id } ?? action).kind {
                    return transform
                }
                return .titleCase
            },
            set: { newValue in self.update(action) { $0.kind = .transform(newValue) } }
        )
    }

    static func body(of kind: ActionKind) -> String {
        switch kind {
        case let .prompt(text), let .javaScript(text), let .shell(text), let .appleScript(text), let .url(text):
            return text
        case .transform:
            return ""
        }
    }

    static func replacingBody(of kind: ActionKind, with text: String) -> ActionKind {
        switch kind {
        case .prompt: return .prompt(text)
        case .javaScript: return .javaScript(text)
        case .shell: return .shell(text)
        case .appleScript: return .appleScript(text)
        case .url: return .url(text)
        case .transform: return kind
        }
    }

    // MARK: - Try it

    func test(_ action: SelectionAction) {
        isTesting = true
        testResult = nil
        let runner = makeRunner(allowsCodeExecution)
        let context = SelectionContext(text: sampleText, bundleIdentifier: Bundle.main.bundleIdentifier)
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let result = try await runner.run(action, on: context)
                testResult = TestResult(text: result.text, isFailure: false)
            } catch {
                testResult = TestResult(text: error.localizedDescription, isFailure: true)
            }
        }
    }

    // MARK: - Descriptions

    static let iconChoices = [
        "sparkles", "wand.and.stars", "textformat", "text.badge.checkmark", "curlybraces",
        "terminal", "applescript", "link", "magnifyingglass", "doc.on.doc", "envelope",
        "list.bullet", "number", "scissors", "arrow.up.arrow.down", "questionmark.circle",
        "bubble.left", "briefcase", "map", "character.book.closed",
    ]

    static func isCode(_ kind: ActionKind) -> Bool {
        switch kind {
        case .javaScript, .shell, .appleScript, .url: return true
        case .prompt, .transform: return false
        }
    }

    static func hint(for kind: ActionKind) -> String? {
        switch kind {
        case .prompt:
            return "The selected text is appended below your instruction."
        case .javaScript:
            return "The selection is available as `text` or `selected_text`. Write an expression, a body with `return`, or a `function run(selected_text)`. No network or filesystem access."
        case .shell:
            return "The selection arrives on stdin, and `{{text}}` is substituted as a safely quoted argument."
        case .appleScript:
            return "`{{text}}` is substituted as an escaped string literal."
        case .url:
            return "`{{text}}` is URL-encoded; `{{text|raw}}` is inserted verbatim."
        case .transform:
            return nil
        }
    }

    static func describe(_ sideEffects: ActionSideEffects) -> String {
        switch sideEffects {
        case .none: return "Runs entirely on this Mac. Nothing is sent anywhere."
        case .sendsTextToModel: return "Sends the selected text to whichever model you have configured."
        case .opensURL: return "Opens a link in your browser."
        case .runsCode: return "Runs a command on your Mac with your own permissions."
        }
    }

    static func describe(_ conditions: ActionConditions) -> String {
        var parts: [String] = []
        if conditions.requiresURL == true { parts.append("a link") }
        if conditions.requiresEmail == true { parts.append("an email address") }
        if conditions.requiresCodeLike == true { parts.append("code") }
        if conditions.requiresMultipleLines == true { parts.append("several lines") }
        if let minimum = conditions.minimumWords, let maximum = conditions.maximumWords {
            parts.append("\(minimum)–\(maximum) words")
        } else if let minimum = conditions.minimumWords {
            parts.append("\(minimum)+ words")
        } else if let maximum = conditions.maximumWords {
            parts.append("up to \(maximum) words")
        }
        return parts.isEmpty ? "Any selection" : parts.joined(separator: ", ")
    }
}
