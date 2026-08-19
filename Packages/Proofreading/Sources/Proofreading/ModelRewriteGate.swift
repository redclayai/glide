//
//  ModelRewriteGate.swift
//  Proofreading
//
//  Decides whether a model's proposed sentence is a *grammar fix* worth offering, or something else
//  the model felt like producing. This is the piece that keeps the feature trustworthy, and it is
//  deliberately harsh.
//
//  A local instruction-tuned model asked to "fix the grammar" will, given the chance:
//    - rewrite the sentence into its own voice, which is a different feature (Polish) the user did
//      not ask for and did not select;
//    - answer the sentence instead of correcting it, if the sentence reads like a question;
//    - wrap the output in quotes, or prefix it with "Corrected:" / "Here is";
//    - continue past the sentence and invent a second one;
//    - "fix" a sentence that was already correct, by changing word choice.
//
//  So the test is not "is this good English" — it is "is this the same sentence, with errors
//  removed".
//
//  The measure for that is *word retention*, not character edit distance. Character distance was the
//  first attempt and it was the wrong instrument: correcting "Ok I have think abo it" to "Okay, I
//  have thought about it." rewrites half the characters — a 0.50 ratio — while keeping every word
//  the writer chose. Meanwhile re-voicing "He don't agree with it." as "He disagrees with it."
//  touches fewer characters but throws away a content word. Counting how many of the writer's words
//  survive, allowing for a word being corrected in place, separates those two cleanly where a
//  character count cannot.
//

import Foundation

public enum ModelRewriteGate {
    /// Fraction of the writer's words that must survive the correction. A fix repairs words in
    /// place; a rewrite replaces them. Measured against real model output: a genuine correction
    /// retains 0.8+, a re-voicing lands around 0.6, and an answer-instead-of-a-correction below 0.3.
    public static let minimumWordRetention = 0.65

    /// Backstop for the pathological case where the words all match but the text has ballooned —
    /// deliberately loose, because word retention is the real test.
    public static let maximumEditRatio = 0.6

    /// A fix should not materially change length. Well outside this and the model has added or
    /// dropped content rather than corrected it.
    static let minimumLengthRatio = 0.6
    static let maximumLengthRatio = 1.6

    /// Preambles a model reaches for despite being told not to.
    static let preambles = [
        "corrected:", "correction:", "fixed:", "here is", "here's", "revised:", "rewritten:",
        "sure,", "certainly,", "the corrected", "output:"
    ]

    /// Strip the packaging a model wraps its answer in, without touching the sentence itself.
    public static func unwrap(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only the first line: anything after it is commentary or an invented second sentence.
        if let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first {
            text = String(firstLine).trimmingCharacters(in: .whitespaces)
        }

        let lowered = text.lowercased()
        for preamble in preambles where lowered.hasPrefix(preamble) {
            text = String(text.dropFirst(preamble.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        // Matched wrapping quotes, straight or curly.
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }

        return text
    }

    /// Whether `candidate` is an acceptable grammar fix of `original`.
    public static func accepts(candidate: String, original: String) -> Bool {
        let candidate = candidate.trimmingCharacters(in: .whitespaces)
        let original = original.trimmingCharacters(in: .whitespaces)

        guard !candidate.isEmpty, candidate != original else { return false }
        guard !candidate.contains("\n") else { return false }

        let ratio = Double(candidate.count) / Double(max(original.count, 1))
        guard ratio >= minimumLengthRatio, ratio <= maximumLengthRatio else { return false }

        // The model must not have started a new sentence of its own.
        guard sentenceCount(candidate) <= sentenceCount(original) else { return false }

        guard editRatio(candidate: candidate, original: original) <= maximumEditRatio else { return false }
        return wordRetention(candidate: candidate, original: original) >= minimumWordRetention
    }

    /// The fraction of `original`'s words that survive into `candidate`, in order, counting a word
    /// as surviving when it is corrected in place rather than replaced.
    public static func wordRetention(candidate: String, original: String) -> Double {
        let originalWords = words(in: original)
        guard !originalWords.isEmpty else { return 0 }
        let candidateWords = words(in: candidate)

        // Longest common subsequence over words, so reordering costs but insertion does not.
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: candidateWords.count + 1),
            count: originalWords.count + 1
        )
        for i in 1...originalWords.count {
            for j in stride(from: 1, through: candidateWords.count, by: 1) where !candidateWords.isEmpty {
                table[i][j] = isSameWord(originalWords[i - 1], candidateWords[j - 1])
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return Double(table[originalWords.count][candidateWords.isEmpty ? 0 : candidateWords.count])
            / Double(originalWords.count)
    }

    /// Shortest word that may be matched by prefix. Without a floor, "he" matches "here" and every
    /// short function word finds a spurious partner in unrelated text.
    static let minimumPrefixMatchLength = 3

    /// Two words count as the same word when one is a correction of the other: identical, one a
    /// prefix of the other ("abo"/"about"), or sharing a four-character stem ("finish"/"finished").
    static func isSameWord(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let shorter = min(lhs.count, rhs.count)
        guard shorter >= minimumPrefixMatchLength else { return false }
        if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
        let stem = 4
        guard lhs.count >= stem, rhs.count >= stem else { return false }
        return lhs.prefix(stem) == rhs.prefix(stem)
    }

    /// Apostrophes are stripped rather than split on, so "don't" stays one word instead of becoming
    /// "don" + "t" and inflating the denominator.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// How much of `original` the candidate changes, as a fraction of its length. Exposed so the
    /// threshold can be tuned against real model output rather than guessed at.
    public static func editRatio(candidate: String, original: String) -> Double {
        let original = original.trimmingCharacters(in: .whitespaces)
        guard !original.isEmpty else { return 1 }
        let distance = levenshtein(
            candidate.trimmingCharacters(in: .whitespaces).lowercased(),
            original.lowercased()
        )
        return Double(distance) / Double(original.count)
    }

    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var previousWasTerminator = false
        for character in text {
            let isTerminator = TrailingSentenceScanner.terminators.contains(character)
            if isTerminator, !previousWasTerminator { count += 1 }
            previousWasTerminator = isTerminator
        }
        return max(count, 1)
    }

    /// Standard two-row Levenshtein. The inputs are one sentence bounded at 200 characters, so the
    /// quadratic cost is irrelevant next to the model call that produced the candidate.
    static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
