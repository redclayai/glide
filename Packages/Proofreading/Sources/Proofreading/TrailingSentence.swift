//
//  TrailingSentence.swift
//  Proofreading
//
//  Finds the sentence the user just finished, for the model-backed grammar pass. The word scanner's
//  counterpart, one level up — and much more conservative, because asking a language model costs
//  hundreds of milliseconds of local inference where a spell check costs nothing.
//
//  Two ways in. A *terminated* sentence — the writer typed the period — is settled and can be
//  checked promptly. An *unterminated* one is only offered after a longer pause, because a fragment
//  someone is still mid-clause on will attract confident corrections to a thought they hadn't
//  finished. The pause is what makes the second case safe, and it is what most sentences in chat
//  actually are: people rarely type the final period before sending.
//
//  The upper bound matters more than it looks: a replacement that falls back to keystrokes costs one
//  ⇧← per grapheme, and `maximumReplacementKeystrokes` caps that at 256. A sentence longer than the
//  bound could be proposed but never applied, so it is refused up front instead.
//

import AutocompleteCore
import Foundation

public struct TrailingSentence: Equatable {
    public let sentence: String
    /// Whitespace committed after the terminator, if any.
    public let boundary: String

    public init(sentence: String, boundary: String) {
        self.sentence = sentence
        self.boundary = boundary
    }

    /// The replaceable span: sentence + boundary, so it ends at the caret.
    public var span: CaretSpan { CaretSpan(original: sentence + boundary) }
}

public enum TrailingSentenceScanner {
    static let terminators: Set<Character> = [".", "!", "?"]

    /// Below this a "sentence" is a fragment — a heading, a list item, a one-word reply — where a
    /// grammar model has nothing useful to say and is prone to inventing structure.
    static let minimumCharacters = 16
    static let minimumWords = 3

    /// Bounded by what can actually be *applied*: the keystroke fallback costs one synthesized key
    /// per grapheme and `maximumReplacementKeystrokes` caps that at 256, so a longer sentence could
    /// be proposed and never inserted.
    ///
    /// It was 140 while the capsule was a single line and a long sentence would have been unreadable.
    /// The capsule wraps now, so display is no longer the binding constraint — and 140 was quietly
    /// refusing ordinary prose: a two-clause sentence in an email runs past it easily, which read as
    /// "it doesn't work on real sentences".
    static let maximumCharacters = 220

    /// Content that means this is not prose the model should touch: code, paths, URLs, addresses,
    /// markup. The model will happily "fix" all of it into something that no longer works.
    static func isProse(_ sentence: String) -> Bool {
        let disqualifying: Set<Character> = ["`", "{", "}", "<", ">", "|", "\\", "@", "_", "="]
        guard !sentence.contains(where: { disqualifying.contains($0) }) else { return false }
        guard !sentence.lowercased().contains("http") else { return false }
        guard !sentence.contains("://") else { return false }
        return true
    }

    static func wordCount(_ sentence: String) -> Int {
        sentence.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Whether the sentence's own terminator was typed. Callers use it to decide how long to wait
    /// before spending a model call: a finished sentence is settled, a fragment might not be.
    public enum Termination: Equatable {
        case terminated
        case unterminated
    }

    /// Resolve the sentence behind the caret along with whether the writer finished it.
    public static func scan(beforeCursor: String) -> (sentence: TrailingSentence, termination: Termination)? {
        if let terminated = scanTerminated(beforeCursor: beforeCursor) {
            return (terminated, .terminated)
        }
        if let unterminated = scanUnterminated(beforeCursor: beforeCursor) {
            return (unterminated, .unterminated)
        }
        return nil
    }

    /// A sentence whose terminator has been committed.
    public static func scanTerminated(beforeCursor: String) -> TrailingSentence? {
        // Trailing whitespace committed after the terminator. Anything containing a newline means the
        // caret has left the line and a keystroke replacement could not reach back to it.
        var boundary = ""
        var index = beforeCursor.endIndex
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            guard character.isWhitespace else { break }
            guard !character.isNewline else { return nil }
            boundary.insert(character, at: boundary.startIndex)
            index = previous
            if boundary.count > 2 { return nil }
        }

        // The character now behind us must be the terminator that ended the sentence.
        guard index > beforeCursor.startIndex else { return nil }
        guard terminators.contains(beforeCursor[beforeCursor.index(before: index)]) else { return nil }

        // Walk back to the previous sentence terminator, a newline, or the window limit.
        var sentence = ""
        var scanned = 0
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            if character.isNewline { break }
            // Stop at the terminator of the *previous* sentence, not our own.
            if !sentence.isEmpty, isSentenceBreak(at: previous, in: beforeCursor) {
                break
            }
            sentence.insert(character, at: sentence.startIndex)
            index = previous
            scanned += 1
            if scanned > maximumCharacters { return nil }
        }

        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumCharacters,
              wordCount(trimmed) >= minimumWords,
              isProse(trimmed)
        else { return nil }

        // Trimming only leading whitespace, so `trimmed + boundary` is still a suffix of the text
        // before the caret — which is what makes it a replaceable span.
        return TrailingSentence(sentence: trimmed, boundary: boundary)
    }

    /// Abbreviations whose trailing dot is not the end of a sentence. Without these, walking back
    /// from "We should ask Dr. Ramirez about it." stops at the wrong dot and hands the model half a
    /// sentence to correct.
    static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie", "approx", "no",
        "fig", "al", "inc", "ltd", "co", "dept", "est", "min", "max", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mon", "tue", "wed", "thu", "fri"
    ]

    /// A sentence still being written: no terminator typed yet. Offered only after a pause, which
    /// is what the caller enforces — see the file header.
    ///
    /// This deliberately accepts a caret sitting mid-word. The first version required a trailing
    /// space, on the reasoning that mid-word means the writer is still going. In practice that made
    /// the pass almost unreachable: someone who types a sentence and stops leaves the caret directly
    /// after the last letter, so no snapshot ever carries a trailing boundary and nothing was ever
    /// evaluated. The pause itself is the evidence that the thought is finished — a boundary
    /// character is not, and waiting for one means waiting forever.
    public static func scanUnterminated(beforeCursor: String) -> TrailingSentence? {
        guard let last = beforeCursor.last, !last.isNewline else { return nil }

        var boundary = ""
        var index = beforeCursor.endIndex
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            guard character.isWhitespace else { break }
            guard !character.isNewline else { return nil }
            boundary.insert(character, at: boundary.startIndex)
            index = previous
            if boundary.count > 2 { return nil }
        }

        var sentence = ""
        var scanned = 0
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            if character.isNewline { break }
            if isSentenceBreak(at: previous, in: beforeCursor) { break }
            sentence.insert(character, at: sentence.startIndex)
            index = previous
            scanned += 1
            if scanned > maximumCharacters { return nil }
        }

        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumCharacters,
              wordCount(trimmed) >= minimumWords,
              isProse(trimmed)
        else { return nil }

        return TrailingSentence(sentence: trimmed, boundary: boundary)
    }

    /// Whether the terminator at `index` really ends a sentence.
    ///
    /// `!` and `?` always do. A `.` does not when the token in front of it is an abbreviation or a
    /// single letter (initials — "J. R. R. Tolkien"). What *follows* the dot cannot tell these
    /// apart: "Dr. Ramirez" and "it. He" both read as space-then-capital.
    static func isSentenceBreak(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        guard terminators.contains(character) else { return false }
        guard character == "." else { return true }

        var token = ""
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let candidate = text[previous]
            guard candidate.isLetter else { break }
            token.insert(candidate, at: token.startIndex)
            cursor = previous
            if token.count > 8 { break }
        }

        if token.count == 1 { return false }
        return !abbreviations.contains(token.lowercased())
    }
}
