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
    /// The same file the completion path writes to. Debug-level os_log is not persisted, so without
    /// this there was no way to see why a rewrite did or didn't appear — which is exactly the
    /// question that came up the first time the feature looked dead in a real app.
    private let predictionLog: PredictionLog?
    private let log = Logger(subsystem: "app.glide", category: "proofread")

    /// User-facing on/off switch. Off clears anything pending immediately.
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled, !isEnabled else { return }
            dismiss()
        }
    }

    /// Injected by the app so the rewrite can tell whether completion currently owns the caret.
    var isCompletionVisible: () -> Bool = { false }
    /// Clears a visible completion. Used only when a model grammar fix is ready: by then the user
    /// has paused for over a second, which says they have stopped composing, and a correction to
    /// what they wrote beats a guess at what comes next. The completion re-offers itself the moment
    /// they type again.
    var dismissCompletion: () -> Void = {}

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
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore(),
        predictionLog: PredictionLog? = nil
    ) {
        self.tracker = tracker
        self.proofreader = proofreader
        self.replacer = replacer
        self.overlay = overlay
        self.compatibilityStore = compatibilityStore
        self.predictionLog = predictionLog
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

        guard isEnabled, let context = snapshot?.context, !context.beforeCursor.isEmpty else {
            reset()
            return
        }

        let policy = compatibilityStore.policy(for: context)
        guard policy.isCompletionEnabled, policy.allowsTabAcceptance else {
            reset()
            return
        }
        guard !(policy.excludesSecureField && context.traits.isSecureTextEntry) else {
            reset()
            return
        }

        // THE pause gate. Only a change in the text restarts the clock.
        //
        // The accessibility tracker emits snapshots continuously — caret geometry, window and focus
        // echoes — several times a second whether or not anyone is typing. Cancelling the in-flight
        // evaluation on every snapshot (which this method used to do, at the top, before looking at
        // anything) meant the debounce was restarted faster than it could ever elapse, so the model
        // was never reached and the pause the user was waiting for never arrived. Returning early
        // here leaves the running evaluation alone, so a genuine pause in *typing* is what completes
        // it, rather than a pause in AX traffic that never comes.
        if lastEvaluatedText == context.beforeCursor { return }

        evaluationTask?.cancel()
        evaluationTask = nil

        // Nothing pending survives a real text change; the span it referred to may be gone.
        dismiss()
        lastEvaluatedText = context.beforeCursor

        evaluationTask = Task { [weak self] in
            guard let self else { return }
            let suggestion = await self.proofreader.suggestion(for: context)
            guard !Task.isCancelled else { return }
            guard let suggestion, suggestion.isMeaningful else {
                self.predictionLog?.append(
                    "REWRITE ctx=\"\(PredictionLog.contextTail(context.beforeCursor))\" → none"
                )
                return
            }
            self.present(suggestion, for: context)
        }
    }

    private func present(_ suggestion: RewriteSuggestion, for context: TextFieldContext) {
        let span = PredictionLog.escape(suggestion.span.original)
        let replacement = PredictionLog.escape(suggestion.replacement)

        // Priority between the two paths is decided here, and it turns on how long the user paused.
        //
        // A spelling fix is instant, so it arrives while the writer is mid-flow and the completion
        // on screen is usually about the very word they are typing — completion wins, and the fix
        // waits for the next snapshot. A model grammar fix only exists after a pause of more than a
        // second, which is the writer saying they have stopped composing; there, the correction wins
        // and the completion is cleared. Without this split the grammar pass was effectively
        // invisible, because a completion is nearly always on screen at the moment of a pause.
        if isCompletionVisible() {
            switch suggestion.origin {
            case .proofreader:
                predictionLog?.append("REWRITE origin=proofreader \"\(span)\" → SUPPRESS(completionVisible)")
                return
            case .model:
                dismissCompletion()
            }
        }

        guard var placement = placementResolver.placement(for: context, mode: .correction) else {
            // No caret rect, or the app's overlay preference is `.hidden`. The suggestion was real;
            // there was simply nowhere to draw it.
            predictionLog?.append(
                "REWRITE origin=\(suggestion.origin.rawValue) \"\(span)\" → \"\(replacement)\" → SUPPRESS(noPlacement)"
            )
            return
        }
        placement.presentation = .capsule

        pending = suggestion
        overlay.show(
            text: Self.displayText(for: suggestion),
            font: .systemFont(ofSize: NSFont.systemFontSize),
            placement: placement
        )
        predictionLog?.append(
            "REWRITE origin=\(suggestion.origin.rawValue) \"\(span)\" → \"\(replacement)\" → SHOWN mode=\(placement.mode)"
        )
    }

    /// The capsule shows the replacement as it will land, minus the trailing boundary the span
    /// carries so it ends at the caret — rendering "receive " with its space reads as a typo of its
    /// own. Nothing is truncated: the sentence scanner is bounded so a model rewrite always fits,
    /// because accepting text you cannot fully read is worse than not being offered it.
    static func displayText(for suggestion: RewriteSuggestion) -> String {
        suggestion.replacement.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Acceptance

    /// True when there is a rewrite the user can apply with Tab. The acceptance tap consults this
    /// only after the completion path has declined the key, so no further check is needed here.
    var canAcceptRewrite: Bool {
        pending != nil && isEnabled
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
            predictionLog?.append("REWRITE accept → ABANDONED(spanChanged)")
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

    /// Dismiss and forget the evaluated text, so leaving a field and coming back re-evaluates it
    /// rather than being swallowed by the unchanged-text guard.
    private func reset() {
        lastEvaluatedText = nil
        dismiss()
    }

    private func logOutcome(_ outcome: ReplacementOutcome) {
        switch outcome {
        case let .applied(mechanism):
            predictionLog?.append("REWRITE accept → APPLIED(\(mechanism))")
        case .skipped:
            predictionLog?.append("REWRITE accept → SKIPPED(atReplacer)")
        }
    }

    private func logFailure(_ error: Error) {
        predictionLog?.append("REWRITE accept → FAILED(\(error.localizedDescription))")
        log.error("Rewrite failed: \(error.localizedDescription, privacy: .public)")
    }
}
