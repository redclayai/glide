//
//  TrailingWord.swift
//  Proofreading
//
//  Finds the word the user just finished typing — the only thing the proofreader is allowed to
//  touch. Pure text logic, no AppKit, so the decision rules are testable directly.
//
//  Why "just finished": while the caret is still inside a word the user is mid-thought and the
//  completion path owns the cursor; correcting a half-typed word would fight the typist. A word
//  becomes eligible only once a boundary character (space, comma, period…) has been committed
//  after it.
//
//  The span returned deliberately includes that trailing boundary, because replacement spans must
//  end exactly at the caret — see `CaretSpan`.
//
//  Two subtleties the obvious implementation gets wrong:
//
//    - A word is a run of *letters and apostrophes*, not "anything that isn't a boundary". Treating
//      the apostrophe as a boundary reduces "don't" to "t", which the spell checker then tries to
//      fix.
//    - Rejecting non-prose has to look at what precedes the word, not just the word itself. In
//      `danny@example.com` and `src/main.swift` the separators are boundaries too, so the scanner
//      only ever sees the trailing fragment ("com", "swift") — which looks like perfectly good
//      prose in isolation. The character in front of the word is what gives it away.
//

import AutocompleteCore
import Foundation

/// A completed word behind the caret, plus the boundary characters that follow it.
public struct TrailingWord: Equatable {
    public let word: String
    /// Whitespace/punctuation sitting between the word and the caret.
    public let boundary: String

    public init(word: String, boundary: String) {
        self.word = word
        self.boundary = boundary
    }

    /// The replaceable span: word + boundary, so it ends at the caret.
    public var span: CaretSpan { CaretSpan(original: word + boundary) }
}

public enum TrailingWordScanner {
    /// Longest boundary run we will absorb into a span. Anything longer means the user has moved
    /// on (blank lines, indentation runs) and a rewrite would arrive too late to be welcome.
    static let maximumBoundaryLength = 3

    /// Words longer than this are almost never prose — hashes, tokens, base64, minified junk.
    static let maximumWordLength = 32

    /// Below this, a "correction" is noise: single letters and two-letter words are either valid
    /// ("a", "I", "to") or too ambiguous to fix confidently.
    static let minimumWordLength = 3

    /// A word is letters plus the apostrophes that live inside contractions and possessives.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "\u{2019}"
    }

    /// Characters that end a word and make it eligible for proofreading.
    static func isBoundary(_ character: Character) -> Bool {
        !isWordCharacter(character)
    }

    /// Characters that, sitting immediately before a word, mean it is a fragment of a larger
    /// machine-readable token — an email, path, URL, identifier, or version string — rather than
    /// the start of prose.
    static let gluingCharacters: Set<Character> = [
        ".", "/", "\\", "@", "_", ":", "-", "#", "$", "~", "=", "+", "%", "&", "|", "^", "<", ">"
    ]

    /// Whether the word itself reads as prose, ignoring its surroundings.
    static func isProse(_ word: String) -> Bool {
        guard word.count >= minimumWordLength, word.count <= maximumWordLength else { return false }
        guard word.contains(where: { $0.isLetter }) else { return false }
        return true
    }

    /// Resolve the word the user just completed, or nil when nothing is eligible.
    public static func scan(beforeCursor: String) -> TrailingWord? {
        guard let last = beforeCursor.last, isBoundary(last) else { return nil }

        var boundary = ""
        var index = beforeCursor.endIndex
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            guard isBoundary(character) else { break }
            // A newline means the word belongs to a line the caret has left. Replacing across a
            // line break with synthesized keystrokes is unreliable, so stop here.
            guard !character.isNewline else { return nil }
            boundary.insert(character, at: boundary.startIndex)
            index = previous
            if boundary.count > maximumBoundaryLength { return nil }
        }

        guard !boundary.isEmpty else { return nil }

        var word = ""
        while index > beforeCursor.startIndex {
            let previous = beforeCursor.index(before: index)
            let character = beforeCursor[previous]
            guard isWordCharacter(character) else { break }
            word.insert(character, at: word.startIndex)
            index = previous
            if word.count > maximumWordLength { return nil }
        }

        guard isProse(word) else { return nil }

        // The word is a fragment of a larger token if something glues it to what came before.
        if index > beforeCursor.startIndex {
            let preceding = beforeCursor[beforeCursor.index(before: index)]
            if gluingCharacters.contains(preceding) { return nil }
        }

        return TrailingWord(word: word, boundary: boundary)
    }
}
