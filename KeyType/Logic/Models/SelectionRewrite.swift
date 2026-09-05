//
//  SelectionRewrite.swift
//  Glide
//
//  "Polish" / "Grammar" selection actions. When the user selects text in any app, a small
//  non-activating popover appears above the selection with two buttons. Clicking one rewrites the
//  selected text with the local model and replaces it in place.
//
//  Design: this is deliberately ISOLATED from the autocomplete pipeline (CompletionController owns a
//  single-KV-cache runtime tuned for constrained decoding). `RewriteService` loads its own small
//  `LlamaModelRuntime` from the same GGUF — llama.cpp mmaps the weights, so a second instance shares
//  the physical pages and adds little memory — and does plain greedy generation against a few-shot
//  prompt (the default catalog model is a *base* model, so we prime it with examples rather than an
//  instruction it wouldn't follow).
//

import AppKit
import SwiftUI
import ApplicationServices
import AutocompleteCore
import CompletionUI
import LlamaModelRuntime
import MacContextCapture
import ModelRuntime
import Proofreading
import SelectionActions
import os

/// Append log for the rewrite path.
///
/// This used to write to `/tmp/glide-rewrite.log`, which was a genuine leak: `/private/tmp` is
/// mode 1777, the file landed there world-readable, it recorded the text being rewritten, and it
/// grew without bound. Any other process running as any user on the machine could read what the
/// user had been writing. It now lives beside the prediction log under Application Support, whose
/// parent `~/Library` is `drwx------`, and text goes through the same capture gate as everything
/// else. `purgeLegacyLog()` deletes the old file so existing installs stop leaking too.
enum RewriteLog {
    private static let url: URL? = {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("KeyType/Logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("rewrite.log", isDirectory: false)
    }()

    private static let legacyURL = URL(fileURLWithPath: "/tmp/glide-rewrite.log")

    /// Keeps the file from growing without bound; the old one reached half a megabyte unnoticed.
    private static let maximumBytes = 512 * 1024

    /// Remove the world-readable log earlier versions wrote. Called once at launch, so upgrading is
    /// enough to clear the exposure — a fix that only protects new writes would leave every existing
    /// install leaking whatever it had already collected.
    static func purgeLegacyLog() {
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// Text destined for the log. Redacted to a length unless capture is explicitly enabled.
    static func text(_ value: String?) -> String {
        guard let value else { return "⟨none⟩" }
        return PredictionLog.capturesText ? value.prefix(80).debugDescription : PredictionLog.redacted(value)
    }

    static func write(_ message: String) {
        guard let url else { return }
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()).map({ $0 > UInt64(maximumBytes) }) == true {
                try? handle.truncate(atOffset: 0)
            }
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Generation

/// Owns a dedicated llama runtime for free-form rewrites, separate from the autocomplete engine.
actor RewriteService {
    /// `Equatable` is declared rather than synthesized: an enum stops getting it for free the moment
    /// a case carries an associated value, and `.custom` does.
    enum Style: Equatable {
        case polish
        case grammar
        /// An arbitrary instruction, optionally with worked examples. The whole action system routes
        /// its prompts through here rather than through a fixed set of styles.
        case custom(RewriteInstruction)
        /// Grammar, but prompted few-shot rather than by instruction, and stopped at the first
        /// newline. Used by the inline sentence pass. The catalog model is a *base* model, and
        /// measured against it few-shot is materially better: asked by ChatML instruction it turned
        /// "Their going to send us the files tomorrow." into "Their are going to send us the files
        /// tomorrow." — leaving the homophone and adding a verb error — where the examples below
        /// produce "They are going to send us the files tomorrow." It also stays closer to a
        /// correction: instructed, it rewrote "He don't agree with it." as "He disagrees with it."
        case inlineGrammar

        /// Few-shot styles continue a pattern, so the answer ends at the newline rather than at a
        /// chat end-of-turn marker the base model has no reason to emit.
        /// Few-shot styles continue a pattern, so the answer ends at the newline rather than at a
        /// chat end-of-turn marker the base model has no reason to emit. That applies to any
        /// example-driven prompt, not just the inline grammar one.
        var stopsAtNewline: Bool {
            if case let .custom(spec) = self { return spec.hasExamples }
            return self == .inlineGrammar
        }
    }

    private var runtime: LlamaModelRuntime?
    private var loadedFilename: String?
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "rewrite")

    func shutdown() async {
        await runtime?.shutdown()
        runtime = nil
        loadedFilename = nil
    }

    /// Rewrite `text` in the given style using the model `modelFilename`. Returns nil on any failure
    /// (caller simply shows nothing).
    func rewrite(_ text: String, style: Style, modelFilename: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let rt = try runtime(for: modelFilename)
            let prompt = Self.prompt(for: trimmed, style: style)
            // Tokenize with special-token parsing so the ChatML markers (`<|im_start|>`, `<think>`,
            // …) become their single control tokens rather than literal text.
            let promptTokens = try rt.tokenizer.tokenizeAllowingSpecial(prompt)
            await rt.resetKVCache()
            try await rt.prepare(promptTokens: promptTokens)

            // Stop tokens: EOS plus `<|im_end|>` (end of the assistant turn). Ban `<think>` so the
            // model can't re-open reasoning even though we pre-closed it in the prompt.
            var stops = Set<TokenID>()
            if let eos = rt.metadata.eosTokenID { stops.insert(eos) }
            if let eot = rt.metadata.eotTokenID { stops.insert(eot) }
            for marker in ["<|im_end|>", "<|endoftext|>"] {
                if let t = try? rt.tokenizer.tokenizeAllowingSpecial(marker), t.count == 1 { stops.insert(t[0]) }
            }
            let banned = Self.bannedTokenIDs(rt)

            let maxTokens = min(320, max(64, trimmed.count * 2))
            var produced: [TokenID] = []
            for _ in 0..<maxTokens {
                let logits = try await rt.logitsForNextToken()
                guard let best = logits.lazy
                    .filter({ !banned.contains($0.tokenID) })
                    .max(by: { $0.logit < $1.logit })?.tokenID else { break }
                if stops.contains(best) { break }
                produced.append(best)
                try await rt.decodeNext(tokenID: best)
                // A few-shot prompt has nothing to stop it continuing the pattern with another
                // "Original: … Corrected: …" pair, so end the answer at its newline instead of
                // generating (and paying for) the rest of the budget.
                if style.stopsAtNewline,
                   let text = try? rt.tokenizer.detokenize(produced),
                   text.contains("\n") {
                    break
                }
            }
            let raw = (try? rt.tokenizer.detokenize(produced)) ?? ""
            let result = Self.clean(raw)
            RewriteLog.write("rewrite[\(style)] in=\(RewriteLog.text(trimmed)) tokens=\(produced.count) raw=\(RewriteLog.text(raw)) -> \(RewriteLog.text(result))")
            return result
        } catch {
            log.error("rewrite failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func runtime(for filename: String) throws -> LlamaModelRuntime {
        if let runtime, loadedFilename == filename { return runtime }
        // Model changed (or first use) — drop the old one and load the new GGUF.
        let url = try ModelContainer.modelURL(filename: filename)
        guard ModelContainer.modelExists(at: url) else {
            throw NSError(domain: "Glide.Rewrite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not installed"])
        }
        let rt = try LlamaModelRuntime(modelURL: url, contextLength: 2048)
        runtime = rt
        loadedFilename = filename
        return rt
    }

    // MARK: - Prompt (ChatML with thinking pre-disabled)

    /// Builds a ChatML prompt and pre-fills the assistant turn with an *empty* `<think></think>`
    /// block. For Qwen3-style reasoning models this is the documented way to disable chain-of-
    /// thought — the model sees thinking already finished and emits the answer directly, instead of
    /// leaking "<think> Okay, the user wants…". Tokenized with `tokenizeAllowingSpecial` so the
    /// markers resolve to control tokens. Falls back gracefully on non-ChatML models (the markers
    /// become harmless text and the instruction still steers the output).
    private static func prompt(for text: String, style: Style) -> String {
        if style == .inlineGrammar { return fewShotGrammarPrompt(for: text) }
        // Any example-driven prompt takes the same shape, and for the same measured reason: the
        // shipped model is a *base* model, and asked by instruction to shorten or change register it
        // returns the input verbatim. See ADR-138.
        if case let .custom(spec) = style, spec.hasExamples {
            return fewShotPrompt(header: spec.fewShotHeader ?? "", examples: spec.examples, text: text)
        }

        let instruction: String
        switch style {
        case .inlineGrammar:
            instruction = ""   // handled above
        case .grammar:
            instruction = "Fix the grammar, spelling, and punctuation of the text below. Keep the original meaning, tone, and wording where possible."
        case .polish:
            instruction = "Rewrite the text below to be clearer and more polished, keeping the original meaning and a natural tone."
        case let .custom(spec):
            instruction = spec.instruction
        }
        return """
        <|im_start|>system
        You are a writing assistant. Output ONLY the rewritten text — no preamble, no explanation, no quotes.<|im_end|>
        <|im_start|>user
        \(instruction)

        \(text)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
    }

    /// The generic few-shot shape: a short header, worked pairs, then the text — the model continues
    /// the pattern rather than being asked to obey an instruction it was never tuned to follow.
    private static func fewShotPrompt(header: String, examples: [RewriteExample], text: String) -> String {
        var prompt = header + "\n\n"
        for example in examples {
            prompt += "Original: \(example.original)\nRewritten: \(example.rewritten)\n\n"
        }
        return prompt + "Original: \(text)\nRewritten:"
    }

    /// Few-shot grammar correction: three worked examples, then the sentence to correct. A base
    /// model continues the pattern, which is what it is good at, rather than being asked to obey an
    /// instruction it was never tuned to follow.
    private static func fewShotGrammarPrompt(for text: String) -> String {
        """
        Correct the grammar of each sentence. Keep the wording and meaning.

        Original: We was late to the meeting.
        Corrected: We were late to the meeting.

        Original: She dont know the answer yet.
        Corrected: She doesn't know the answer yet.

        Original: Him and me finished the report.
        Corrected: He and I finished the report.

        Original: \(text)
        Corrected:
        """
    }

    /// Token IDs for reasoning / chat-control markers, to ban during generation. Resolved via the
    /// tokenizer's special-token parsing; only single-token markers are banned.
    private static func bannedTokenIDs(_ rt: LlamaModelRuntime) -> Set<TokenID> {
        var ids = Set<TokenID>()
        let markers = [
            "<think>", "</think>",
            "<|im_start|>", "<|im_end|>", "<|endoftext|>",
            "<|assistant|>", "<|user|>", "<|system|>",
        ]
        for marker in markers {
            if let tokens = try? rt.tokenizer.tokenizeAllowingSpecial(marker), tokens.count == 1 {
                ids.insert(tokens[0])
            }
        }
        return ids
    }

    private static func clean(_ raw: String) -> String? {
        var s = raw
        // Drop any reasoning block the model still managed to open, plus stray tags.
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // First non-empty line is the rewrite.
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        s = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an echoed label if the model repeated it.
        for label in ["Polished:", "Corrected:", "Rewritten:", "Output:"] {
            if s.hasPrefix(label) { s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
        }
        if let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? nil : s
    }
}

// MARK: - Popover

/// Borderless, non-activating panel with Polish / Grammar buttons that floats above the selection.
@MainActor
final class SelectionRewritePopover: NSPanel {
    var onAction: ((SelectionAction) -> Void)?
    /// Dismissal by the user. Escape does the same thing, but a visible control is the only one that
    /// is discoverable — nobody guesses at a keystroke for a panel they did not ask for.
    var onClose: (() -> Void)?
    /// The user took the result shown by `showResult`.
    var onAcceptResult: ((String) -> Void)?
    /// The user cancelled while an action was running.
    var onCancel: (() -> Void)?

    /// One SwiftUI root for every state. Replaces an `NSStackView` of `NSButton`s, hairline `NSBox`
    /// dividers, a spinner and a hand-rolled result surface — see `SelectionToolbarView` for what the
    /// system now owns that we used to.
    ///
    /// Hosted in `FirstMouseHostingView`, not a plain `NSHostingView`, and that is not incidental: a
    /// borderless non-activating panel gets its first click while another app is frontmost, and
    /// without `acceptsFirstMouse` that click is spent activating rather than pressing (ADR-119).
    private let stack = NSStackView()
    private var surface: NSVisualEffectView?
    /// 10pt, matching the requested spec, rather than the capsule this used to be.
    private static let cornerRadius: CGFloat = 10
    private var state: SelectionToolbarState = .actions([])
    private var visibleItems: [SelectionActions.ToolbarItem] = []
    private var overflowActions: [SelectionAction] = []
    /// Where the panel was last placed, so a state change can re-present at the same anchor after the
    /// panel changes size.
    private var lastPresentedRect: CGRect?
    /// True while one of this panel's menus is open. `Menu` is a native SwiftUI menu now, so this is
    /// tracked by the panel losing key rather than by bracketing a modal `popUp` call.
    private(set) var isMenuOpen = false

    /// Whether the pointer is over the panel. Checked against the frame rather than with a tracking
    /// area, because the hosting view's own SwiftUI hover handling already owns the inside.
    var isPointerInside: Bool {
        isVisible && frame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn by SwiftUI, into the padding the view reserves for it. A window shadow
        // as well would double it and would not follow the rounded corners.
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false

        let surface = NSVisualEffectView()
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.cornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        // The high-contrast hairline that separates the panel from a dark background. Drawn on a
        // sublayer rather than as a border on `surface` so `masksToBounds` cannot clip it to half
        // width on the outer edge.
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            stack.topAnchor.constraint(equalTo: surface.topAnchor),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        contentView = surface
        self.surface = surface
        render()
    }

    // MARK: - State

    private func render() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch state {
        case let .actions(entries):
            for entry in entries {
                stack.addArrangedSubview(button(for: entry))
            }
            stack.addArrangedSubview(iconButton("xmark", action: #selector(closeTapped), label: "Dismiss"))

        case let .working(title):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
            stack.addArrangedSubview(label(title + "…", secondary: true))
            stack.addArrangedSubview(textButton("Cancel", action: #selector(cancelWork)))

        case let .result(text, canReplace):
            messageText = text
            stack.addArrangedSubview(label(text, secondary: false, wrapping: true))
            if canReplace {
                let replace = textButton("Replace", action: #selector(acceptResult))
                replace.keyEquivalent = "\r"
                stack.addArrangedSubview(replace)
            }
            stack.addArrangedSubview(textButton("Copy", action: #selector(copyMessage)))
            stack.addArrangedSubview(iconButton("xmark", action: #selector(closeTapped), label: "Dismiss"))

        case let .message(text):
            messageText = text
            stack.addArrangedSubview(label(text, secondary: true, wrapping: true))
            stack.addArrangedSubview(iconButton("xmark", action: #selector(closeTapped), label: "Dismiss"))
        }
        layoutIfNeeded()
    }

    private func button(for entry: SelectionToolbarEntry) -> NSButton {
        switch entry {
        case let .action(id, title):
            let button = ToolbarPillButton(title: title, symbolName: "")
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.target = self
            button.action = #selector(entryTapped(_:))
            return button

        case let .menu(id, title, _):
            // The chevron is the system symbol appended to the title, because `ToolbarPillButton`
            // draws a title and this is the one place the row needs to say "opens something" rather
            // than "does something".
            let button = ToolbarPillButton(title: title, symbolName: "chevron.down")
            button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            button.imagePosition = .imageTrailing
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.target = self
            button.action = #selector(entryTapped(_:))
            return button
        }
    }

    private func textButton(_ title: String, action: Selector) -> NSButton {
        let button = ToolbarPillButton(title: title, symbolName: "")
        button.target = self
        button.action = action
        return button
    }

    private func iconButton(_ symbol: String, action: Selector, label: String) -> NSButton {
        let button = ToolbarDismissButton()
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        return button
    }

    private func label(_ text: String, secondary: Bool, wrapping: Bool = false) -> NSTextField {
        let field = wrapping
            ? NSTextField(wrappingLabelWithString: text)
            : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .regular)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.isSelectable = wrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        if wrapping { field.preferredMaxLayoutWidth = 380 }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    @objc private func entryTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if id.hasPrefix("group.") {
            popMenu(for: id, from: sender)
        } else {
            select(id)
        }
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func cancelWork() { onCancel?() }

    @objc private func acceptResult() {
        guard let messageText else { return }
        onAcceptResult?(messageText)
    }

    @objc private func copyMessage() {
        guard let messageText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messageText, forType: .string)
        onClose?()
    }

    private var messageText: String?

    /// Pop the system menu for a group, at the pointer.
    ///
    /// Positioned at the mouse rather than under the button because the button is a SwiftUI view and
    /// its frame is not addressable from here — and for a menu opened by a click, the pointer is
    /// where the user is looking anyway.
    private func popMenu(for id: String, from sender: NSButton) {
        let actions: [SelectionAction]
        if id == "group.more" {
            actions = overflowActions
        } else {
            let name = String(id.dropFirst("group.".count))
            actions = visibleItems.compactMap { item -> ActionGroup? in
                if case let .group(group) = item, group.name == name { return group }
                return nil
            }.first?.actions ?? []
        }
        guard !actions.isEmpty else { return }

        menuActions = actions
        let menu = NSMenu()
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }

        isMenuOpen = true
        defer { isMenuOpen = false }   // popUp is modal and does not return until the menu closes
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuActions.count else { return }
        let action = menuActions[sender.tag]
        RewriteLog.write("menuSelected \(action.id)")
        onAction?(action)
    }

    /// Backing store for whichever menu is open, so a selected item maps back to an action.
    private var menuActions: [SelectionAction] = []

    /// Maps a toolbar id back to the action it stands for. Ids rather than indices, because a menu
    /// item and a top-level button now come back through the same callback and an index would have to
    /// encode which list it came from.
    private func select(_ id: String) {
        let everything = visibleItems.flatMap { item -> [SelectionAction] in
            switch item {
            case let .action(action): return [action]
            case let .group(group): return group.actions
            }
        } + overflowActions
        guard let action = everything.first(where: { $0.id == id }) else { return }
        RewriteLog.write("actionSelected \(action.id)")
        onAction?(action)
    }

    /// Rebuild the row for this selection. Runs before every presentation, because the right actions
    /// for a URL are not the right actions for a paragraph.
    func setActions(_ ranked: RankedActions) {
        visibleItems = ranked.items
        overflowActions = ranked.overflow

        var entries: [SelectionToolbarEntry] = ranked.items.map { item in
            switch item {
            case let .action(action):
                return .action(id: action.id, title: action.title)
            case let .group(group):
                return .menu(
                    id: "group.\(group.name)",
                    title: group.name,
                    items: group.actions.map { .action(id: $0.id, title: $0.title) }
                )
            }
        }
        if !ranked.overflow.isEmpty {
            entries.append(.menu(
                id: "group.more",
                title: "More",
                items: ranked.overflow.map { .action(id: $0.id, title: $0.title) }
            ))
        }
        state = .actions(entries)
        render()
    }

    func showWorking(_ title: String) {
        state = .working(title: title)
        render()
        represent()
    }

    func showResult(_ text: String, canReplace: Bool) {
        state = .result(text: text, canReplace: canReplace)
        render()
        represent()
    }

    func showMessage(_ text: String) {
        state = .message(text)
        render()
        represent()
    }

    /// Busy is now a state rather than a spinner bolted onto the row, so this only has to stop the
    /// row accepting clicks while a fast action runs.
    func setBusy(_ value: Bool) {
        ignoresMouseEvents = value
    }

    private func represent() {
        guard let rect = lastPresentedRect else { return }
        present(aboveScreenRect: rect)
    }

    /// Must be true, or the buttons are decorative: a borderless `.nonactivatingPanel` that refuses
    /// key status never routes a click through to its controls, so `NSButton`'s action never fires.
    /// `.nonactivatingPanel` still keeps the *app* from activating, which is the property actually
    /// wanted here — the user stays in their document.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Deliberately quieter than the actions: borderless, secondary tint, no title. It is an escape
    /// hatch, not a third thing to consider doing.
    
    
    // MARK: - Placement

    func present(aboveScreenRect rect: CGRect) {
        lastPresentedRect = rect
        layoutIfNeeded()
        setContentSize(stack.fittingSize)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint(rect.origin)) }) ?? NSScreen.main else { return }
        let panelSize = frame.size

        // The window is larger than the panel the user sees, by the margin `SelectionToolbarView`
        // reserves for its drop shadow — a SwiftUI shadow renders inside its own bounds and would
        // otherwise be clipped away. Every measurement below is of the *visible* box, so the inset is
        // taken back out before positioning.
        let inset: CGFloat = 0
        let visible = CGSize(width: panelSize.width - inset * 2, height: panelSize.height - inset * 2)

        // Enough clearance that the panel never sits on the line above the selection. A 6pt gap
        // from a 27pt caret rect put it straight through the previous line of text.
        let gap: CGFloat = 12

        // Quartz → AppKit is flipped about the **primary** display's top edge, always. The previous
        // version flipped about `screen.frame.maxY` — the maxY of whichever screen the selection was
        // on — which is the same number only when that screen *is* the primary. On a display mounted
        // above the primary, Accessibility reports negative Quartz coordinates, the two frames no
        // longer agree, and the panel was placed thousands of points off the top of the screen. It
        // was not missing; it was somewhere nobody could see. The found screen is still used, but
        // only for clamping.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let selectionTop = primaryMaxY - rect.minY        // AppKit y of the selection's top edge
        let selectionBottom = primaryMaxY - rect.maxY     // AppKit y of its bottom edge

        var y = selectionTop + gap - inset                                    // above the selection
        if selectionTop + gap + visible.height > screen.frame.maxY {          // no room above → below
            y = selectionBottom - gap - visible.height - inset
        }
        var x = rect.midX - visible.width / 2 - inset
        x = min(max(x, screen.frame.minX + 4 - inset), screen.frame.maxX - visible.width - 4 - inset)
        setFrameOrigin(NSPoint(x: x, y: y))
        setBusy(false)
        animateIn(to: NSPoint(x: x, y: y))
        orderFrontRegardless()
        RewriteLog.write("popover presented at x=\(Int(x)) y=\(Int(y))")
    }

    /// The same entrance the suggestion capsule uses: a short rise into place, fading in, no
    /// overshoot. Matching them is the point — these are the app's two floating surfaces and they
    /// should behave identically, not merely look similar.
    ///
    /// Done on the window rather than in SwiftUI because this panel's content is AppKit; animating
    /// `alphaValue` and the frame origin is the equivalent gesture.
    private func animateIn(to origin: NSPoint) {
        guard !isVisible else { return }   // re-presenting for a grown selection should not re-animate
        alphaValue = 0
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y - SuggestionStyle.entranceOffset))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SuggestionStyle.entranceDuration
            context.timingFunction = SuggestionStyle.entranceTimingFunction
            animator().alphaValue = 1
            animator().setFrameOrigin(origin)
        }
    }

    private func appKitPoint(_ quartz: CGPoint) -> NSPoint {
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: quartz.x, y: maxY - quartz.y)
    }
}

// MARK: - Controller

/// Watches the focused-field tracker for a stable selection and drives the popover + rewrite +
/// replacement. Isolated from the completion pipeline; reads/writes the selection via AX directly.
@MainActor
final class SelectionRewriteController {
    private let tracker: AccessibilityContextTracker
    private let modelFilenameProvider: () -> String
    private let isEnabledProvider: () -> Bool
    /// Performs the rewrite, whichever engine the user has chosen. Injected as a closure so this
    /// file stays unaware that backends exist — the branching lives in one obvious place in
    /// AppDelegate rather than being threaded through the popover's state machine.
    private let rewriteText: (String, CloudRewriteStyle) async -> Result<String, Error>
    /// Shared with the inline grammar pass (`ModelSentenceRewriter`) so both features drive one
    /// llama context. The actor also serializes them, so the two can never run an eval at once.
    private let service: RewriteService
    private let popover = SelectionRewritePopover()
    /// The user's action arrangement: built-ins, their own, and what they pinned or turned off.
    /// Injected so the Settings pane and the toolbar are looking at the same store — otherwise an
    /// edit would not reach the toolbar until the next launch.
    let actionStore: ActionStore
    private let ranker = ActionRanker()
    private let modelResponder: ActionRunner.ModelResponder
    private let allowsCodeExecution: () -> Bool

    /// Built per run, not once at init. The policy is enforced at execution rather than at display,
    /// so turning "allow commands and scripts" on takes effect on the next click instead of the next
    /// launch — which was not true when the flag was read once into a stored runner.
    private var runner: ActionRunning {
        ActionRunner(
            policy: ExecutionPolicy(allowsCodeExecution: allowsCodeExecution()),
            model: modelResponder
        )
    }
    private let log = Logger(subsystem: "com.pattonium.KeyType", category: "rewrite")

    private var pollTimer: Timer?
    private var isBusy = false

    /// Selection text the popover is currently shown for (avoids re-presenting every poll).
    private var shownSelection: String?
    /// Consecutive polls with no selection while the popover is shown (debounces flickery reads).
    private var emptyPolls = 0
    /// App the popover is currently shown for — dismiss if focus moves to a different app.
    private var shownBundle: String?
    /// Global hotkey CGEventTap (⌃⌥P / ⌃⌥G) — the universal trigger.
    private var hotkeyTap: CFMachPort?
    private var hotkeyRunLoopSource: CFRunLoopSource?
    /// Cached so the action uses the selection that was live when the popover appeared.
    private var pendingText: String?
    /// The same selection, with its detected properties, so an action does not recompute them.
    private var pendingContext: SelectionContext?
    /// Set when the selection was obtained by ⌘C rather than read through Accessibility. An app that
    /// would not expose its selection will not accept an accessibility write either, so the result
    /// has to go back as a paste.
    private var replacesByPasting = false
    /// The action currently running, so Cancel has something to cancel.
    private var runningWork: Task<Void, Never>?

    private let minSelectionLength = 3

    /// Identity of a selection for "is this still the same thing?" purposes. Whitespace-insensitive,
    /// because that is exactly what differs between two reads of an unchanged selection.
    static func selectionKey(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Longest the popover may stay up without the normal rules having dismissed it.
    ///
    /// Every dismissal path used to live *after* an early return in `poll()` — one for a rewrite in
    /// flight, one for our own app holding focus — so either could leave the popover on screen
    /// permanently, with no way for the user to close it. This cap is checked before anything else
    /// and cannot be skipped, so "stuck forever" is structurally impossible rather than merely
    /// unlikely.
    private static let maximumVisibleSeconds: TimeInterval = 15
    private var shownAt: Date?

    /// Consecutive polls in which Glide itself held focus. The exemption exists so the popover
    /// survives its own panel briefly taking focus; unbounded, opening any Glide window (Settings,
    /// Your Glide) froze the popover on screen for good.
    private var glideFocusPolls = 0
    private static let maximumGlideFocusPolls = 3

    init(
        tracker: AccessibilityContextTracker,
        service: RewriteService = RewriteService(),
        modelFilenameProvider: @escaping () -> String,
        isEnabledProvider: @escaping () -> Bool = { true },
        allowsCodeExecution: @escaping () -> Bool = { false },
        actionStore: ActionStore = ActionStore(),
        rewriteText: @escaping (String, CloudRewriteStyle) async -> Result<String, Error>
    ) {
        self.tracker = tracker
        self.service = service
        self.modelFilenameProvider = modelFilenameProvider
        self.isEnabledProvider = isEnabledProvider
        self.rewriteText = rewriteText
        self.actionStore = actionStore
        self.allowsCodeExecution = allowsCodeExecution
        // Every prompt action reaches the configured engine through the same closure the two
        // built-in styles already used, as a `.custom` instruction. That keeps provider plumbing,
        // retries and rate-limit reporting in one place instead of once per action.
        self.modelResponder = { instruction, fewShot, text in
            let spec = RewriteInstruction(
                instruction: instruction,
                fewShotHeader: fewShot?.header,
                examples: (fewShot?.examples ?? []).map {
                    RewriteExample(original: $0.original, rewritten: $0.rewritten)
                }
            )
            switch await rewriteText(text, .custom(spec)) {
            case let .success(result): return result
            case let .failure(error): throw error
            }
        }
        popover.onAction = { [weak self] action in self?.perform(action) }
        popover.onAcceptResult = { [weak self] text in self?.acceptPreviewedResult(text) }
        popover.onCancel = { [weak self] in
            RewriteLog.write("action cancelled by the user")
            self?.runningWork?.cancel()
            self?.runningWork = nil
            self?.isBusy = false
            self?.hide()
        }
        popover.onClose = { [weak self] in
            RewriteLog.write("close button: dismissed")
            self?.hide()
        }
    }

    // We don't rely on the shared context tracker for selection detection (it only reliably fires on
    // focus/typing changes, not selection-only changes in many apps). Instead we poll the focused
    // AX element's selected text directly — self-contained and works everywhere AX is exposed.
    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Universal trigger: a CGEventTap hotkey works in every app (including Chromium/Electron
        // apps that don't expose their selection to Accessibility). ⌃⌥P = polish, ⌃⌥G = grammar.
        // (A CGEventTap works under the same permission that drives autocomplete; an NSEvent global
        // monitor would need separate Input Monitoring permission.)
        installHotkeyTap()
        RewriteLog.write("SelectionRewriteController.start: polling + hotkeys (⌃⌥P / ⌃⌥G)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        removeHotkeyTap()
        hide()
    }

    // MARK: - Hotkey CGEventTap

    private func installHotkeyTap() {
        guard hotkeyTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.hotkeyCallback, userInfo: refcon
        ) else {
            RewriteLog.write("hotkey tap: FAILED to create")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hotkeyTap = tap
        hotkeyRunLoopSource = src
    }

    private func removeHotkeyTap() {
        if let tap = hotkeyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = hotkeyRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        }
        hotkeyTap = nil
        hotkeyRunLoopSource = nil
    }

    fileprivate func reEnableHotkeyTap() {
        if let tap = hotkeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// ⌃⌥A — open the action list for the current selection in **any** app.
    ///
    /// The polling path can only offer actions where Accessibility reports a selection, and plenty of
    /// apps never do: Millie logs `snapSel=-1 rawSel=-1` on every tick. In those the toolbar simply
    /// never appears, which means a user's own actions are unreachable exactly where they may most
    /// want them. This route asks the app for its selection with ⌘C instead, which works everywhere,
    /// and it is why custom actions can be described as available in every app rather than in most.
    ///
    /// The trade is that the result has to go back the same way — a paste, not an accessibility write
    /// — because an app that would not tell us what was selected will not let us set it either.
    fileprivate func actionsHotkeyPressed() {
        guard isEnabledProvider(), !isBusy else { return }
        hide()
        isBusy = true

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let beforeCount = pasteboard.changeCount

        Task { @MainActor in
            // The user is still holding ⌃⌥. Sending ⌘C now would arrive as ⌃⌥⌘C, which is not copy.
            var waited = 0
            while !NSEvent.modifierFlags.intersection([.control, .option]).isEmpty, waited < 20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            Self.synthCmd(keyCode: 8) // ⌘C
            try? await Task.sleep(nanoseconds: 180_000_000)

            defer { isBusy = false }
            guard pasteboard.changeCount != beforeCount,
                  let copied = pasteboard.string(forType: .string),
                  !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                RewriteLog.write("actions hotkey: nothing selected")
                if let saved { pasteboard.clearContents(); pasteboard.setString(saved, forType: .string) }
                return
            }
            if let saved { pasteboard.clearContents(); pasteboard.setString(saved, forType: .string) }

            let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let context = SelectionContext(text: copied, bundleIdentifier: bundle)
            let ranked = ranker.rank(
                actionStore.allActions,
                for: context,
                preferences: actionStore.preferences,
                usage: actionStore.usage
            )
            guard !ranked.isEmpty else {
                RewriteLog.write("actions hotkey: no eligible actions")
                return
            }
            RewriteLog.write("actions hotkey: \(ranked.items.count) items for \(copied.count) chars in \(bundle ?? "?")")
            pendingText = copied
            pendingContext = context
            replacesByPasting = true
            shownAt = Date()
            shownBundle = bundle
            popover.setActions(ranked)
            popover.present(aboveScreenRect: Self.mouseRectQuartz())
        }
    }

    fileprivate func hotkeyPressed(_ style: CloudRewriteStyle) {
        guard isEnabledProvider() else { return }
        handleHotkey(style)
    }

    private nonisolated static let hotkeyCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let ptrValue = UInt(bitPattern: refcon)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                if let p = UnsafeMutableRawPointer(bitPattern: ptrValue) {
                    Unmanaged<SelectionRewriteController>.fromOpaque(p).takeUnretainedValue().reEnableHotkeyTap()
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Escape closes the popover. Passed through rather than swallowed: Escape almost always
        // means something in the app the user is working in, and stealing it would be a worse bug
        // than the one this fixes.
        if keyCode == 53 {
            MainActor.assumeIsolated {
                if let p = UnsafeMutableRawPointer(bitPattern: ptrValue) {
                    Unmanaged<SelectionRewriteController>.fromOpaque(p).takeUnretainedValue().dismissFromEscape()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let hasCtrlOpt = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        let hasOther = flags.contains(.maskCommand) || flags.contains(.maskShift)
        guard hasCtrlOpt, !hasOther, keyCode == 35 || keyCode == 5 || keyCode == 0 else {
            return Unmanaged.passUnretained(event)
        }
        MainActor.assumeIsolated {
            guard let p = UnsafeMutableRawPointer(bitPattern: ptrValue) else { return }
            let controller = Unmanaged<SelectionRewriteController>.fromOpaque(p).takeUnretainedValue()
            if keyCode == 0 {
                controller.actionsHotkeyPressed()
            } else {
                controller.hotkeyPressed(keyCode == 35 ? .polish : .grammar)
            }
        }
        return nil // swallow ⌃⌥P / ⌃⌥G / ⌃⌥A so the focused app doesn't also receive them
    }

    func shutdown() async {
        await service.shutdown()
    }

    // MARK: - Selection detection (AX poll)

    private var lastHeartbeat = ""

    private func poll() {
        // Checked first, deliberately: every other dismissal rule sits behind a guard that can
        // return early, and the one thing worse than a missed suggestion is an overlay the user
        // cannot get rid of.
        if let shownAt, Date().timeIntervalSince(shownAt) > Self.maximumVisibleSeconds {
            RewriteLog.write("poll: dismissed by the visibility cap")
            hide()
            return
        }

        guard !isBusy, isEnabledProvider() else { return }

        // Two sources for the selection — the shared tracker (drills to the real text element,
        // which is why autocomplete works) and a raw system-wide AX read. Prefer whichever has it.
        let snap = tracker.currentSnapshot
        let snapSel = snap?.context.selection.selectedText
        let rawEl = AX.focusedElement()
        let rawSel = rawEl.flatMap { AX.string($0, kAXSelectedTextAttribute) }
        let bundle = snap?.context.target.bundleIdentifier ?? rawEl.flatMap { AX.bundleID($0) }

        let selected = (snapSel?.isEmpty == false ? snapSel : nil) ?? (rawSel?.isEmpty == false ? rawSel : nil) ?? ""
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)

        let hb = "snapSel=\(snapSel?.count ?? -1) rawSel=\(rawSel?.count ?? -1) bundle=\(bundle ?? "?")"
        if hb != lastHeartbeat { RewriteLog.write("poll hb: \(hb)"); lastHeartbeat = hb }

        if snap?.context.traits.isSecureTextEntry == true { hide(); return }
        // If focus moved to a *different* app than the one the popover is shown for, dismiss now.
        if shownSelection != nil, let bundle, let shown = shownBundle, bundle != shown,
           !bundle.hasPrefix("app.glide") {
            hide(); return
        }
        if let bundle, bundle.hasPrefix("app.glide") {
            // Brief self-focus is the popover itself; sustained self-focus means the user has moved
            // to a Glide window and is no longer editing the text this was offered for.
            glideFocusPolls += 1
            if glideFocusPolls <= Self.maximumGlideFocusPolls { return }
            RewriteLog.write("poll: dismissed — focus stayed on Glide")
            hide()
            return
        }
        glideFocusPolls = 0

        guard trimmed.count >= minSelectionLength else {
            // The selection read flickers badly in web/Electron apps (reported once, then -1).
            // Keep the popover up so the user can actually click it: don't dismiss while the mouse
            // is over it, and only after the selection has been gone for ~5s.
            if shownSelection != nil {
                if popover.frame.contains(NSEvent.mouseLocation) {
                    emptyPolls = 0
                } else {
                    emptyPolls += 1
                    if emptyPolls >= 12 { hide() } // ~5s grace before dismissing
                }
            }
            return
        }
        emptyPolls = 0

        // Compared on a normalised key, not the raw string. Web and Electron apps return the same
        // selection with and without a trailing newline between one read and the next, so an exact
        // comparison saw a *change* every few hundred milliseconds and re-anchored the panel — which
        // is what "it keeps moving around while I'm interacting" is.
        if Self.selectionKey(selected) == shownSelection.map(Self.selectionKey) { return }

        // A visible panel does not move under the pointer. Even a genuine selection change should not
        // reposition a toolbar the user is currently reaching for; the system's own selection callout
        // stays put until it is dismissed. The panel is left exactly as it is and the poll tries again
        // once the pointer leaves.
        if popover.isVisible, popover.isPointerInside || popover.isMenuOpen { return }

        // Anchor: tracker caret/field rect, else the raw selection/element rect. Some apps
        // (Electron/web) return a degenerate zero-size rect — fall back to the mouse location so
        // the popover appears where the user just dragged.
        // The *selection's* bounds first. The caret rect was tried first before, which for a
        // selection is a 2pt-wide sliver at one end — so the panel was centred on the caret and
        // anchored to a line the selection might not even start on, which is how it ended up over
        // the user's text.
        let candidate = rawEl.flatMap { AX.selectionRect($0) }
            ?? snap?.caretRect
            ?? snap?.context.geometry.fieldRect
            ?? rawEl.flatMap { AX.frame($0) }
        let rect: CGRect
        if let candidate, candidate.width > 1, candidate.height > 1 {
            rect = candidate
        } else {
            rect = Self.mouseRectQuartz()
        }

        RewriteLog.write("poll: show popover sel.len=\(trimmed.count) rect=\(NSStringFromRect(rect))")
        shownSelection = selected
        shownBundle = bundle
        shownAt = Date()
        pendingText = selected

        // Ranked per presentation, not once at launch: the right actions for a URL are not the right
        // actions for a paragraph, and that is the whole point of the ranker.
        let actionContext = SelectionContext(text: selected, bundleIdentifier: bundle)
        let ranked = ranker.rank(
            actionStore.allActions,
            for: actionContext,
            preferences: actionStore.preferences,
            usage: actionStore.usage
        )
        guard !ranked.isEmpty else {
            RewriteLog.write("poll: no eligible actions for this selection — not presenting")
            return
        }
        pendingContext = actionContext
        popover.setActions(ranked)
        popover.present(aboveScreenRect: rect)
    }

    private func hide() {
        shownSelection = nil
        shownBundle = nil
        shownAt = nil
        emptyPolls = 0
        glideFocusPolls = 0
        pendingText = nil
        pendingContext = nil
        replacesByPasting = false
        popover.orderOut(nil)
    }

    /// Escape dismisses the popover. It had no user-facing dismissal at all — no key, no click-away,
    /// no close button — so when the automatic rules failed there was nothing the user could do.
    fileprivate func dismissFromEscape() {
        guard popover.isVisible else { return }
        RewriteLog.write("escape: dismissed")
        hide()
    }

    /// Current mouse location as a small Quartz-space (top-left origin) rect, used to anchor the
    /// popover when the app gives no usable selection rect.
    private static func mouseRectQuartz() -> CGRect {
        let loc = NSEvent.mouseLocation // AppKit bottom-left origin
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        let quartzY = maxY - loc.y
        // A small rect above which the popover will sit.
        return CGRect(x: loc.x, y: quartzY - 18, width: 1, height: 18)
    }

    // MARK: - Action

    /// Universal hotkey path: copy the current selection via ⌘C (works in every app, unlike AX
    /// selection reads), rewrite it, and paste it back via ⌘V — restoring the user's clipboard.
    private func handleHotkey(_ style: CloudRewriteStyle) {
        guard !isBusy else { return }
        hide() // drop any popover; the hotkey is the active path now
        isBusy = true
        RewriteLog.write("hotkey \(style)")

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let beforeCount = pb.changeCount
        Task { @MainActor in
            // The user is still holding ⌃⌥ from the hotkey. If we send ⌘C now the OS sees ⌃⌥⌘C
            // (not copy). Wait for the modifiers to be released first (cap ~1s).
            var waited = 0
            while !NSEvent.modifierFlags.intersection([.control, .option]).isEmpty, waited < 20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            Self.synthCmd(keyCode: 8) // ⌘C
            try? await Task.sleep(nanoseconds: 180_000_000) // let the copy land
            guard pb.changeCount != beforeCount,
                  let copied = pb.string(forType: .string),
                  !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                RewriteLog.write("hotkey: nothing selected/copied")
                isBusy = false
                return
            }
            let outcome = await rewriteText(copied, style)
            guard case let .success(result) = outcome, !result.isEmpty else {
                if case let .failure(error) = outcome {
                    RewriteLog.write("hotkey: failed — \(error.localizedDescription)")
                } else {
                    RewriteLog.write("hotkey: no rewrite result")
                }
                if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
                isBusy = false
                return
            }
            pb.clearContents()
            pb.setString(result, forType: .string)
            Self.synthCmd(keyCode: 9) // ⌘V — replaces the selection
            RewriteLog.write("hotkey: pasted \(RewriteLog.text(result))")
            // Restore the user's clipboard once the paste has been consumed.
            try? await Task.sleep(nanoseconds: 250_000_000)
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
            isBusy = false
        }
    }

    /// Post a ⌘+<key> keystroke to the frontmost app.
    private static func synthCmd(keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func perform(_ action: SelectionAction) {
        guard let context = pendingContext, !isBusy else {
            RewriteLog.write("perform ignored: context=\(pendingContext != nil) isBusy=\(isBusy)")
            return
        }
        isBusy = true
        RewriteLog.write("perform \(action.id) kind=\(action.kind.label) textLen=\(context.text.count)")

        // A model call takes seconds; a transform takes none. Only the slow one gets a progress
        // surface, because flashing "Working on it…" for something already finished is worse than
        // showing nothing.
        if action.sideEffects == .sendsTextToModel {
            popover.showWorking(action.title)
        } else {
            popover.setBusy(true)
        }

        let work = Task { @MainActor in
            defer {
                self.isBusy = false
                self.popover.setBusy(false)
                self.runningWork = nil
            }
            do {
                let result = try await self.runner.run(action, on: context)
                try Task.checkCancellation()
                self.actionStore.recordUse(of: action.id)
                self.apply(result, from: action)
            } catch is CancellationError {
                RewriteLog.write("action \(action.id) cancelled")
                self.hide()
            } catch {
                RewriteLog.write("action \(action.id) failed — \(error.localizedDescription)")
                self.popover.showMessage(error.localizedDescription)
            }
        }
        runningWork = work
    }

    /// What to do with what the action produced. Only `.replaceSelection` touches the document; the
    /// others deliberately leave it alone, which is why "Explain" and "Count" are safe to run on
    /// something you are in the middle of writing.
    @MainActor
    private func apply(_ result: ActionResult, from action: SelectionAction) {
        // Model output is a suggestion, not a certainty. Show it and let the user decide, rather than
        // rewriting their sentence and leaving undo as the only way to see what it used to say.
        // Deterministic transforms apply straight away — confirming "UPPERCASE" is friction with
        // nothing on the other side of it.
        if result.output == .replaceSelection, action.sideEffects == .sendsTextToModel {
            popover.showResult(result.text, canReplace: true)
            return
        }

        switch result.output {
        case .replaceSelection:
            let ok = replacesByPasting
                ? Self.pasteOverSelection(with: result.text)
                : Self.replaceSelection(with: result.text)
            RewriteLog.write("replaceSelection paste=\(replacesByPasting) ok=\(ok)")
            hide()

        case .copyToClipboard:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            RewriteLog.write("copied \(result.text.count) chars")
            hide()

        case .openURL:
            guard let url = URL(string: result.text) else {
                popover.showMessage("That doesn't look like a URL.")
                return
            }
            NSWorkspace.shared.open(url)
            RewriteLog.write("opened \(url.scheme ?? "?") URL")
            hide()

        case .preview:
            // Stays up. The user asked to be told something, so dismissing on success would throw
            // away the answer they asked for.
            popover.showResult(result.text, canReplace: false)
        }
    }

    /// Apply a result the user accepted from the preview.
    @MainActor
    private func acceptPreviewedResult(_ text: String) {
        let ok = replacesByPasting
            ? Self.pasteOverSelection(with: text)
            : Self.replaceSelection(with: text)
        RewriteLog.write("accepted preview paste=\(replacesByPasting) ok=\(ok)")
        hide()
    }

    /// How long to wait for an accessibility write to show up in the field's value before treating
    /// it as dropped. Generous next to the ~75ms a Chromium field was measured to take, because the
    /// cost of waiting is a brief pause and the cost of giving up early is the text pasted twice.
    private static let axWriteVerifyTimeout: TimeInterval = 0.4
    private static let axWriteVerifyPoll: TimeInterval = 0.02

    /// Replace the active selection with `newText`. We try the AX `AXSelectedText` setter first
    /// (clean, works in standard NSTextField/NSTextView), then fall back to a clipboard paste —
    /// which replaces the highlighted selection regardless of the app's AX hierarchy (Notes, etc.,
    /// where the focused element isn't the text element). The clipboard is saved and restored.
    /// Replace the selection by pasting, skipping the accessibility tier entirely.
    ///
    /// Used by the ⌃⌥A route, where the selection was obtained with ⌘C precisely because the app does
    /// not expose one. Trying the accessibility write first there is not merely wasted — ADR-133
    /// showed a failed attempt can leave the field in a state that breaks what follows.
    private static func pasteOverSelection(with newText: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        synthCmd(keyCode: 9) // ⌘V
        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        return true
    }

    private static func replaceSelection(with newText: String) -> Bool {
        // Tier 1: direct AX set on the focused element — taken only when the field's value is
        // observed to change.
        //
        // `.success` from this setter is not evidence. Chromium returns it and silently discards the
        // write, so every web-rendered editor — Millie, Claude Desktop, Slack, Teams — used to report
        // a replacement that never happened, and the clipboard tier behind it never ran. That is the
        // same lie ADR-133 documents on the autocomplete side.
        //
        // The check has to be a poll rather than a single read: the same investigation measured a
        // Chromium field taking ~75ms to publish a change through Accessibility, so an immediate
        // comparison would call a successful write a failure and paste the text a second time.
        if let element = AX.focusedElement(),
           let before = AX.string(element, kAXValueAttribute as String),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, newText as CFString) == .success {
            var waited: TimeInterval = 0
            while waited < axWriteVerifyTimeout {
                if AX.string(element, kAXValueAttribute as String) != before { return true }
                Thread.sleep(forTimeInterval: axWriteVerifyPoll)
                waited += axWriteVerifyPoll
            }
            // Reported success, changed nothing. Fall through and paste it.
        }

        // Tier 2: clipboard paste over the selection (universal).
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(newText, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Restore the user's clipboard shortly after the paste has been consumed.
        if let saved {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
        return true
    }
}

// MARK: - AX helpers

/// Minimal Accessibility readers for selection detection + placement.
private enum AX {
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return s
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    static func bundleID(_ element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Screen rect (Quartz / top-left origin) of the current selection, via AXBoundsForRange.
    static func selectionRect(_ element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rv = rangeValue, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &cfRange), cfRange.length > 0 else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &boundsValue) == .success,
              let bv = boundsValue, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect), !rect.isNull, rect.width.isFinite else { return nil }
        return rect
    }

    /// Element frame in screen coords (Quartz / top-left), as a placement fallback.
    static func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef,
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
