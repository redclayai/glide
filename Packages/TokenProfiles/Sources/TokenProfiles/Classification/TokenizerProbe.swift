import AutocompleteCore
import Foundation

/// Tokenizer-side attributes the classifier needs in order to decide a token's flags.
/// Mirrors `llama_token_attr` from `llama.h` (one bit per attribute) so an introspector
/// implemented on top of the llama C API can translate the enum without losing
/// information, and so the classifier can be tested without llama (synthetic probes set
/// these bits directly). New tokenizer backends provide their own probe.
public struct TokenAttr: OptionSet, Equatable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unknown      = TokenAttr(rawValue: 1 << 0)
    public static let unused       = TokenAttr(rawValue: 1 << 1)
    public static let normal       = TokenAttr(rawValue: 1 << 2)
    public static let control      = TokenAttr(rawValue: 1 << 3)
    public static let userDefined  = TokenAttr(rawValue: 1 << 4)
    public static let byte         = TokenAttr(rawValue: 1 << 5)
    public static let normalized   = TokenAttr(rawValue: 1 << 6)
    public static let lstrip       = TokenAttr(rawValue: 1 << 7)
    public static let rstrip       = TokenAttr(rawValue: 1 << 8)
    public static let singleWord   = TokenAttr(rawValue: 1 << 9)
}

/// Named role of a token within the tokenizer's special set. The introspector maps
/// `llama_vocab_bos/eos/eot/sep/nl/pad` (and any UNK lookup) to these tags so the
/// classifier's rules are independent of the tokenizer family.
public enum TokenRole: Equatable, Hashable {
    case bos
    case eos
    case eot
    case sep
    case nl
    case pad
    case unk
}

/// Snapshot of one token's source-of-truth state, fed into `TokenClassifier.classify`.
/// Pure value type so tests can construct probes without importing llama.
public struct TokenizerProbe: Equatable {
    public var tokenID: TokenID
    public var bytes: [UInt8]
    public var attr: TokenAttr
    public var role: TokenRole?
    /// `llama_vocab_is_control` (true also for chat markers exported as control tokens).
    public var isControl: Bool
    /// `llama_vocab_is_eog` ("end-of-generation"): EOS plus any extra termination tokens
    /// the tokenizer declares (Qwen's `<|im_end|>`, etc.).
    public var isEOG: Bool

    public init(
        tokenID: TokenID,
        bytes: [UInt8],
        attr: TokenAttr = [],
        role: TokenRole? = nil,
        isControl: Bool = false,
        isEOG: Bool = false
    ) {
        self.tokenID = tokenID
        self.bytes = bytes
        self.attr = attr
        self.role = role
        self.isControl = isControl
        self.isEOG = isEOG
    }
}
