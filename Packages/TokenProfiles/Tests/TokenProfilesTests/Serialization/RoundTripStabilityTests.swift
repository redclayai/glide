import AutocompleteCore
import XCTest
@testable import TokenProfiles

/// Round-trip stability — applying the engine's filter+bias+sort pipeline to scripted
/// logits must yield identical candidate orderings before and after serialisation. This
/// is M4's core acceptance: "round-trip candidate sets are stable across serialization".
///
/// We deliberately don't compare against `InMemoryAutocompleteProfile`: that pre-M4
/// type only carries `static_bias` and has no notion of per-mode deltas, so its bias
/// function would diverge from the mmap reader by design. The right round-trip check
/// compares two `MmapAutocompleteProfile` instances built from the same input — if the
/// encoder is deterministic and the decoder is a faithful inverse of the encoder, the
/// rankings must agree.
final class RoundTripStabilityTests: XCTestCase {

    func testCandidateSetIsStableAcrossSerialization() throws {
        let built = SyntheticVocabFixture.build()
        let input = makeInput(built: built)
        let data1 = try ACPFWriter.encode(input)
        let data2 = try ACPFWriter.encode(input)
        XCTAssertEqual(data1, data2, "encoder must be deterministic for identical input")

        let profile1 = try MmapAutocompleteProfile(data: data1)
        let profile2 = try MmapAutocompleteProfile(data: data2)
        let logits = makeLogits(vocabSize: built.vocabSize, seed: 7)
        for mode in allModes() {
            for isSingleLine in [false, true] {
                let prefix: [UInt8] = []
                let r1 = pickTopK(profile: profile1, logits: logits, mode: mode, isSingleLine: isSingleLine, requiredPrefix: prefix)
                let r2 = pickTopK(profile: profile2, logits: logits, mode: mode, isSingleLine: isSingleLine, requiredPrefix: prefix)
                XCTAssertEqual(r1, r2,
                               "ranking diverged in mode \(mode) singleLine=\(isSingleLine)")
            }
        }
    }

    func testCandidateSetIsStableAcrossRequiredPrefixes() throws {
        let built = SyntheticVocabFixture.build()
        let input = makeInput(built: built)
        let data1 = try ACPFWriter.encode(input)
        let data2 = try ACPFWriter.encode(input)
        let profile1 = try MmapAutocompleteProfile(data: data1)
        let profile2 = try MmapAutocompleteProfile(data: data2)
        let logits = makeLogits(vocabSize: built.vocabSize, seed: 11)
        let prefixes: [[UInt8]] = [
            [],
            Array("\u{0120}".utf8),
            Array("\u{0120}t".utf8),
            Array("a".utf8),
            Array("ing".utf8)
        ]
        for prefix in prefixes {
            let r1 = pickTopK(profile: profile1, logits: logits, mode: .prose, isSingleLine: false, requiredPrefix: prefix)
            let r2 = pickTopK(profile: profile2, logits: logits, mode: .prose, isSingleLine: false, requiredPrefix: prefix)
            XCTAssertEqual(r1, r2, "ranking diverged for prefix \(prefix)")
        }
    }

    /// Spec invariant: `bias(for:mode:isSingleLine:)` returns the policy's static bias
    /// plus the per-mode delta plus, when `isSingleLine`, the single-line delta.
    func testBiasValuesMatchPolicy() throws {
        let built = SyntheticVocabFixture.build()
        let input = makeInput(built: built)
        let data = try ACPFWriter.encode(input)
        let profile = try MmapAutocompleteProfile(data: data)
        for entry in built.entries {
            for cm in [CompletionMode.prose, .code, .terminal, .emoji, .correction] {
                let biasMode = BiasMode(cm)
                for isSL in [false, true] {
                    let expected = entry.staticBias
                        + BiasPolicy.delta(flags: entry.flags, mode: biasMode, bytes: entry.bytes)
                        + (isSL ? BiasPolicy.delta(flags: entry.flags, mode: .singleLine, bytes: entry.bytes) : 0)
                    let got = profile.bias(for: entry.tokenID, mode: cm, isSingleLine: isSL)
                    if expected.isFinite && got.isFinite {
                        XCTAssertEqual(got, expected, accuracy: 1e-6,
                                       "bias drift token=\(entry.tokenID) mode=\(cm) sl=\(isSL)")
                    } else {
                        XCTAssertEqual(got, expected,
                                       "bias drift (non-finite) token=\(entry.tokenID) mode=\(cm) sl=\(isSL)")
                    }
                }
            }
        }
    }

    /// Spec invariant: `isExcluded(_:mode:isSingleLine:)` mirrors the mmap rules across
    /// modes/single-line; this is what `ConstrainedGenerationEngine` consults.
    func testIsExcludedMatchesSpec() throws {
        let built = SyntheticVocabFixture.build()
        let input = makeInput(built: built)
        let data = try ACPFWriter.encode(input)
        let profile = try MmapAutocompleteProfile(data: data)
        for entry in built.entries {
            for cm in [CompletionMode.prose, .code, .terminal, .emoji, .correction] {
                for isSL in [false, true] {
                    let f = entry.flags
                    var expected = false
                    if f.contains(.excluded) || f.contains(.special) || f.contains(.chatMarker) {
                        expected = true
                    } else if cm != .emoji && f.contains(.emoji) {
                        expected = true
                    } else if cm == .prose && f.contains(.newline) {
                        expected = true
                    } else if isSL && f.contains(.newline) {
                        expected = true
                    }
                    let got = profile.isExcluded(entry.tokenID, mode: cm, isSingleLine: isSL)
                    XCTAssertEqual(got, expected,
                                   "excluded mismatch token=\(entry.tokenID) mode=\(cm) sl=\(isSL) flags=\(f.rawValue)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func allModes() -> [CompletionMode] { [.prose, .code, .terminal, .emoji, .correction] }

    private func makeInput(built: SyntheticVocabFixture.Built) -> ACPFProfileInput {
        ACPFProfileInput(
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
    }

    private func makeLogits(vocabSize: Int, seed: UInt64) -> [Float] {
        var state = seed | 1
        var logits = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: state >> 32)
            logits[i] = Float(bits) / Float(UInt32.max) * 6.0 - 3.0
        }
        return logits
    }

    private func pickTopK(
        profile: MmapAutocompleteProfile,
        logits: [Float],
        mode: CompletionMode,
        isSingleLine: Bool,
        requiredPrefix: [UInt8],
        topK: Int = 16
    ) -> [TokenID] {
        var scored: [(TokenID, Float)] = []
        scored.reserveCapacity(logits.count)
        for (i, raw) in logits.enumerated() {
            let id = TokenID(i)
            if profile.isExcluded(id, mode: mode, isSingleLine: isSingleLine) { continue }
            if !profile.tokenAllowed(id, afterRequiredPrefix: requiredPrefix) { continue }
            let bias = profile.bias(for: id, mode: mode, isSingleLine: isSingleLine)
            let score = raw + bias
            if !score.isFinite { continue }
            scored.append((id, score))
        }
        scored.sort { a, b in
            if a.1 == b.1 { return a.0 < b.0 }
            return a.1 > b.1
        }
        return scored.prefix(topK).map { $0.0 }
    }
}
