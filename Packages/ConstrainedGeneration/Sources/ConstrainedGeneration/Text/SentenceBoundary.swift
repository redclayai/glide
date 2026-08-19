import Foundation

/// Context-aware sentence-boundary disambiguation for the `.stopAndDisplay` (sentence-end) stop.
///
/// The profile flags a token as a sentence end whenever its text contains a terminator
/// (`TokenClassifier.containsSentenceEnd`) — ASCII `.?!…`, closing quotes/brackets, and the
/// non-Latin terminators (`。！？` `।॥` `۔؟` `։` `።` `;`). That flag is necessarily context-free.
///
/// ## Cross-language behaviour
/// - **Non-Latin terminators** (`isUnambiguousTerminator`) are not overloaded with a decimal /
///   abbreviation meaning, so they always end a sentence — no disambiguation needed.
/// - **The ASCII period `.`** is the only ambiguous case, and the ambiguity is shared across
///   Latin-script languages: decimals (`3.14`), ordinals (German `1.`, `am 3. Mai`), numbered
///   lists (`1.`), abbreviations, and initials. The digit rule below uses Unicode-aware
///   `isNumber`, so it also covers Arabic-Indic / Devanagari / fullwidth digits.
/// - **The abbreviation / initial rules are Latin-/cased-script specific** (an English+European
///   set, and an uppercase-initial check). For scripts without case (CJK, Arabic, Hebrew,
///   Devanagari) those rules simply never fire, which is correct — those scripts don't write
///   abbreviations with a trailing ASCII `.` followed by more sentence.
///
/// The function is conservative: anything it can't confidently reject is treated as a real
/// boundary, preserving the decoder's bias toward stopping early.
enum SentenceBoundary {
    /// Lower-cased words that end with a period without ending a sentence. English plus the most
    /// common Western-European abbreviations (German/French/Spanish/Italian), since those share
    /// the Latin `.` and are the languages most likely to appear in mixed text. Internal periods
    /// are stored without them (e.g. `z.b` for `z.B.`).
    private static let abbreviations: Set<String> = [
        // English
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc",
        "e.g", "i.e", "a.m", "p.m", "u.s", "u.k", "no", "vol", "fig", "al",
        "inc", "ltd", "co", "corp", "dept", "est", "approx", "appt", "min", "max",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "wed", "thu", "fri", "sat", "sun",
        // German
        "z.b", "u.a", "d.h", "u.s.w", "usw", "bzw", "ggf", "evtl", "inkl", "geb", "ca", "nr",
        // French
        "p.ex", "c.-à-d", "cf", "env", "mme", "mlle", "m", "av", "bd", "ste",
        // Spanish / Italian
        "sra", "srta", "ud", "uds", "núm", "pág", "ej", "sig", "dott", "egr"
    ]

    /// Closing wrappers / whitespace the profile also treats as sentence-final; skipped to reach
    /// the underlying terminator. Includes CJK/fullwidth closers so a trailing 」』）］ doesn't
    /// hide the real terminator.
    private static func isTrailingWrapper(_ c: Character) -> Bool {
        switch c {
        case " ", "\n", "\t", "\u{00A0}", "\u{3000}",            // spaces (incl. NBSP, ideographic)
             "\"", "'", "\u{201D}", "\u{2019}",                   // " ' ” ’
             ")", "]", "}",                                       // ASCII closers
             "\u{FF09}", "\u{FF3D}", "\u{300D}", "\u{300F}":      // ） ］ 」 』
            return true
        default:
            return false
        }
    }

    /// Sentence terminators that are unambiguous across scripts (no decimal/abbreviation
    /// ambiguity), so they always end a sentence. Only the Latin period `.` needs context.
    private static func isUnambiguousTerminator(_ c: Character) -> Bool {
        switch c {
        case "?", "!", "\u{2026}",                               // ? ! …
             "\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF0E}", "\u{FF61}", // 。 ！ ？ ． ｡
             "\u{0964}", "\u{0965}",                              // । ॥ (Devanagari)
             "\u{06D4}", "\u{061F}",                              // ۔ ؟ (Arabic)
             "\u{0589}", "\u{1362}",                              // ։ ። (Armenian / Ethiopic)
             "\u{104A}", "\u{104B}", "\u{037E}":                  // ၊ ။ (Myanmar), ; (Greek)
            return true
        default:
            return false
        }
    }

    /// Returns `true` when `text` ends at a genuine sentence boundary. Only meaningful for text
    /// whose final emitted token was flagged as a sentence end; it rejects the common false
    /// positives. Conservative: anything it can't confidently reject is treated as a real
    /// boundary (so the decoder keeps its bias toward stopping early).
    static func isTerminal(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, isTrailingWrapper(last) {
            trimmed = trimmed.dropLast()
        }
        guard let terminator = trimmed.last else { return true }

        // Non-Latin and unambiguous terminators end a sentence outright. Only the ASCII period
        // is overloaded (decimals, ordinals like German "1.", abbreviations, initials), so only
        // it needs context-sensitive disambiguation below.
        if isUnambiguousTerminator(terminator) { return true }
        guard terminator == "." else { return true }

        let beforeDot = trimmed.dropLast()
        guard let prev = beforeDot.last else { return true } // bare "."

        // Decimal / ordinal / numbered list: a digit immediately before the period ("1.", "3.14",
        // German ordinal "am 3."). `isNumber` is Unicode-aware so Arabic-Indic / Devanagari /
        // fullwidth digits count too.
        if prev.isNumber { return false }

        // Trailing run of letters/internal-periods → an abbreviation like "etc", "e.g", "U.S".
        let runReversed = beforeDot.reversed().prefix { $0.isLetter || $0 == "." }
        let word = String(runReversed.reversed())
        let core = word.hasPrefix(".") ? String(word.dropFirst()) : word
        if abbreviations.contains(core.lowercased()) { return false }

        // Single uppercase letter before the period → an initial ("J."), not a sentence end.
        if core.count == 1, let only = core.first, only.isUppercase { return false }

        return true
    }
}
