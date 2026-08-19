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
//    2. `.shiftArrowSelection` — ⇧← over the span, then paste on top of the selection. The general
//       fallback, and a single undo step in most apps.
//    3. `.backspaceDeletion` — ⌫ over the span, then paste at the caret. For apps where shift
//       selection misbehaves; costs N undo entries and flickers.
//
//  The ladder tries AX first and then *exactly one* keystroke mechanism. Chaining both keystroke
//  paths is unsafe: a shift-selection that only partially took, followed by a delete run, eats
//  text the user typed. See ADR-104.
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

    public init(span: CaretSpan, keystrokeFallback: ReplacementMechanism = .shiftArrowSelection, write: InsertionPlan) {
        self.span = span
        self.keystrokeFallback = keystrokeFallback
        self.write = write
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

    public func plan(span: CaretSpan, replacement: String, context: TextFieldContext) -> ReplacementPlan {
        let write = insertionPlanner.plan(candidate: CompletionCandidate(text: replacement), context: context)
        let policy = compatibilityStore.policy(for: context)

        // Apps that need text injected in chunks rather than pasted also tend to mishandle a
        // synthesized shift-selection, so delete the span outright there.
        let fallback: ReplacementMechanism = policy.stringInjectionChunkSize == nil
            ? .shiftArrowSelection
            : .backspaceDeletion

        return ReplacementPlan(span: span, keystrokeFallback: fallback, write: write)
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
    ///   - settleDelayNanoseconds: pause between removing the span and writing over it, so the
    ///     target app's selection state has landed before the paste.
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

        if let spanReplacer {
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

        if settleDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: settleDelayNanoseconds)
        }

        try await inserter.insert(plan: plan.write)
        return .applied(plan.keystrokeFallback)
    }
}
