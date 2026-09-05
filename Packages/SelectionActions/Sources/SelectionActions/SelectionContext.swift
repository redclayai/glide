//
//  SelectionContext.swift
//  SelectionActions
//
//  What we know about the selected text, computed once per presentation and handed to every
//  applicability check and every ranker.
//
//  Deliberately cheap. This runs on the main actor while the user waits for a toolbar to appear over
//  their selection, so everything here is a linear scan or better, and the one genuinely expensive
//  signal — language identification — is computed lazily by the caller that needs it rather than
//  eagerly for every selection.
//
//  The detectors answer "is it worth offering an action for this" and nothing more. `containsURL` is
//  allowed to be wrong about an edge case; the cost is one extra item in a menu, not a broken
//  document.
//

import Foundation

public struct SelectionContext: Equatable, Sendable {
    public var text: String
    public var bundleIdentifier: String?

    public var characterCount: Int
    public var wordCount: Int
    public var lineCount: Int
    public var containsURL: Bool
    public var containsEmail: Bool
    public var looksLikeCode: Bool

    public var isMultiline: Bool { lineCount > 1 }
    public var isSingleWord: Bool { wordCount == 1 }
    /// Long enough that summarising it is a sensible offer rather than a joke.
    public var isSubstantialProse: Bool { wordCount >= 25 && !looksLikeCode }

    public init(text: String, bundleIdentifier: String? = nil) {
        self.text = text
        self.bundleIdentifier = bundleIdentifier
        self.characterCount = text.count
        self.wordCount = Self.countWords(in: text)
        self.lineCount = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        self.containsURL = Self.detector(.link)?.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )?.url != nil
        self.containsEmail = Self.containsEmailAddress(text)
        self.looksLikeCode = Self.looksLikeCode(text)
    }

    /// The first URL in the selection, for actions that open one rather than search for the text.
    public var firstURL: URL? {
        guard let match = Self.detector(.link)?.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) else { return nil }
        return match.url
    }

    // MARK: - Detection

    /// `NSDataDetector` construction is not free and the type is documented as thread-safe for
    /// concurrent use, so the two we need are built once.
    private static func detector(_ types: NSTextCheckingResult.CheckingType) -> NSDataDetector? {
        if types == .link { return linkDetector }
        return try? NSDataDetector(types: types.rawValue)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func countWords(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// `NSDataDetector.link` reports `mailto:` for bare addresses, which is the cheapest reliable
    /// signal available — a hand-rolled regex here would be longer and worse.
    static func containsEmailAddress(_ text: String) -> Bool {
        guard let detector = linkDetector else { return false }
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            if match?.url?.scheme == "mailto" {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// A heuristic, and it only has to be about right.
    ///
    /// Scored rather than pattern-matched because any single signal is a bad test on its own: prose
    /// contains braces, code contains English, and one line of either proves nothing. Two independent
    /// signals is the threshold — it keeps "the function returns nil" out and lets a genuine snippet
    /// through.
    static func looksLikeCode(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var score = 0

        let codePunctuation = CharacterSet(charactersIn: "{}[]();<>=")
        let punctuationCount = text.unicodeScalars.filter { codePunctuation.contains($0) }.count
        if Double(punctuationCount) / Double(max(text.count, 1)) > 0.04 { score += 1 }

        let keywords = ["func ", "def ", "class ", "return ", "import ", "const ", "let ", "var ",
                        "if (", "for (", "while (", "=> ", "public ", "private ", "#include"]
        if keywords.contains(where: text.contains) { score += 1 }

        // Leading indentation on more than one line — prose wraps, code indents.
        let indented = text.split(separator: "\n").filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        if indented.count >= 2 { score += 1 }

        return score >= 2
    }
}
