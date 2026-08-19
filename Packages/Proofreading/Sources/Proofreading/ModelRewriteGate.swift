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
//  removed". Similarity is the core measure: a genuine grammar fix touches a small fraction of the
//  text. Anything that diverges beyond `maximumEditRatio` is a rewrite, and gets dropped.
//

import Foundation

public enum ModelRewriteGate {
    /// Fraction of the sentence a grammar fix may change. Tuned to allow verb agreement, articles,
    /// tense, plurals, and punctuation — while rejecting a re-voicing of the whole sentence.
    public static let maximumEditRatio = 0.34

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

        let distance = levenshtein(candidate.lowercased(), original.lowercased())
        let editRatio = Double(distance) / Double(max(original.count, 1))
        return editRatio <= maximumEditRatio
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
