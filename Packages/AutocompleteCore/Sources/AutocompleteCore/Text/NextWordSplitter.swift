import Foundation

/// Splits a completion string into the "next word" to accept (Tab) and the remainder, using ICU
/// word boundaries so it works across scripts — space-delimited (Latin/Cyrillic/…) *and*
/// space-less ones the system segments (CJK, Thai). See ADR-016.
///
/// "Next word" is the leading whitespace plus the word itself, up to (but not including) the word's
/// trailing whitespace. The separator before a word travels *with* that word, never after the
/// previous one (accepting `" world today"` inserts `" world"` and leaves `" today"`; accepting
/// `"orrow to talk"` inserts `"orrow"` and leaves `" to talk"`). A string with one or zero words
/// accepts wholesale.
///
/// Sentence/clause punctuation (`. , ; : ! ?` and the common full-width CJK forms) is *not* swallowed
/// with the word it follows — it becomes its own accept unit, so completing `"esses."` inserts
/// `"esses"` on the first Tab and `"."` on the next. A run of such punctuation (e.g. `"?!"`, `"…"`,
/// `","`) is one unit; any whitespace after it stays with whatever comes next. See ADR-038.
public enum NextWordSplitter {
    /// Punctuation that is confirmed as a separate Tab press rather than bundled into the preceding
    /// word. Covers ASCII sentence/clause marks plus their full-width CJK counterparts.
    private static let separablePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?",
        "。", "，", "、", "；", "：", "！", "？",
    ]

    /// `head` is the slice to insert on a single Tab; `rest` is what remains for the next Tab.
    public static func split(_ text: String) -> (head: String, rest: String) {
        guard !text.isEmpty else { return ("", "") }

        // Leading-punctuation unit: when the remainder begins (after any whitespace) with separable
        // punctuation — e.g. the `"."` left over once `"esses"` was accepted, or `", today"` — that
        // punctuation run is the whole unit. The whitespace that follows it leads the next word, so it
        // is *not* swallowed here.
        if let firstNonSpace = text.firstIndex(where: { !$0.isWhitespace }),
           separablePunctuation.contains(text[firstNonSpace]) {
            var index = firstNonSpace
            while index < text.endIndex, separablePunctuation.contains(text[index]) {
                index = text.index(after: index)
            }
            return (String(text[..<index]), String(text[index...]))
        }

        // Word unit: find where the first ICU word ends. ICU skips whitespace and punctuation, so this
        // segments space-less scripts (CJK/Thai) too.
        var firstWordEnd: String.Index?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { _, range, _, stop in
            firstWordEnd = range.upperBound
            stop = true
        }

        // No words at all (e.g. only whitespace/symbols) → nothing to sub-divide; accept wholesale.
        guard let firstWordEnd else { return (text, "") }

        // The head is the leading whitespace plus the word itself, stopping at the word's end. Any
        // trailing whitespace (the separator before whatever comes next) stays with the rest so it
        // leads the *next* word rather than trailing this one.
        return (String(text[..<firstWordEnd]), String(text[firstWordEnd...]))
    }
}
