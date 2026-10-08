//
//  SelectionSpellChecker.swift
//  Proofreading
//
//  Spelling correction across a whole selection, rather than the one word behind the caret.
//
//  `SystemProofreader` exists for the inline pass and is shaped for it: one word, at the caret, on a
//  word boundary. The Grammar *action* is handed an arbitrary span — a sentence, a paragraph, a
//  pasted mess — and has to fix every misspelling in it. Same engine, different traversal, so this is
//  a separate type rather than a parameter on that one.
//
//  Why this exists at all, when the Grammar prompt already says "correct the spelling": because the
//  on-device model is a *base* model and does not follow instructions (ADR-138). Telling it to fix
//  spelling achieves approximately nothing. `NSSpellChecker` does it deterministically, offline, in
//  no measurable time, and is right far more often than a 2B model asked nicely — so spelling is
//  handled before the model is consulted at all, and is handled even when there is no model.
//
//  Conservative for the same reason `SystemProofreader` is: the user typed these words, so a change
//  had better be an unambiguous improvement. A wrong "correction" to a name or a piece of jargon is
//  worse than leaving a typo alone.
//

import AppKit
import Foundation

@MainActor
public final class SelectionSpellChecker {
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

    /// Every misspelled word in `text` replaced by its best guess, where that guess passes the gates
    /// below. Returns the input unchanged when nothing qualifies.
    public func corrected(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let ns = text as NSString

        // `check(_:range:types:…)`, not `checkSpelling(of:startingAt:)`.
        //
        // The latter is markedly more conservative in context and missed the obvious cases: measured
        // on "This is a testt.", it flagged nothing at all, while `guesses` for the same word offered
        // "test" happily. `check` with `.spelling` flags every misspelling in the span — and finds
        // nothing in a clean sentence — which is the behaviour the OS's own autocorrect shows.
        let results = checker.check(
            text,
            range: NSRange(location: 0, length: ns.length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: nil,
            inSpellDocumentWithTag: documentTag,
            orthography: nil,
            wordCount: nil
        )
        guard !results.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in results where match.range.location >= cursor && match.range.length > 0 {
            let range = match.range
            result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            result += corrected(span: range, in: text, ns: ns)
            cursor = range.location + range.length
        }
        if cursor < ns.length { result += ns.substring(from: cursor) }
        return result
    }

    /// One flagged span, corrected.
    ///
    /// Usually a single word, and then this is just `replacement(for:)`. But the checker sometimes
    /// returns a range covering several of them — on "Teh meetng is tommorow." its first result was
    /// the twelve characters "Teh meetng i", with no guesses at all and no separate result for the
    /// words inside it. Taking that at face value corrected nothing in the sentence; skipping it
    /// lost "Teh". So a multi-word span is broken into its words and each is judged on its own,
    /// with the text between them carried through untouched.
    ///
    /// It failed silently, and only where several typos sat close together — which is exactly the
    /// text this exists for.
    private func corrected(span: NSRange, in text: String, ns: NSString) -> String {
        let whole = ns.substring(with: span)
        guard whole.contains(where: \.isWhitespace) else {
            return replacement(
                for: whole,
                range: span,
                in: text,
                startsSentence: Self.startsSentence(at: span.location, in: ns)
            ) ?? whole
        }

        var rebuilt = ""
        var cursor = span.location
        ns.enumerateSubstrings(in: span, options: [.byWords, .localized]) { word, wordRange, _, _ in
            guard let word, wordRange.location >= cursor else { return }
            rebuilt += ns.substring(with: NSRange(location: cursor, length: wordRange.location - cursor))
            rebuilt += self.replacement(
                for: word,
                range: wordRange,
                in: text,
                startsSentence: Self.startsSentence(at: wordRange.location, in: ns)
            ) ?? word
            cursor = wordRange.location + wordRange.length
        }
        let end = span.location + span.length
        if cursor < end { rebuilt += ns.substring(with: NSRange(location: cursor, length: end - cursor)) }
        return rebuilt
    }

    /// The gates. Each exists because its absence produced a worse result than the typo.
    func replacement(for word: String, range: NSRange, in text: String, startsSentence: Bool) -> String? {
        // A capitalised word mid-sentence is a name far more often than a typo, and the checker has
        // no idea what your products are called. Measured: "…on Millie and Cueo." offered "Cleo" as
        // its first in-context guess for Cueo, which is a rename, not a correction. Sentence-initial
        // words are still fair game, so "Teh cat" is fixed.
        if !startsSentence, let first = word.first, first.isUppercase { return nil }

        guard let guesses = checker.guesses(
            forWordRange: range,
            in: text,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) else { return nil }

        // The first guess that is a single word. A guess containing a space splits or joins words,
        // which reflows everything after it — the replacement mechanisms model a span, not a reflow.
        guard let guess = guesses.first(where: { !$0.contains(" ") && !$0.isEmpty }) else { return nil }

        // The two engines have to agree.
        //
        // `guesses` ranks what the word *could* have been; `correction` is the autocorrect API and
        // answers the stricter question of what it should silently become. They agree on real
        // typos and diverge exactly where the word is not a typo at all, which is the case worth
        // catching — measured over 23 misspellings they agreed on all 17 genuine ones and on none
        // of the 6 that should be left alone:
        //
        //   sended    guesses "seeded"     correction "ended"      — a verb form, not a spelling
        //   writed    guesses "writes"     correction "waited"
        //   goed      guesses "goes"       correction "good"
        //   Supabase  guesses "Superbness" correction nil          — a product name
        //   Cueo      guesses "Cleo"       correction nil
        //
        // This matters more now than it did: corrections are applied the moment text is selected,
        // without being asked for, so a wrong one is something the user never invited and may not
        // notice. The words this declines to touch are the model's job anyway — a tense error is
        // grammar, and grammar runs straight after.
        guard let correction = checker.correction(
            forWordRange: range,
            in: text,
            language: checker.language(),
            inSpellDocumentWithTag: documentTag
        ), correction.lowercased() == guess.lowercased() else { return nil }

        // Differing only in case is a style opinion, not a spelling fix — nobody wants "i" quietly
        // becoming "I" in text they chose to write lowercase.
        guard guess.lowercased() != word.lowercased() else { return nil }

        return Self.matchingCase(of: word, in: guess)
    }

    /// Whether the word at `location` opens a sentence — start of the text, or the first word after
    /// a terminator.
    static func startsSentence(at location: Int, in text: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")
            if character.isWhitespace || character == "\"" || character == "'" {
                index -= 1
                continue
            }
            return ".!?".contains(character)
        }
        return true
    }

    /// Carry the original's capitalisation onto the replacement, so a misspelling at the start of a
    /// sentence does not come back lowercase.
    static func matchingCase(of original: String, in replacement: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        // All caps stays all caps; otherwise just the leading letter.
        if original.count > 1, original.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return replacement.uppercased()
        }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
