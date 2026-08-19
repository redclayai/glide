import AutocompleteCore
import Foundation
@testable import TokenProfiles

/// Synthetic vocabulary fixture exercising every classifier path. Used by every test in
/// this suite so a single change ripples through them all. The fixture is small but
/// covers: ASCII letters/digits/punctuation, sentence-end punctuation, leading-space
/// (`Ġfoo`), `▁foo`, newline tokens (`Ċ`), multi-byte UTF-8 (`é`, `日`, family emoji),
/// an invalid mid-byte (`0xC3`), and named specials (`<bos>`, `<eos>`, `<eot>`,
/// `<unk>`, `<pad>`, `<|im_start|>`, `<|im_end|>`, `### Response:`).
enum SyntheticVocabFixture {

    struct Built {
        let probes: [TokenizerProbe]
        let entries: [ACPFTokenEntry]
        let digest: ACPFTokenizerDigestValue
        /// Expected flags for diagnostics-friendly cases (only the explicit cases we
        /// assert against in `ClassifierFlagTests`).
        let expectedFlagSamples: [TokenID: TokenProfileFlags]
        let modelFamily: String
        let vocabSize: Int
        let probeByID: [TokenID: TokenizerProbe]
    }

    struct Spec {
        let bytes: [UInt8]
        var attr: TokenAttr = []
        var role: TokenRole? = nil
        var isControl: Bool = false
        var isEOG: Bool = false
        var expectedFlags: TokenProfileFlags? = nil
    }

    static func build(modelFamily: String = "synthetic-v128") -> Built {
        var specs: [Spec] = []

        // 0-25: ASCII letters a..z
        for byte: UInt8 in 0x61...0x7A {
            specs.append(Spec(bytes: [byte], attr: .normal))
        }
        // 26-35: digits 0..9
        for byte: UInt8 in 0x30...0x39 {
            specs.append(Spec(bytes: [byte], attr: .normal))
        }
        // 36-41: common ASCII punctuation . , ; : ? !
        for ch: Character in [".", ",", ";", ":", "?", "!"] {
            specs.append(Spec(bytes: Array(String(ch).utf8), attr: .normal))
        }
        // 42-44: leading-space (Ġ) word tokens
        specs.append(Spec(bytes: bytes("\u{0120}the"), attr: .normal))
        specs.append(Spec(bytes: bytes("\u{0120}foo"), attr: .normal))
        specs.append(Spec(bytes: bytes("\u{0120}123"), attr: .normal))
        // 45-46: SentencePiece-style ▁word
        specs.append(Spec(bytes: bytes("\u{2581}bar"), attr: .normal))
        specs.append(Spec(bytes: bytes("\u{2581}baz"), attr: .normal))
        // 47: newline marker Ċ alone
        specs.append(Spec(bytes: bytes("\u{010A}"), attr: .normal))
        // 48: raw "\n"
        specs.append(Spec(bytes: [0x0A], attr: .normal))
        // 49: repeated whitespace (4 spaces)
        specs.append(Spec(bytes: [0x20, 0x20, 0x20, 0x20], attr: .normal))
        // 50-52: multi-byte UTF-8: é, 日, 🙂
        specs.append(Spec(bytes: bytes("é"), attr: .normal))
        specs.append(Spec(bytes: bytes("日"), attr: .normal))
        specs.append(Spec(bytes: bytes("🙂"), attr: .normal))
        // 53: family ZWJ emoji
        specs.append(Spec(bytes: bytes("👨‍👩‍👧"), attr: .normal))
        // 54: invalid UTF-8 byte fallback (single 0xC3 = start of multi-byte sequence)
        specs.append(Spec(bytes: [0xC3], attr: .byte))
        // 55: another byte-fallback (0x9A — continuation byte)
        specs.append(Spec(bytes: [0x9A], attr: .byte))
        // 56-60: named specials
        specs.append(Spec(bytes: bytes("<bos>"), attr: .control, role: .bos, isControl: true))
        specs.append(Spec(bytes: bytes("<eos>"), attr: .control, role: .eos, isControl: true, isEOG: true))
        specs.append(Spec(bytes: bytes("<eot>"), attr: .control, role: .eot, isControl: true, isEOG: true))
        specs.append(Spec(bytes: bytes("<unk>"), attr: [.control, .unknown], role: .unk, isControl: true))
        specs.append(Spec(bytes: bytes("<pad>"), attr: .control, role: .pad, isControl: true))
        // 61-64: chat markers
        specs.append(Spec(bytes: bytes("<|im_start|>"), attr: .userDefined, isControl: true))
        specs.append(Spec(bytes: bytes("<|im_end|>"), attr: .userDefined, isControl: true, isEOG: true))
        specs.append(Spec(bytes: bytes("<|endoftext|>"), attr: .userDefined, isControl: true, isEOG: true))
        specs.append(Spec(bytes: bytes("### Response:"), attr: .normal))
        // 65: sentence-end punctuation token "you."
        specs.append(Spec(bytes: bytes("you."), attr: .normal))
        // 66: word-continuation token "ing"
        specs.append(Spec(bytes: bytes("ing"), attr: .normal))
        // 67: a long token (32+ bytes)
        let longText = String(repeating: "a", count: 40)
        specs.append(Spec(bytes: bytes(longText), attr: .normal))
        // 68: empty bytes (unused slot)
        specs.append(Spec(bytes: [], attr: .unused))

        // Pad to a round vocab size with simple ASCII fillers so the trie has
        // some breadth.
        while specs.count < 96 {
            let n = specs.count
            specs.append(Spec(bytes: bytes("t\(n)"), attr: .normal))
        }

        var probes: [TokenizerProbe] = []
        var entries: [ACPFTokenEntry] = []
        var samples: [TokenID: TokenProfileFlags] = [:]
        var probeByID: [TokenID: TokenizerProbe] = [:]

        for (i, spec) in specs.enumerated() {
            let tokenID = TokenID(i)
            let probe = TokenizerProbe(
                tokenID: tokenID,
                bytes: spec.bytes,
                attr: spec.attr,
                role: spec.role,
                isControl: spec.isControl,
                isEOG: spec.isEOG
            )
            probes.append(probe)
            probeByID[tokenID] = probe

            let cls = TokenClassifier.classify(probe)
            let staticBias = BiasPolicy.staticBias(flags: cls.flags, displayWidth: cls.displayWidth, bytes: spec.bytes)
            entries.append(ACPFTokenEntry(
                tokenID: tokenID,
                bytes: spec.bytes,
                flags: cls.flags,
                staticBias: staticBias,
                displayWidth: cls.displayWidth,
                tokenType: cls.tokenType
            ))
            if let expected = spec.expectedFlags {
                samples[tokenID] = expected
            }
        }

        let vocabSize = specs.count
        // Build a deterministic byte source for the digest.
        let digest = ACPFTokenizerDigest.digest(vocabSize: vocabSize) { id in
            probes[Int(id)].bytes
        }

        return Built(
            probes: probes,
            entries: entries,
            digest: digest,
            expectedFlagSamples: samples,
            modelFamily: modelFamily,
            vocabSize: vocabSize,
            probeByID: probeByID
        )
    }

    /// Convenience: build a fixture and serialise it into a `Data` profile image. Tests
    /// that exercise the on-disk format only ever go through this.
    static func buildAndEncode() throws -> (built: Built, data: Data) {
        let built = build()
        let input = ACPFProfileInput(
            modelFamily: built.modelFamily,
            vocabSize: built.vocabSize,
            tokenizerDigest: built.digest,
            entries: built.entries,
            ggufMetadataDigest: "synthetic-gguf-digest",
            generatorVersion: ACPF.generatorVersion,
            builderHost: "synthetic-host",
            buildTimestamp: Date(timeIntervalSince1970: 1_716_000_000),
            headerFlags: 0
        )
        let data = try ACPFWriter.encode(input)
        return (built, data)
    }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
}
