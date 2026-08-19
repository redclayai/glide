//
//  LayeredRewriter.swift
//  Proofreading
//
//  Runs rewrite sources in order and takes the first meaningful suggestion.
//
//  Order is the whole point. The spell check is instant, deterministic, and offline; the model costs
//  hundreds of milliseconds of local inference. Asking the cheap source first means the common case —
//  a plain misspelling — never wakes the model, and the model is only consulted for what the spell
//  checker had nothing to say about.
//
//  It also settles a collision: at the end of a sentence containing a typo, both sources have an
//  opinion about overlapping spans. First-wins gives the user the narrow, certain fix rather than a
//  whole-sentence replacement that happens to include it.
//

import AutocompleteCore
import Foundation

public struct LayeredRewriter: SentenceRewriting {
    private let sources: [any SentenceRewriting]

    public init(sources: [any SentenceRewriting]) {
        self.sources = sources
    }

    public func suggestion(for context: TextFieldContext) async -> RewriteSuggestion? {
        for source in sources {
            if Task.isCancelled { return nil }
            if let suggestion = await source.suggestion(for: context), suggestion.isMeaningful {
                return suggestion
            }
        }
        return nil
    }
}
