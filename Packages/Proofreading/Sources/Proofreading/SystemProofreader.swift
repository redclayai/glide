//
//  SystemProofreader.swift
//  Proofreading
//
//  The deterministic, always-available half of the rewrite path: spelling and autocorrect for the
//  word the user just finished, via `NSSpellChecker`. No model, no network, no latency worth
//  measuring — which is what makes it the right thing to run on every word boundary.
//
//  It is deliberately conservative. `NSSpellChecker` will offer a "correction" for plenty of words
//  that are perfectly fine (names, jargon, dialect), and a wrong rewrite costs far more than a
//  missed one: the user has already typed the word, so anything we change had better be an
//  unambiguous improvement. Hence the gates in `suggestion(for:)`:
//
//    - only a word that is actually flagged as misspelled is eligible;
//    - the replacement must be a single word (a correction that splits or joins words moves the
//      caret in ways the replacement mechanisms don't model);
//    - the replacement must differ only in spelling, not in case (nobody wants "i" → "I" fighting
//      their lowercase style), unless the misspelling is unambiguous;
//    - the user's own dictionary wins — `NSSpellChecker` already honours it, and `ignoredWords`
//      is threaded through the document tag.
//
//  A future Harper-backed implementation can replace this type wholesale: everything above the
//  `SentenceRewriting` protocol is unaware of which engine produced the suggestion.
//

import AppKit
import AutocompleteCore
import Foundation

@MainActor
public final class SystemProofreader: SentenceRewriting {
    private let checker: NSSpellChecker
    private let documentTag: Int

    public init(checker: NSSpellChecker = .shared) {
        self.checker = checker
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    deinit {
        let tag = documentTag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    public func suggestion(for context: TextFieldContext) async -> RewriteSuggestion? {
        guard !context.traits.isSecureTextEntry, !context.traits.isPasswordField else { return nil }
        guard let trailing = TrailingWordScanner.scan(beforeCursor: context.beforeCursor) else { return nil }
        guard let corrected = correction(for: trailing.word, in: context) else { return nil }

        let suggestion = RewriteSuggestion(
            span: trailing.span,
            replacement: corrected + trailing.boundary,
            origin: .proofreader
        )
        return suggestion.isMeaningful ? suggestion : nil
    }

    // MARK: - Spell checking

    /// Ask the system spell checker for a replacement for `word`, using the sentence it sits in as
    /// context (autocorrect quality depends heavily on it). Returns nil unless the word is both
    /// flagged as misspelled and has an unambiguous single-word fix.
    private func correction(for word: String, in context: TextFieldContext) -> String? {
        let sentence = Self.enclosingSentence(of: context.beforeCursor)
        guard let wordRange = sentence.range(of: word, options: .backwards) else { return nil }
        let nsRange = NSRange(wordRange, in: sentence)
        let language = context.detectedLanguage ?? checker.language()

        // Gate 1: only proceed if the checker considers this word misspelled.
        //
        // Checked against the word in isolation, not against the sentence. `startingAt:` does not
        // mean "begin scanning here" — it resumes at the *next* word after the given offset, so
        // passing the target word's own start offset skips precisely the word we are asking about
        // and reports nothing. Handing the checker just the word sidesteps that entirely and gives
        // an unambiguous {0, length} answer.
        let isolated = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        guard isolated.location == 0, isolated.length == (word as NSString).length else { return nil }

        let candidate = checker.correction(
            forWordRange: nsRange,
            in: sentence,
            language: language,
            inSpellDocumentWithTag: documentTag
        ) ?? checker.guesses(
            forWordRange: nsRange,
            in: sentence,
            language: language,
            inSpellDocumentWithTag: documentTag
        )?.first

        guard let candidate, Self.isAcceptable(candidate: candidate, for: word) else { return nil }
        return candidate
    }

    /// Gate 2 and 3: a usable correction is one word, actually different, and not a bare case flip.
    nonisolated static func isAcceptable(candidate: String, for word: String) -> Bool {
        guard !candidate.isEmpty, candidate != word else { return false }
        guard !candidate.contains(where: { $0.isWhitespace }) else { return false }
        guard candidate.lowercased() != word.lowercased() else { return false }
        return true
    }

    /// The sentence the caret sits in, bounded to a window the checker can use as context without
    /// us handing it the user's whole document.
    nonisolated static func enclosingSentence(of beforeCursor: String, limit: Int = 240) -> String {
        let window = String(beforeCursor.suffix(limit))
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        // Skip the trailing boundary run so a sentence-ending period doesn't cut the sentence off
        // at the very word being checked.
        let trimmed = window.reversed().drop(while: { TrailingWordScanner.isBoundary($0) })
        guard let breakIndex = trimmed.firstIndex(where: { terminators.contains($0) }) else {
            return window
        }
        let sentence = String(trimmed[trimmed.startIndex..<breakIndex].reversed())
        let boundary = window.suffix(while: { TrailingWordScanner.isBoundary($0) })
        return sentence + boundary
    }
}

private extension String {
    /// Trailing run of characters satisfying `predicate`, in original order.
    func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}
