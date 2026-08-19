import AutocompleteCore
import Foundation

/// Output of `TokenClassifier.classify(_:)`. Carries the flag set the writer stores in
/// the on-disk record plus the decoded text the bias policy uses.
public struct TokenProfileClassification: Equatable {
    public var flags: TokenProfileFlags
    /// Width of the token in *grapheme clusters* when the bytes decode as UTF-8, else
    /// the byte count. Capped at `UInt16.max` so it fits in the on-disk record.
    public var displayWidth: Int
    /// Raw tokenizer attribute bits packed into a `UInt16` so the on-disk record can
    /// carry them through unmodified (the runtime can re-derive secondary state from
    /// this without going back to the tokenizer).
    public var tokenType: UInt16
    /// UTF-8 decoded text, with byte-BPE space/newline markers (`Ġ`, `Ċ`, `▁`) stripped
    /// so the visible width and bias rules can be applied to the underlying glyphs.
    /// `nil` if `bytes` is not a valid UTF-8 sequence.
    public var decodedText: String?

    public init(
        flags: TokenProfileFlags,
        displayWidth: Int,
        tokenType: UInt16,
        decodedText: String?
    ) {
        self.flags = flags
        self.displayWidth = displayWidth
        self.tokenType = tokenType
        self.decodedText = decodedText
    }
}

/// Pure, deterministic classifier mapping a `TokenizerProbe` to the `TokenProfileFlags`
/// the runtime sampler reads. No I/O, no tokenizer calls — synthetic probes drive the
/// tests directly.
public enum TokenClassifier {

    // MARK: - Public surface

    public static func classify(_ probe: TokenizerProbe) -> TokenProfileClassification {
        let rawText = String(bytes: probe.bytes, encoding: .utf8)
        let stripped: StrippedText
        if let rawText = rawText {
            stripped = stripBPEMarkers(rawText)
        } else {
            stripped = StrippedText(text: "", hadSpaceMarker: false, hadNewlineMarker: false, hadLeadingWhitespace: false)
        }
        let visibleText = stripped.text

        var flags = TokenProfileFlags()

        // SPECIAL: control / user-defined / unknown / unused / known role / chat marker.
        let isSpecial =
            probe.attr.contains(.control)
            || probe.attr.contains(.userDefined)
            || probe.attr.contains(.unknown)
            || probe.attr.contains(.unused)
            || probe.isControl
            || probe.role != nil
            || matchesChatMarker(rawText)
        if isSpecial { flags.insert(.special) }

        // STOP: EOS / EOT / any EOG-declared token.
        let isStop =
            probe.isEOG
            || probe.role == .eos
            || probe.role == .eot
        if isStop { flags.insert(.stop) }

        // CHAT_MARKER: assistant scaffolding text we never want to emit.
        if matchesChatMarker(rawText) { flags.insert(.chatMarker) }

        // INVALID_UTF8 (standalone byte fallback or partial multi-byte token).
        if rawText == nil { flags.insert(.invalidUTF8) }

        // EXCLUDED: every special token except a genuine end-of-generation stop we keep as
        // a stop *condition* (EOS / EOT). A "displayable stop" is role-driven so exclusion no
        // longer relies on the token's rendered text — which is empty for special tokens under
        // `rawBytes` / `special: false`. This matters for tokens that are special AND EOG but
        // are not eos/eot (e.g. a PAD token llama reports as end-of-generation): they must still
        // be excluded from sampling. Chat markers, unknown/unused, and standalone invalid-UTF8
        // tokens are excluded too (the latter stay walkable through the trie as intermediate
        // steps, but are never sampled directly).
        let isDisplayableStop = probe.role == .eos || probe.role == .eot
        let excluded =
            (isSpecial && !isDisplayableStop)
            || flags.contains(.chatMarker)
            || probe.attr.contains(.unknown)
            || probe.attr.contains(.unused)
            || (flags.contains(.invalidUTF8) && !flags.contains(.stop))
        if excluded { flags.insert(.excluded) }

        // Visible-text driven flags. Skipped for invalid-UTF8 tokens (no glyph info).
        if !visibleText.isEmpty {
            let firstScalar = visibleText.unicodeScalars.first!

            // WHITESPACE / NEWLINE — driven by both leading marker (Ġ/Ċ/▁) and raw text.
            if stripped.hadSpaceMarker || firstScalar.properties.isWhitespace {
                flags.insert(.whitespace)
            }
            if stripped.hadNewlineMarker || visibleText.contains("\n") || visibleText.contains("\r") {
                flags.insert(.newline)
                flags.insert(.whitespace)
            }

            // PUNCTUATION / SENTENCE_END
            if isPunctuation(firstScalar) {
                flags.insert(.punctuation)
            }
            if containsSentenceEnd(visibleText) {
                flags.insert(.sentenceEnd)
            }

            // EMOJI: any presentation-default emoji scalar or ZWJ-bound emoji sequence.
            if containsEmoji(visibleText) {
                flags.insert(.emoji)
            }

            // WORD_START / WORD_CONTINUATION
            let afterMarker = stripped.hadSpaceMarker || stripped.hadNewlineMarker
                || stripped.hadLeadingWhitespace
            let firstLetterOrDigit = firstNonWhitespaceScalar(visibleText).map { isLetterOrDigit($0) } ?? false
            if afterMarker && firstLetterOrDigit {
                flags.insert(.wordStart)
            } else if !afterMarker && firstLetterOrDigit {
                flags.insert(.wordContinuation)
            }
        } else if stripped.hadNewlineMarker {
            // Lone Ċ etc. — newline-only token with empty visible text.
            flags.insert(.newline)
            flags.insert(.whitespace)
        } else if stripped.hadSpaceMarker {
            flags.insert(.whitespace)
        }

        let displayWidth: Int
        if let text = rawText {
            displayWidth = min(text.count, Int(UInt16.max))
        } else {
            displayWidth = min(probe.bytes.count, Int(UInt16.max))
        }

        // Pack attr bits as token_type (preserve the bits; high bits are unused).
        let tokenType = UInt16(truncatingIfNeeded: probe.attr.rawValue & UInt32(UInt16.max))

        return TokenProfileClassification(
            flags: flags,
            displayWidth: displayWidth,
            tokenType: tokenType,
            decodedText: rawText
        )
    }

    // MARK: - Internals

    struct StrippedText {
        var text: String
        var hadSpaceMarker: Bool
        var hadNewlineMarker: Bool
        var hadLeadingWhitespace: Bool
    }

    /// Strip leading byte-BPE markers (`Ġ` / `Ċ` / `▁`) from a token's decoded text.
    /// Returns the visible text plus flags describing which markers we removed and
    /// whether the residual text starts with real Unicode whitespace.
    static func stripBPEMarkers(_ text: String) -> StrippedText {
        guard !text.isEmpty else {
            return StrippedText(text: "", hadSpaceMarker: false, hadNewlineMarker: false, hadLeadingWhitespace: false)
        }
        var s = text[...]
        var hadSpace = false
        var hadNewline = false
        while let first = s.first {
            if first == "\u{0120}" {            // "Ġ" — GPT-2/Qwen space marker
                hadSpace = true
                s = s.dropFirst()
            } else if first == "\u{010A}" {     // "Ċ" — GPT-2/Qwen newline marker
                hadNewline = true
                s = s.dropFirst()
            } else if first == "\u{2581}" {     // "▁" — SentencePiece space marker
                hadSpace = true
                s = s.dropFirst()
            } else {
                break
            }
        }
        let visible = String(s)
        let leadingWS = visible.unicodeScalars.first?.properties.isWhitespace ?? false
        return StrippedText(text: visible, hadSpaceMarker: hadSpace, hadNewlineMarker: hadNewline, hadLeadingWhitespace: leadingWS)
    }

    /// Regexes covering common assistant-scaffolding markers. We compile lazily once.
    private static let chatMarkerRegexes: [NSRegularExpression] = {
        let patterns = [
            #"^<\|[^|>]+\|>$"#,
            #"<start_of_turn>"#,
            #"<end_of_turn>"#,
            #"<\|im_start\|>"#,
            #"<\|im_end\|>"#,
            #"<\|endoftext\|>"#,
            #"<\|fim_(?:prefix|suffix|middle)\|>"#,
            #"###\s*(?:Response|Instruction|Input|Output)\s*:?"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    static func matchesChatMarker(_ text: String?) -> Bool {
        guard let text = text, !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in chatMarkerRegexes {
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        // General punctuation categories Pc/Pd/Pe/Pf/Pi/Po/Ps.
        scalar.properties.generalCategory.isPunctuation
    }

    private static func containsSentenceEnd(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            switch s {
            case ".", "?", "!", "\u{2026}",          // ASCII + horizontal ellipsis
                 "\u{201D}", "\u{2019}",              // ” ’
                 "\u{0022}", "\u{0027}",              // " '
                 "\u{0029}", "\u{005D}",              // ) ]
                 // Non-ASCII sentence terminators so the sentence-end stop works beyond Latin
                 // scripts. Disambiguation of false positives is the engine's job
                 // (`SentenceBoundary`); here we only need the candidate set.
                 "\u{3002}", "\u{FF01}", "\u{FF1F}", // 。 ！ ？ (CJK ideographic / fullwidth)
                 "\u{FF0E}", "\u{FF61}",              // ． ｡ (fullwidth / halfwidth full stop)
                 "\u{FF09}", "\u{FF3D}",              // ） ］ (fullwidth closing wrappers)
                 "\u{300D}", "\u{300F}",              // 」 』 (CJK closing quotes)
                 "\u{0964}", "\u{0965}",              // । ॥ (Devanagari danda / double danda)
                 "\u{06D4}", "\u{061F}",              // ۔ ؟ (Arabic full stop / question mark)
                 "\u{0589}", "\u{1362}",              // ։ ። (Armenian / Ethiopic full stop)
                 "\u{104A}", "\u{104B}",              // ၊ ။ (Myanmar little section / section)
                 "\u{037E}":                          // ; (Greek question mark)
                // NB: the ideographic comma 、 (U+3001) and Arabic comma ، are deliberately
                // NOT terminators.
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func containsEmoji(_ text: String) -> Bool {
        // ZWJ-joined emoji sequences are still detected because any participating scalar
        // (including the joiner-adjacent emoji) has `isEmoji && isEmojiPresentation`.
        for s in text.unicodeScalars where s.properties.isEmoji && s.properties.isEmojiPresentation {
            return true
        }
        return false
    }

    private static func firstNonWhitespaceScalar(_ text: String) -> Unicode.Scalar? {
        text.unicodeScalars.first(where: { !$0.properties.isWhitespace })
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.generalCategory.isNumber
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuation: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .closePunctuation,
             .finalPunctuation, .initialPunctuation, .otherPunctuation, .openPunctuation:
            return true
        default:
            return false
        }
    }

    var isNumber: Bool {
        switch self {
        case .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
