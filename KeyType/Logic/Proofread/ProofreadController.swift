//
//  ProofreadController.swift
//  Glide
//
//  The rewrite path's controller: watches the same focused-field snapshots the completion pipeline
//  does, asks the proofreader about the word the user just finished, and offers the fix as a capsule
//  under the caret that Tab applies.
//
//  Deliberately isolated from `CompletionController`, for the same reason `SelectionRewrite` is: that
//  controller owns a single KV-cache runtime and a large amount of state tuned for constrained
//  decoding, and a spelling fix has nothing to do with any of it. The two paths meet in exactly one
//  place — the acceptance tap — where completion always wins the Tab key and the rewrite is offered
//  only when no completion is on screen. That ordering is what keeps them from fighting.
//
//  Everything here is cheap: no model, no network, a spell check per word boundary.
//

import AppCompatibility
import AppKit
import AutocompleteCore
import CompletionUI
import MacContextCapture
import Proofreading
import TextInsertion
import os

@MainActor
final class ProofreadController {
    private let tracker: AccessibilityContextTracker
    private let proofreader: any SentenceRewriting
    private let replacer: any TextReplacing
    private let overlay: GhostTextOverlayWindow
    private let placementResolver: OverlayPlacementResolver
    private let compatibilityStore: AppCompatibilityStore
    private let log = Logger(subsystem: "app.glide", category: "proofread")

    /// User-facing on/off switch. Off clears anything pending immediately.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled, !isEnabled else { return }
            dismiss()
        }
    }

    /// Injected by the app so the rewrite never competes with a visible completion for Tab.
    var isCompletionVisible: () -> Bool = { false }

    /// The suggestion currently on screen. The context it was built from is deliberately not kept:
    /// acceptance re-reads the live caret instead, because the user keeps typing while it is up.
    private var pending: RewriteSuggestion?
    private var listenerToken: UUID?
    private var evaluationTask: Task<Void, Never>?
    private var isApplying = false
    /// Text the current suggestion was computed from. AX emits several snapshots per keystroke
    /// (caret moves, window changes, value echoes); without this the model would be asked the same
    /// question repeatedly and the capsule would flicker off and back on between answers.
    private var lastEvaluatedText: String?

    init(
        tracker: AccessibilityContextTracker,
        proofreader: any SentenceRewriting,
        replacer: any TextReplacing,
        overlay: GhostTextOverlayWindow = GhostTextOverlayWindow(),
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()
    ) {
        self.tracker = tracker
        self.proofreader = proofreader
        self.replacer = replacer
        self.overlay = overlay
        self.compatibilityStore = compatibilityStore
        self.placementResolver = OverlayPlacementResolver(compatibilityStore: compatibilityStore)
    }

    // MARK: - Lifecycle

    func start() {
        guard listenerToken == nil else { return }
        listenerToken = tracker.addListener { [weak self] snapshot in
            MainActor.assumeIsolated { self?.handle(snapshot) }
        }
    }

    func stop() {
        if let listenerToken {
            tracker.removeListener(listenerToken)
        }
        listenerToken = nil
        lastEvaluatedText = nil
        dismiss()
    }

    // MARK: - Pipeline

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        // Snapshots produced by our own replacement keystrokes would otherwise re-evaluate the text
        // we just wrote.
        guard !isApplying else { return }

        evaluationTask?.cancel()
        evaluationTask = nil

        guard isEnabled, let context = snapshot?.context else {
            dismiss()
            return
        }

        // Completion owns the caret and the Tab key whenever it has something to show.
        guard !isCompletionVisible() else {
            dismiss()
            return
        }

        let policy = compatibilityStore.policy(for: context)
        guard policy.isCompletionEnabled, policy.allowsTabAcceptance else {
            dismiss()
            return
        }
        guard !(policy.excludesSecureField && context.traits.isSecureTextEntry) else {
            dismiss()
            return
        }

        // A snapshot that changed nothing about the text leaves the current suggestion alone.
        if lastEvaluatedText == context.beforeCursor, pending != nil { return }

        // Nothing pending survives a real context change; the span it referred to may be gone.
        dismiss()
        lastEvaluatedText = context.beforeCursor

        evaluationTask = Task { [weak self] in
            guard let self else { return }
            let suggestion = await self.proofreader.suggestion(for: context)
            guard !Task.isCancelled, let suggestion, suggestion.isMeaningful else { return }
            self.present(suggestion, for: context)
        }
    }

    private func present(_ suggestion: RewriteSuggestion, for context: TextFieldContext) {
        guard var placement = placementResolver.placement(for: context, mode: .correction) else { return }
        placement.presentation = .capsule

        pending = suggestion
        overlay.show(
            text: Self.displayText(for: suggestion),
            font: .systemFont(ofSize: NSFont.systemFontSize),
            placement: placement
        )
        log.debug("Offering rewrite: \(suggestion.span.original, privacy: .private) → \(suggestion.replacement, privacy: .private)")
    }

    /// The capsule shows the replacement as it will land, minus the trailing boundary the span
    /// carries so it ends at the caret — rendering "receive " with its space reads as a typo of its
    /// own. Nothing is truncated: the sentence scanner is bounded so a model rewrite always fits,
    /// because accepting text you cannot fully read is worse than not being offered it.
    static func displayText(for suggestion: RewriteSuggestion) -> String {
        suggestion.replacement.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Acceptance

    /// True when there is a rewrite the user can apply with Tab.
    var canAcceptRewrite: Bool {
        pending != nil && isEnabled && !isCompletionVisible()
    }

    func acceptRewrite() {
        guard let pending else { return }
        self.pending = nil
        overlay.hide()

        // The field may have moved on between the suggestion being offered and Tab being pressed.
        // Re-read the caret rather than trusting the snapshot the suggestion was built from; the AX
        // replacer verifies the span again before writing, and the keystroke fallbacks cannot.
        guard let live = tracker.currentSnapshot?.context,
              live.beforeCursor.hasSuffix(pending.span.original)
        else {
            log.debug("Rewrite abandoned: the text behind the caret changed before acceptance")
            return
        }

        let plan = replacer.planReplacement(
            span: pending.span,
            replacement: pending.replacement,
            context: live
        )

        // Our own replacement keystrokes come back as snapshots; ignore them until the write is done.
        isApplying = true
        Task { [weak self] in
            defer { self?.isApplying = false }
            do {
                guard let outcome = try await self?.replacer.replace(plan: plan) else { return }
                self?.logOutcome(outcome)
            } catch {
                self?.logFailure(error)
            }
        }
    }

    func dismiss() {
        evaluationTask?.cancel()
        evaluationTask = nil
        guard pending != nil else { return }
        pending = nil
        overlay.hide()
    }

    private func logOutcome(_ outcome: ReplacementOutcome) {
        switch outcome {
        case let .applied(mechanism):
            log.debug("Rewrite applied via \(String(describing: mechanism), privacy: .public)")
        case .skipped:
            log.debug("Rewrite skipped at the replacer")
        }
    }

    private func logFailure(_ error: Error) {
        log.error("Rewrite failed: \(error.localizedDescription, privacy: .public)")
    }
}
