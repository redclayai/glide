//
//  RewriteDiff.swift
//  AutocompleteCore
//
//  Splits a proposed rewrite into the parts that are unchanged and the parts that are new, so the
//  suggestion can show *what it is changing* rather than a wall of text the reader has to compare
//  against their own sentence by eye.
//
//  This matters more than it sounds. A whole-sentence grammar fix is mostly the user's own words;
//  without emphasis, reading it means diffing two sentences in your head under time pressure, which
//  is precisely the work the feature exists to save. With the changed words marked, the decision is
//  a glance.
//
//  Word-level, not character-level: "going" → "going to" should mark one added word, not a run of
//  letters inside a word, which renders as visual noise.
//

import Foundation

public struct RewriteDiff: Equatable {
    public struct Segment: Equatable {
        public let text: String
        public let isChanged: Bool

        public init(text: String, isChanged: Bool) {
            self.text = text
            self.isChanged = isChanged
        }
    }

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    public var changedWordCount: Int {
        segments.filter(\.isChanged).count
    }

    /// Characters the user did not have to retype — the changed portion of the replacement.
    public var changedCharacterCount: Int {
        segments.filter(\.isChanged).reduce(0) { $0 + $1.text.count }
    }

    /// Compare `replacement` against `original`, marking the words of the replacement that are not
    /// carried over. Whitespace is preserved in the segments so the rendered text reads normally.
    public static func between(original: String, replacement: String) -> RewriteDiff {
        let originalWords = tokenize(original)
        let replacementWords = tokenize(replacement)

        // Longest common subsequence over normalized words: everything outside it is a change.
        let keptIndices = commonSubsequenceIndices(
            originalWords.map(\.normalized),
            replacementWords.map(\.normalized)
        )

        var segments: [Segment] = []
        for (index, word) in replacementWords.enumerated() {
            let isChanged = !keptIndices.contains(index)
            // Merge runs of the same kind so the renderer emits as few spans as possible.
            if let last = segments.last, last.isChanged == isChanged {
                segments[segments.count - 1] = Segment(text: last.text + word.raw, isChanged: isChanged)
            } else {
                segments.append(Segment(text: word.raw, isChanged: isChanged))
            }
        }
        return RewriteDiff(segments: segments)
    }

    // MARK: - Internals

    struct Word: Equatable {
        /// The word plus any whitespace that followed it, so concatenating every raw value
        /// reproduces the input exactly.
        let raw: String
        /// Lowercased and stripped of punctuation, for comparison only.
        let normalized: String
    }

    static func tokenize(_ text: String) -> [Word] {
        var words: [Word] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            let normalized = current
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
            words.append(Word(raw: current, normalized: normalized))
            current = ""
        }

        var sawWordCharacter = false
        for character in text {
            if character.isWhitespace {
                current.append(character)
                // Trailing whitespace belongs to the word before it; the next non-space starts a new
                // one.
                if sawWordCharacter {
                    flush()
                    sawWordCharacter = false
                }
            } else {
                current.append(character)
                sawWordCharacter = true
            }
        }
        flush()
        return words
    }

    /// Indices *in the second sequence* that belong to the longest common subsequence.
    static func commonSubsequenceIndices(_ lhs: [String], _ rhs: [String]) -> Set<Int> {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        var table = [[Int]](repeating: [Int](repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in 1...lhs.count {
            for j in 1...rhs.count {
                table[i][j] = lhs[i - 1] == rhs[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }

        var kept: Set<Int> = []
        var i = lhs.count
        var j = rhs.count
        while i > 0, j > 0 {
            if lhs[i - 1] == rhs[j - 1] {
                kept.insert(j - 1)
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return kept
    }
}
