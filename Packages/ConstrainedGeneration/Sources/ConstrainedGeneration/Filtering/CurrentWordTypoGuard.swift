import AutocompleteCore
import Foundation

/// Drops beam branches whose *current word* — the stem the user already typed at the cursor plus the
/// model's continuation up to the next word boundary — completes into a misspelling.
///
/// ## Why this lives inside the beam (not as an end-of-run filter)
/// A misspelled tokenisation can out-score the correct one: `"tom"` + `"orow."` beats `"tom"` +
/// `"orrow."` because the typo splits into commoner sub-tokens with higher individual probability.
/// An end-of-run filter would (a) waste the beam's budget generating the typo branch's *continuation*
/// tokens — all conditioned on the wrong word — and (b) risk the correctly-spelled branch being
/// pruned by the typo's higher score before it is ever finalised. Judging a word the instant it
/// closes lets us discard the typo branch then and there, so every subsequent token is only ever
/// explored from correctly-spelled context. That is what "fix the word, then the next predictions
/// follow" means here: we do not patch letters in a finished string, we keep the branch whose later
/// tokens were generated under the correct spelling.
///
/// ## Conservative by construction (no false positives)
/// - Only a *closed* word is ever judged — a still-growing word is a valid prefix and is never
///   flagged (so `"orr"` of `"orrow"` is safe).
/// - Only fires when the user actually typed a stem at the cursor *and* the model added letters to
///   it; a completion that starts a brand-new word (after a space) is the model's own and is left
///   alone.
/// - Only all-lowercase, letters-only words are eligible. This skips proper nouns and
///   sentence-initial capitals (`"Tomorow"`), acronyms (`"NDA"`), camelCase identifiers, and
///   anything containing digits — all common false-positive sources.
/// - Never runs in `.code` / `.terminal` modes, where identifiers are not "typos".
/// - A word that already appears verbatim in the surrounding text (prefix or suffix) is kept: a
///   term the user is already using is treated as a personal-dictionary entry, not a typo.
/// - The recogniser itself is conservative and reports "recognised" whenever unsure.
final class CurrentWordTypoGuard {
    private let recognizer: WordRecognizing
    private let language: String?
    private let enabled: Bool
    private let stem: String
    private let contextWords: Set<String>
    /// The mid-word healing stem the completion re-emits (ADR-019): the leading whitespace + the
    /// partial word the user already typed (e.g. `" coll"`). Empty when the request isn't healed.
    /// Stripped off a branch's text before word reconstruction so the guard sees the genuinely-new
    /// continuation — without this the branch text starts with the heal's leading space, its
    /// `leadingWord` is empty, and the guard never judges the word (ADR-025 follow-up).
    private let heal: String
    private var cache: [String: Bool] = [:]

    init(recognizer: WordRecognizing?, request: CompletionRequest) {
        self.recognizer = recognizer ?? NoopWordRecognizer()
        self.language = request.context.detectedLanguage
        // Spelling is meaningless for code/terminal; identifiers there are not typos.
        let modeAllowsCheck = request.mode == .prose || request.mode == .correction
        self.enabled = recognizer != nil && modeAllowsCheck
        self.stem = Self.trailingWord(of: request.context.beforeCursor)
        self.contextWords = Self.words(in: request.context.beforeCursor)
            .union(Self.words(in: request.context.afterCursor))
        self.heal = String(decoding: request.requiredPrefixBytes, as: UTF8.self)
    }

    /// Cheap gate the engine checks before doing any per-extension work.
    var isActive: Bool { enabled && !stem.isEmpty }

    /// `true` when extending `parentText` to `childText` *just closed* the current word and that
    /// word is a misspelling — i.e. the engine should drop the child branch.
    func shouldDrop(parentText: String, childText: String) async -> Bool {
        guard isActive else { return false }
        guard let word = currentWordJustClosed(parentText: parentText, childText: childText) else {
            return false
        }
        return await isTypo(word)
    }

    // MARK: - Word reconstruction

    /// The completed current word if (and only if) the current word was open in `parentText` and is
    /// closed in `childText` with at least one model-contributed letter; otherwise `nil`.
    func currentWordJustClosed(parentText: String, childText: String) -> String? {
        // For a healed request the branch text re-emits the typed stem (`" coll…"`); strip it so the
        // reconstruction below works on the genuinely-new continuation rather than a leading space.
        let parent = strippingHeal(parentText)
        let child = strippingHeal(childText)
        guard !isClosed(parent), isClosed(child) else { return nil }
        let lead = Self.leadingWord(of: child)
        guard !lead.isEmpty else { return nil } // completion started with a boundary → not our word
        return stem + lead
    }

    /// Drops the healing stem from a branch's text. A no-op when the request isn't healed or the
    /// branch hasn't yet emitted the whole stem (`strip` returns the text unchanged unless it has the
    /// full `heal` prefix), in which case the unstripped text still starts with the heal's leading
    /// space and is safely treated as "not our word" by the empty-`leadingWord` guard above.
    private func strippingHeal(_ text: String) -> String {
        heal.isEmpty ? text : MidWordHealing.strip(text, heal: heal)
    }

    /// A current word is "closed" once a boundary character follows its leading run of word chars.
    private func isClosed(_ completion: String) -> Bool {
        let lead = Self.leadingWord(of: completion)
        return lead.count < completion.count
    }

    // MARK: - Typo judgement

    private func isTypo(_ word: String) async -> Bool {
        guard Self.isEligible(word) else { return false }
        if contextWords.contains(word.lowercased()) { return false }
        if let cached = cache[word] { return cached }
        let recognized = await recognizer.recognizes(word, language: language)
        let typo = !recognized
        cache[word] = typo
        return typo
    }

    /// Only judge words that look like ordinary lowercase dictionary words.
    static func isEligible(_ word: String) -> Bool {
        var letters = 0
        for c in word {
            if c.isLetter {
                letters += 1
            } else if c != "'" && c != "\u{2019}" && c != "-" {
                return false // digits / symbols → not a dictionary word
            }
        }
        guard letters >= 3 else { return false }
        // Any uppercase anywhere → proper noun, acronym, or camelCase identifier. Skip.
        return word == word.lowercased()
    }

    // MARK: - Tokenisation helpers

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c == "'" || c == "\u{2019}" || c == "-"
    }

    /// Leading run of word characters at the start of `text`.
    static func leadingWord(of text: String) -> String {
        String(text.prefix(while: isWordCharacter))
    }

    /// Trailing run of word characters at the end of `text`, with any dangling intra-word marks
    /// trimmed off the ends.
    static func trailingWord(of text: String) -> String {
        var s = Substring(text)
        var word = ""
        while let last = s.last, isWordCharacter(last) {
            word.append(last)
            s = s.dropLast()
        }
        word = String(word.reversed())
        while let f = word.first, f == "'" || f == "\u{2019}" || f == "-" { word.removeFirst() }
        while let l = word.last, l == "'" || l == "\u{2019}" || l == "-" { word.removeLast() }
        return word
    }

    /// All whole words in `text`, lower-cased, for the surrounding-context exemption.
    static func words(in text: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        func flush() {
            while let f = current.first, f == "'" || f == "\u{2019}" || f == "-" { current.removeFirst() }
            while let l = current.last, l == "'" || l == "\u{2019}" || l == "-" { current.removeLast() }
            if !current.isEmpty { result.insert(current.lowercased()) }
            current = ""
        }
        for c in text {
            if isWordCharacter(c) { current.append(c) } else { flush() }
        }
        flush()
        return result
    }
}

/// Default recogniser used when no spell-checker is wired: everything is "recognised", so the guard
/// is inert and behaviour matches the pre-guard engine. Keeps the engine usable (and tests green)
/// without an AppKit dependency.
struct NoopWordRecognizer: WordRecognizing {
    func recognizes(_ word: String, language: String?) async -> Bool { true }
}
