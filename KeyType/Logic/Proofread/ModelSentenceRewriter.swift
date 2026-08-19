//
//  ModelSentenceRewriter.swift
//  Glide
//
//  The AI half of the rewrite path: when a sentence is finished, ask the local model to fix its
//  grammar and offer the result under the caret. Same acceptance gesture, same replacement
//  machinery, same capsule as the spell fix — only the source of the suggestion differs.
//
//  It reuses `RewriteService` (the actor behind ⌃⌥G on a selection) rather than standing up a second
//  inference path, but asks for `.inlineGrammar` — the few-shot prompt. Measured against the shipped
//  base model, instruction-style prompting left homophones in place and re-voiced sentences rather
//  than correcting them; the examples fix both. See the Style enum for the numbers.
//
//  Sharing the actor also serializes the two features: a selection rewrite and an inline grammar
//  pass can never drive an eval at the same time.
//
//  Two things make this affordable to run while someone types:
//
//    - `TrailingSentenceScanner` only returns something at a natural boundary — a committed
//      terminator, or a completed word — so the model is not consulted on every keystroke.
//    - The debounce runs *before* the model call, and `ProofreadController` cancels this task on the
//      next AX snapshot, so a typist who keeps going cancels the sleep and inference never starts.
//      Only an actual pause reaches the model.
//
//  The debounce is longer for a sentence with no terminator. A finished sentence is settled and can
//  be checked promptly; a fragment might just be a thought in progress, and only a real pause says
//  otherwise. Requiring the terminator outright — the first version of this — meant the feature
//  almost never fired, because people don't type the final period before sending a chat message.
//
//  Everything the model returns is then treated as untrusted: see `ModelRewriteGate`.
//

import AutocompleteCore
import Foundation
import Proofreading
import os

@MainActor
final class ModelSentenceRewriter: SentenceRewriting {
    private let service: RewriteService
    private let modelFilenameProvider: () -> String
    private let isEnabledProvider: () -> Bool
    private let debounceNanoseconds: UInt64
    private let unterminatedDebounceNanoseconds: UInt64
    private let log = Logger(subsystem: "app.glide", category: "proofread")

    init(
        service: RewriteService,
        modelFilenameProvider: @escaping () -> String,
        isEnabledProvider: @escaping () -> Bool = { true },
        debounceNanoseconds: UInt64 = 400_000_000,
        unterminatedDebounceNanoseconds: UInt64 = 1_100_000_000
    ) {
        self.service = service
        self.modelFilenameProvider = modelFilenameProvider
        self.isEnabledProvider = isEnabledProvider
        self.debounceNanoseconds = debounceNanoseconds
        self.unterminatedDebounceNanoseconds = unterminatedDebounceNanoseconds
    }

    func suggestion(for context: TextFieldContext) async -> RewriteSuggestion? {
        guard isEnabledProvider() else { return nil }
        guard !context.traits.isSecureTextEntry, !context.traits.isPasswordField else { return nil }
        guard let scanned = TrailingSentenceScanner.scan(beforeCursor: context.beforeCursor) else { return nil }
        let trailing = scanned.sentence

        let debounce = scanned.termination == .terminated
            ? debounceNanoseconds
            : unterminatedDebounceNanoseconds
        try? await Task.sleep(nanoseconds: debounce)
        guard !Task.isCancelled else { return nil }

        guard let raw = await service.rewrite(
            trailing.sentence,
            style: .inlineGrammar,
            modelFilename: modelFilenameProvider()
        ) else { return nil }
        guard !Task.isCancelled else { return nil }

        let candidate = ModelRewriteGate.unwrap(raw)
        guard ModelRewriteGate.accepts(candidate: candidate, original: trailing.sentence) else {
            log.debug("Model rewrite rejected by the gate: \(candidate, privacy: .private)")
            return nil
        }

        return RewriteSuggestion(
            span: trailing.span,
            replacement: candidate + trailing.boundary,
            origin: .model
        )
    }
}
