import Foundation

/// Sentence-aware look-ahead for streaming corrections. Never stop on the current last period:
/// it may become a decimal or abbreviation when the next token arrives.
public enum RewriteSentenceBoundary {
    public static func finishedPrefix(in generated: String, matching original: String) -> String? {
        let budget = max(1, ranges(in: original).count)
        let sentences = ranges(in: generated)
        guard sentences.count > budget else { return nil }
        return String(generated[..<sentences[budget - 1].upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ranges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
