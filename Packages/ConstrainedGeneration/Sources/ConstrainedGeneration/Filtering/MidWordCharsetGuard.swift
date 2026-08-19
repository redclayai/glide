import AutocompleteCore
import Foundation

/// Suppresses prose completions that splice *garbage characters* into the word the user is typing.
///
/// Small base models — especially when fed noisy OCR/screen context — emit completions that close
/// the current word with a stray symbol (`"gre"` → `"at$"`) or pile up punctuation (`"...."`).
/// These are never insertable text; they are exactly the "random characters such as `$`" and
/// "entirely too many periods" failures users report mid-word. Like `CurrentWordTypoGuard` this is
/// applied **in the beam** (so a clean branch can win) and re-checked in `DefaultCandidateFilter`
/// as the documented last gate.
///
/// ## Conservative by construction
/// - Only runs in `.prose` / `.correction` mode — code/terminal legitimately use `$ * | < >` etc.
/// - Only judges the word the user is *actively completing*: it fires when a junk character is the
///   boundary that closes the typed stem's continuation (`stem` + model letters + junk). A symbol
///   that follows a *clean* boundary (a space — i.e. a brand-new word the model started, like the
///   `$` in `" $5"`) is left alone, so prices/handles/markup in ordinary text are untouched.
/// - Digits never trigger it (a digit isn't a "word character" here, so a digit-led run such as
///   `"50%"` is treated as a fresh token, not a corrupted word).
/// - The only context-free rule is a run of ≥4 identical punctuation marks (`"...."`), which is
///   garbage regardless of position; a normal ellipsis (`"..."`) passes.
public enum MidWordCharsetGuard {
    /// Characters that legitimately *close* a word in prose. Anything outside this set (and outside
    /// letters/digits/whitespace) glued onto an open word is treated as corruption.
    private static let allowedWordClosers = Set(".,!?;:'\"’”“)]}-–—…/%")

    /// Punctuation marks whose ≥4-long repeated run marks the whole completion as garbage.
    private static let runnablePunctuation = Set(".,!?;:-")

    /// `true` when `completion` (the raw branch/candidate text, *including* any re-emitted heal stem)
    /// corrupts the current word in a prose-mode `request`.
    public static func violates(completion: String, request: CompletionRequest) -> Bool {
        guard request.mode == .prose || request.mode == .correction else { return false }

        let heal = String(decoding: request.requiredPrefixBytes, as: UTF8.self)
        // Work on the genuinely-new continuation: strip the re-emitted stem of a healed request
        // (ADR-019) so the leading characters are the model's, not the user's typed bytes.
        let cont = heal.isEmpty ? completion : MidWordHealing.strip(completion, heal: heal)
        guard !cont.isEmpty else { return false }

        if hasExcessivePunctuationRun(cont) { return true }

        // Only police the word the user is mid-way through typing.
        let stem = CurrentWordTypoGuard.trailingWord(of: request.context.beforeCursor)
        guard !stem.isEmpty || !heal.isEmpty else { return false }

        // The model's letters that extend the open word, then the first character that closes it.
        let lead = CurrentWordTypoGuard.leadingWord(of: cont)
        guard lead.count < cont.count else { return false } // word still open — nothing closed it yet
        guard !lead.isEmpty else { return false } // model started on a boundary, not inside the word

        let closer = cont[cont.index(cont.startIndex, offsetBy: lead.count)]
        return isJunkCloser(closer)
    }

    /// A non-letter, non-digit, non-whitespace character that isn't an allowed word-closer.
    private static func isJunkCloser(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber || c.isWhitespace { return false }
        return !allowedWordClosers.contains(c)
    }

    /// `true` when any single punctuation mark repeats ≥4 times in a row ("....", "----").
    static func hasExcessivePunctuationRun(_ text: String) -> Bool {
        var previous: Character?
        var run = 0
        for c in text {
            if c == previous {
                run += 1
            } else {
                previous = c
                run = 1
            }
            if run >= 4, let p = previous, runnablePunctuation.contains(p) {
                return true
            }
        }
        return false
    }
}
