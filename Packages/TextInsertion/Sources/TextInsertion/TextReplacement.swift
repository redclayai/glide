//
//  TextReplacement.swift
//  TextInsertion
//
//  Replacement is the rewrite path's counterpart to completion insertion: instead of appending at
//  the caret, it removes the span the user just typed and writes a corrected version in its place.
//
//  Three mechanisms, in preference order:
//
//    1. `.accessibilitySelectedText` — set the selected range, then write the replacement through
//       AX. No keystrokes, no pasteboard, and it is the only mechanism whose result we can verify
//       by re-reading the element. Works in native AppKit fields; usually refused by web/Electron.
//    2. `.shiftArrowSelection` — ⇧← over the span, then type over the selection. The general
//       fallback, and a single undo step in most apps.
//    3. `.backspaceDeletion` — ⌫ over the span, then type at the caret. For apps where shift
//       selection misbehaves; costs N undo entries and flickers.
//
//  The ladder tries AX first and then *exactly one* keystroke mechanism. Chaining both keystroke
//  paths is unsafe: a shift-selection that only partially took, followed by a delete run, eats
//  text the user typed. See ADR-104.
//
//  The keystroke fallback **types** the replacement rather than pasting it, which is the opposite of
//  what completion insertion does, and deliberately so. Replacing a sentence means synthesizing up
//  to a couple of hundred selection keystrokes first; the target app is still draining those when a
//  paste arrives, so it reads the pasteboard long after the clipboard has been restored and inserts
//  whatever the user had copied earlier. That is not a tuning problem — a fixed restore delay cannot
//  be right for every app and every machine load. Typing the text has no such race and never touches
//  the user's clipboard. See ADR-123.
//

import AppCompatibility
import AppKit
import AutocompleteCore
import Foundation

public enum ReplacementMechanism: Equatable {
    case accessibilitySelectedText
    case shiftArrowSelection
    case backspaceDeletion
}

public struct ReplacementPlan: Equatable {
    /// The text being replaced, ending at the caret.
    public var span: CaretSpan
    /// The keystroke fallback to use when the accessibility write is unavailable or refused.
    public var keystrokeFallback: ReplacementMechanism
    /// Reuses the completion insertion plan for the write half (paste vs. match-style, NBSP
    /// workaround, chunked injection) so replacement inherits every per-app quirk already tuned
    /// for insertion.
    public var write: InsertionPlan
    /// Whether to try the accessibility write at all. False for web-rendered fields, where the
    /// attempt cannot succeed and actively breaks the fallback behind it — see `replace(plan:)`.
    public var allowsAccessibilityWrite: Bool

    public init(
        span: CaretSpan,
        keystrokeFallback: ReplacementMechanism = .shiftArrowSelection,
        write: InsertionPlan,
        allowsAccessibilityWrite: Bool = true
    ) {
        self.span = span
        self.keystrokeFallback = keystrokeFallback
        self.write = write
        self.allowsAccessibilityWrite = allowsAccessibilityWrite
    }

    /// A replacement is worth performing only when it changes something and fits the bound.
    public var isActionable: Bool {
        guard !span.isEmpty, !write.text.isEmpty else { return false }
        guard span.keystrokeLength <= maximumReplacementKeystrokes else { return false }
        return span.original != write.text
    }
}

/// Which mechanism actually applied the replacement — surfaced for the prediction log and tests.
public enum ReplacementOutcome: Equatable {
    case applied(ReplacementMechanism)
    /// The plan was empty, unchanged, or longer than `maximumReplacementKeystrokes`.
    case skipped
    /// The span was not selected after the attempt, so nothing was written. Typing here would insert
    /// the replacement *in front of* the text it was meant to replace, which is worse than doing
    /// nothing at all.
    case abandonedSelectionMismatch
}

public protocol TextReplacing {
    func planReplacement(span: CaretSpan, replacement: String, context: TextFieldContext) -> ReplacementPlan
    func replace(plan: ReplacementPlan) async throws -> ReplacementOutcome
}

// MARK: - Planner

public struct ReplacementPlanner {
    private let insertionPlanner: InsertionPlanner
    private let compatibilityStore: AppCompatibilityStore

    public init(
        insertionPlanner: InsertionPlanner = InsertionPlanner(),
        compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()
    ) {
        self.insertionPlanner = insertionPlanner
        self.compatibilityStore = compatibilityStore
    }

    /// Chunk size used when the app has no opinion. Small enough that a field keeping up with
    /// synthesized input is not asked to swallow a whole sentence in one event.
    static let defaultInjectionChunk = 24

    /// Web-rendered fields get smaller pieces. A Chromium contenteditable given a sentence in two
    /// large chunks can end up drawing the replacement over the original rather than in place of it;
    /// more, smaller edits arrive more like real typing and each one invalidates properly.
    static let webInjectionChunk = 8

    public func plan(span: CaretSpan, replacement: String, context: TextFieldContext) -> ReplacementPlan {
        var write = insertionPlanner.plan(candidate: CompletionCandidate(text: replacement), context: context)
        let policy = compatibilityStore.policy(for: context)

        // Type it, do not paste it. See the file header: after a long selection run, a paste races
        // the clipboard restore and loses. `pasteAndMatchStyle` is the one exception — an app that
        // demands it does so because plain insertion carries the wrong styling, and styling is
        // visible where a clipboard race is merely baffling.
        if write.strategy != .pasteAndMatchStyle {
            let chunk = policy.stringInjectionChunkSize
                ?? (context.traits.isWebField ? Self.webInjectionChunk : Self.defaultInjectionChunk)
            write.strategy = .chunkedStringInjection(size: chunk)
            // Nothing was written to the pasteboard, so there is nothing to put back.
            write.restorePasteboard = false
        }

        // Apps that need text injected in chunks rather than pasted also tend to mishandle a
        // synthesized shift-selection, so delete the span outright there.
        let fallback: ReplacementMechanism = policy.stringInjectionChunkSize == nil
            ? .shiftArrowSelection
            : .backspaceDeletion

        // Chromium-rendered fields answer `.success` to the accessibility write and then drop it, so
        // the attempt is not merely useless there — it leaves the span selected, and the shift-arrow
        // run behind it then produces a partial, wrong selection. Measured in Claude Desktop: with
        // the attempt, the replacement lands in front of the original every time; without it, the
        // keystroke path is correct every time. See ADR-133.
        return ReplacementPlan(
            span: span,
            keystrokeFallback: fallback,
            write: write,
            allowsAccessibilityWrite: !context.traits.isWebField
        )
    }
}

// MARK: - Replacer

public final class PasteboardTextReplacer: TextReplacing {
    private let planner: ReplacementPlanner
    private let inserter: CompletionInserting
    private let synthesizer: KeystrokeSynthesizing
    private let spanReplacer: (any CaretSpanReplacing)?
    private let settleDelayNanoseconds: UInt64

    /// - Parameters:
    ///   - spanReplacer: the accessibility seam. Pass nil to force the keystroke fallback (tests,
    ///     or a build without AX permission).
    ///   - settleDelayNanoseconds: base pause between removing the span and writing over it. The
    ///     actual wait scales with how many keystrokes were synthesized, because the app has to
    ///     drain them before the write can land in the right place.
    public init(
        planner: ReplacementPlanner = ReplacementPlanner(),
        inserter: CompletionInserting = PasteboardCompletionInserter(),
        synthesizer: KeystrokeSynthesizing = CGEventKeystrokeSynthesizer(),
        spanReplacer: (any CaretSpanReplacing)? = nil,
        settleDelayNanoseconds: UInt64 = 12_000_000
    ) {
        self.planner = planner
        self.inserter = inserter
        self.synthesizer = synthesizer
        self.spanReplacer = spanReplacer
        self.settleDelayNanoseconds = settleDelayNanoseconds
    }

    public func planReplacement(span: CaretSpan, replacement: String, context: TextFieldContext) -> ReplacementPlan {
        planner.plan(span: span, replacement: replacement, context: context)
    }

    public func replace(plan: ReplacementPlan) async throws -> ReplacementOutcome {
        guard plan.isActionable else { return .skipped }

        if plan.allowsAccessibilityWrite, let spanReplacer {
            let applied = await MainActor.run {
                spanReplacer.replaceBehindCaret(plan.span, with: plan.write.text)
            }
            if applied { return .applied(.accessibilitySelectedText) }
        }

        // Exactly one keystroke mechanism — never both. See the file header.
        switch plan.keystrokeFallback {
        case .shiftArrowSelection:
            synthesizer.selectBackward(count: plan.span.keystrokeLength)
        case .backspaceDeletion:
            for _ in 0..<plan.span.keystrokeLength {
                synthesizer.deleteBackward()
            }
        case .accessibilitySelectedText:
            // Not a keystroke mechanism; a plan can't select it as the fallback. Nothing was
            // removed, so writing here would append instead of replace.
            return .skipped
        }

        let settle = Self.settleDelay(
            base: settleDelayNanoseconds,
            keystrokes: plan.span.keystrokeLength
        )
        if settle > 0 {
            try? await Task.sleep(nanoseconds: settle)
        }

        // Before typing over the selection, check there *is* one. Where the app exposes its
        // selection this catches a selection that silently failed to take; the failure mode it
        // prevents is the replacement being typed in front of the original rather than over it.
        //
        // Waited for rather than sampled once. A Chromium-rendered field applies a synthesized arrow
        // run asynchronously: measured against Claude Desktop, a 26-character span reads back as ""
        // at 0 ms, "g" at 25 ms, "s working" at 50 ms, and only becomes whole at 75 ms. A single read
        // after a fixed delay catches one of those intermediate states and abandons a replacement
        // that was about to succeed. Polling for the state we actually need is both more reliable
        // than a longer sleep and faster than one, since it returns the moment the app agrees.
        if plan.keystrokeFallback == .shiftArrowSelection, let spanReplacer {
            if await settledSelection(matching: plan.span, using: spanReplacer) == .diverged {
                return .abandonedSelectionMismatch
            }
        }

        try await inserter.insert(plan: plan.write)
        return .applied(plan.keystrokeFallback)
    }

    enum SelectionSettlement {
        /// The app reports the span selected — safe to type over it.
        case matched
        /// The app reports something else and stopped changing — the selection did not take.
        case diverged
        /// The app exposes no selection at all. Not evidence of failure, so the caller proceeds.
        case unknown
    }

    /// Poll the app's reported selection until it matches `span`, it stops being worth waiting for,
    /// or the app turns out to expose nothing.
    private func settledSelection(
        matching span: CaretSpan,
        using replacer: any CaretSpanReplacing
    ) async -> SelectionSettlement {
        var waited: UInt64 = 0
        while true {
            let selection = await MainActor.run { replacer.currentSelection() }
            guard let selection else { return .unknown }
            if Self.selection(selection, matches: span) { return .matched }
            guard waited < Self.selectionSettleDeadlineNanoseconds else { return .diverged }
            try? await Task.sleep(nanoseconds: Self.selectionPollIntervalNanoseconds)
            waited += Self.selectionPollIntervalNanoseconds
        }
    }

    /// Long enough for a slow web view under load to finish a couple of hundred arrow keys; short
    /// enough that a genuinely failed selection does not leave the user waiting. Only a failure ever
    /// spends the whole budget — a success returns as soon as the app agrees.
    static let selectionSettleDeadlineNanoseconds: UInt64 = 500_000_000
    static let selectionPollIntervalNanoseconds: UInt64 = 20_000_000

    /// Whether what the app reports as selected is the span we meant to replace. Compared on trimmed
    /// text because a span carries its trailing boundary and apps differ on whether a selection
    /// includes it; an empty selection never matches, which is the case worth catching.
    static func selection(_ selection: String, matches span: CaretSpan) -> Bool {
        let selected = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return false }
        return selected == span.original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A sentence-length span means a couple of hundred synthesized key events, and the app has to
    /// finish them before the replacement is written or it lands in the wrong place. A flat delay was
    /// tuned for a one-word completion and is nowhere near enough here.
    static func settleDelay(base: UInt64, keystrokes: Int) -> UInt64 {
        let perKeystroke: UInt64 = 900_000        // 0.9ms each
        return base + perKeystroke * UInt64(max(0, keystrokes))
    }
}
