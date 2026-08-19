import AutocompleteCore
import Foundation

/// One live path through the search tree: the tokens emitted so far plus the derived
/// display state. Branches accumulate raw bytes (not strings) so detokenization can be
/// validated incrementally — a token that ends mid multi-byte sequence is *pending*, not
/// invalid, and only becomes text once the trailing bytes arrive.
struct GenerationBranch: Equatable {
    /// Completion tokens emitted on this branch (excludes the prompt).
    var tokenIDs: [TokenID]
    /// Raw bytes for every emitted token, concatenated in order.
    var bytes: [UInt8]
    /// Byte count contributed by each emitted token, parallel to `tokenIDs`. Lets a finalized branch
    /// be re-walked token-by-token (e.g. truncate at a character boundary) without re-deriving the
    /// per-token split from a byte resolver. See `truncatedToText(prefixCharCount:)`.
    var tokenByteLengths: [Int]
    /// Per-token log-probability, parallel to `tokenIDs`. Sums to `score`; kept so a truncated
    /// branch can recompute its score from exactly the tokens it retains.
    var tokenLogProbabilities: [Float]
    /// Decoded text = the maximal valid-UTF-8 prefix of `bytes`.
    var text: String
    /// Cumulative display width, measured as grapheme clusters of the decoded `text`.
    var displayWidth: Int
    /// Cumulative log-probability (sum of per-token log-probs). Larger is better.
    var score: Float
    /// Required prefix bytes still to be satisfied before the branch is free to continue.
    var remainingPrefix: [UInt8]

    init(requiredPrefix: [UInt8] = []) {
        self.tokenIDs = []
        self.bytes = []
        self.tokenByteLengths = []
        self.tokenLogProbabilities = []
        self.text = ""
        self.displayWidth = 0
        self.score = 0
        self.remainingPrefix = requiredPrefix
    }

    /// `true` once every required-prefix byte has been consumed.
    var prefixSatisfied: Bool { remainingPrefix.isEmpty }

    /// Outcome of trying to extend a branch with one token.
    enum Extension: Equatable {
        case extended(GenerationBranch)
        case inadmissiblePrefix
        case invalidUTF8
        case overWidth
    }

    /// Produce the branch that results from emitting `tokenID` (with raw `tokenBytes` and
    /// `logProbability`), or a reason it must be dropped.
    func extending(
        withToken tokenID: TokenID,
        bytes tokenBytes: [UInt8],
        logProbability: Float,
        maxDisplayWidth: Int
    ) -> Extension {
        guard let newRemaining = Self.consumePrefix(remainingPrefix, tokenBytes) else {
            return .inadmissiblePrefix
        }

        var newBytes = bytes
        newBytes.append(contentsOf: tokenBytes)

        switch UTF8Scanner.scan(newBytes) {
        case .invalid:
            return .invalidUTF8
        case let .valid(validByteCount), let .pending(validByteCount):
            let newText = String(decoding: newBytes[0..<validByteCount], as: UTF8.self)
            // Display width advances by the *grapheme-cluster* delta of the decoded text, not by a
            // per-token width sum. This is the language-fair measure: a combining mark
            // (Arabic/Devanagari/Hebrew/Thai vowel signs and tone marks) attaches to the previous
            // cluster and adds 0 columns; bytes that only partially complete a multi-byte character
            // add 0 until the cluster closes; and a byte-fallback CJK character split across several
            // single-byte tokens is counted once when it completes, not once per byte. (A per-token
            // sum over-counts all three and truncates non-Latin completions early.)
            let charDelta = newText.count - text.count
            let newWidth = displayWidth + Swift.max(charDelta, 0)
            if newWidth > maxDisplayWidth {
                return .overWidth
            }
            var next = self
            next.tokenIDs.append(tokenID)
            next.tokenByteLengths.append(tokenBytes.count)
            next.tokenLogProbabilities.append(logProbability)
            next.bytes = newBytes
            next.text = newText
            next.displayWidth = newWidth
            next.score += logProbability
            next.remainingPrefix = newRemaining
            return .extended(next)
        }
    }

    /// `true` iff the branch is emittable: it has decoded text and the required prefix is
    /// satisfied. A merely *pending* trailing multi-byte sequence is fine — `text` already holds
    /// only the maximal valid-UTF-8 prefix, so we emit the complete characters and silently drop
    /// the partial tail. This matters for byte-fallback scripts (a CJK/Thai/Indic character split
    /// across single-byte tokens) where a branch can hit the token-depth cap mid-character;
    /// without this it would be dropped entirely and the user would get no completion at all.
    /// Only a genuinely malformed sequence (`.invalid`) disqualifies a branch.
    var isCompleteAndValid: Bool {
        guard prefixSatisfied, !text.isEmpty else { return false }
        switch UTF8Scanner.scan(bytes) {
        case .valid, .pending:
            return true
        case .invalid:
            return false
        }
    }

    /// A copy of this branch keeping only the leading whole tokens whose decoded text stays within
    /// `prefixCharCount` grapheme clusters. Used to salvage a mid-line / FIM branch by cutting it at
    /// the suffix-overlap point (see `SuffixOverlapGuard.nonDuplicatingPrefixLength` and ADR-057)
    /// rather than discarding it. Token boundaries that don't align with the character boundary are
    /// rounded **down** (never keep a token that would reach into the duplicated suffix), and the
    /// score/displayWidth are recomputed from exactly the retained tokens.
    func truncatedToText(prefixCharCount: Int) -> GenerationBranch {
        if prefixCharCount <= 0 {
            return GenerationBranch() // empty text → caller treats as "nothing to insert"
        }
        if text.count <= prefixCharCount {
            return self
        }

        let keptByteCount = String(text.prefix(prefixCharCount)).utf8.count
        var cumulativeBytes = 0
        var keptTokenCount = 0
        while keptTokenCount < tokenByteLengths.count,
              cumulativeBytes + tokenByteLengths[keptTokenCount] <= keptByteCount {
            cumulativeBytes += tokenByteLengths[keptTokenCount]
            keptTokenCount += 1
        }

        var result = GenerationBranch()
        result.tokenIDs = Array(tokenIDs.prefix(keptTokenCount))
        result.tokenByteLengths = Array(tokenByteLengths.prefix(keptTokenCount))
        result.tokenLogProbabilities = Array(tokenLogProbabilities.prefix(keptTokenCount))
        result.bytes = Array(bytes.prefix(cumulativeBytes))
        result.score = result.tokenLogProbabilities.reduce(0, +)
        // A token-aligned prefix of valid bytes may still split a byte-fallback multi-byte character;
        // keep only the maximal valid-UTF-8 prefix, exactly as `extending` does.
        switch UTF8Scanner.scan(result.bytes) {
        case let .valid(validByteCount), let .pending(validByteCount):
            result.text = String(decoding: result.bytes[0..<validByteCount], as: UTF8.self)
        case .invalid:
            result.text = ""
        }
        result.displayWidth = result.text.count
        return result
    }

    /// Returns the remaining required prefix after consuming `tokenBytes`, or `nil` if the
    /// token is inadmissible. Mirrors `AutocompleteProfile.tokenAllowed(_:afterRequiredPrefix:)`
    /// (`bytes.starts(with: prefix) || prefix.starts(with: bytes)`) and additionally tracks
    /// how much of the prefix is left.
    static func consumePrefix(_ remaining: [UInt8], _ tokenBytes: [UInt8]) -> [UInt8]? {
        if remaining.isEmpty { return [] }
        if tokenBytes.count >= remaining.count {
            return tokenBytes.starts(with: remaining) ? [] : nil
        }
        return remaining.starts(with: tokenBytes) ? Array(remaining.dropFirst(tokenBytes.count)) : nil
    }
}

/// Minimal forward UTF-8 validator that distinguishes a genuinely malformed sequence from a
/// merely-incomplete trailing multi-byte sequence (which more tokens may complete).
enum UTF8Scanner {
    enum Result: Equatable {
        /// All bytes form complete, valid scalars. Associated value = total byte count.
        case valid(Int)
        /// A valid prefix followed by an incomplete-but-completable trailing sequence.
        /// Associated value = number of fully-valid leading bytes.
        case pending(Int)
        /// A byte sequence that can never be valid UTF-8.
        case invalid
    }

    static func scan(_ bytes: [UInt8]) -> Result {
        var i = 0
        let n = bytes.count
        while i < n {
            let lead = bytes[i]
            let length: Int
            if lead & 0x80 == 0x00 {
                length = 1
            } else if lead & 0xE0 == 0xC0 {
                length = 2
            } else if lead & 0xF0 == 0xE0 {
                length = 3
            } else if lead & 0xF8 == 0xF0 {
                length = 4
            } else {
                return .invalid // continuation byte as lead, or illegal 0xC0/0xC1/0xF5+
            }

            let available = n - i
            let toCheck = Swift.min(length, available)
            for j in 1..<toCheck where bytes[i + j] & 0xC0 != 0x80 {
                return .invalid // expected continuation byte
            }
            if available < length {
                return .pending(i) // trailing bytes so far are valid continuations
            }
            i += length
        }
        return .valid(n)
    }
}
