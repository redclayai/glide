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

    private var pending: Pending?
    private var listenerToken: UUID?
    private var evaluationTask: Task<Void, Never>?
    private var isApplying = false

    private struct Pending {
        let suggestion: RewriteSuggestion
        let context: TextFieldContext
    }

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
        dismiss()
    }

    // MARK: - Pipeline

    private func handle(_ snapshot: FocusedFieldSnapshot?) {
        // Our own replacement keystrokes generate snapshots. Ignore them, or applying a fix would
        // immediately re-evaluate the text we just wrote.
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

        // Nothing pending survives a context change; the span it referred to may be gone.
        dismiss()

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

        pending = Pending(suggestion: suggestion, context: context)
        overlay.show(
            text: Self.displayText(for: suggestion),
            font: .systemFont(ofSize: NSFont.systemFontSize),
            placement: placement
        )
        log.debug("Offering rewrite: \(suggestion.span.original, privacy: .private) → \(suggestion.replacement, privacy: .private)")
    }

    /// The capsule shows the corrected word alone. The replacement carries the trailing boundary so
    /// the span ends at the caret, but rendering "receive " with its space reads as a typo of its own.
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
              live.beforeCursor.hasSuffix(pending.suggestion.span.original)
        else {
            log.debug("Rewrite abandoned: the text behind the caret changed before acceptance")
            return
        }

        let plan = replacer.planReplacement(
            span: pending.suggestion.span,
            replacement: pending.suggestion.replacement,
            context: live
        )

        isApplying = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.isApplying = false } }
            do {
                let outcome = try await self?.replacer.replace(plan: plan)
                await self?.logOutcome(outcome)
            } catch {
                await self?.logFailure(error)
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

    private func logOutcome(_ outcome: ReplacementOutcome?) {
        switch outcome {
        case let .applied(mechanism):
            log.debug("Rewrite applied via \(String(describing: mechanism), privacy: .public)")
        case .skipped:
            log.debug("Rewrite skipped at the replacer")
        case nil:
            break
        }
    }

    private func logFailure(_ error: Error) {
        log.error("Rewrite failed: \(error.localizedDescription, privacy: .public)")
    }
}
