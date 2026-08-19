import Foundation
import LlamaModelRuntime
import ModelManagement
import ModelRuntime
import ProfileBuilderCore
import TokenProfiles
import os

/// Builds the ACPF token profile (`<family>.acpf.bin`) that the constrained decoder needs, by
/// reading the downloaded GGUF's tokenizer in-process.
///
/// This is the in-app equivalent of the `acpf-build` CLI: it loads the model with a tiny context,
/// drives `BuildProfile.run` over a `LlamaVocabIntrospector`, writes the profile next to the GGUF,
/// then frees the llama context/model up front (ggml-metal asserts at process exit if the GPU
/// residency sets were never released — see ADR-021). The work is heavy (it touches every token),
/// so it runs off the main actor.
public enum ProfileGenerator {

    public enum GenerationError: Error, CustomStringConvertible {
        case modelMissing(String)
        public var description: String {
            switch self {
            case let .modelMissing(name):
                return "Model file '\(name)' not found in the Models directory."
            }
        }
    }

    /// Ensures an ACPF profile exists for `filename`'s tokenizer family. Returns the resolved
    /// family. A no-op (returns the family) when the profile is already present.
    @discardableResult
    public static func generateProfileIfNeeded(forModelFilename filename: String) async throws -> String {
        let log = Logger(subsystem: "com.pattonium.KeyType", category: "profile-generation")
        let modelURL = try ModelContainer.modelURL(filename: filename)
        guard ModelContainer.modelExists(at: modelURL) else {
            throw GenerationError.modelMissing(filename)
        }

        // A small context is plenty: the builder only reads tokenizer metadata, it does not decode.
        let runtime = try LlamaModelRuntime(modelURL: modelURL, contextLength: 256, reuseThreshold: 0)
        defer { Task { await runtime.shutdown() } }

        let vocabSize = runtime.metadata.vocabularySize
        let family = ModelFamilyResolver.family(forFilename: filename, vocabSize: vocabSize)
        let outputURL = try ModelContainer.profileURL(family: family, create: true)
        let introspector = runtime.makeIntrospector()

        // Only trust an existing profile if it still opens and validates. A profile left behind by a
        // previously failed/interrupted build would otherwise be reused unchecked — the exact reason a
        // failed "Prepare" used to look fixed after a retry (the bad file was present, so the rebuild
        // was skipped). Validation here is the same check the runtime applies at load time.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if Self.profileIsValid(at: outputURL, vocabSize: vocabSize, family: family, introspector: introspector) {
                log.info("ACPF profile for family \(family, privacy: .public) already present and valid; skipping build")
                return family
            }
            log.error("Existing ACPF profile for family \(family, privacy: .public) failed validation; rebuilding")
            try? FileManager.default.removeItem(at: outputURL)
        }

        log.info("Building ACPF profile for \(filename, privacy: .public) (family \(family, privacy: .public))")
        // Build into a sibling temp file and only move it into place once `BuildProfile.run`'s
        // post-write self-check has passed. A self-check failure therefore never leaves a usable
        // artifact behind, so a retry actually rebuilds instead of trusting a file that failed
        // validation.
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).building-\(UUID().uuidString)")
        do {
            try BuildProfile.run(
                introspector: introspector,
                family: family,
                output: tempURL,
                reporter: ConsoleReporter(isQuiet: true)
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        log.info("ACPF profile written to \(outputURL.path, privacy: .public)")
        return family
    }

    /// Whether the on-disk profile at `url` opens and validates against the live tokenizer — i.e. the
    /// header invariants hold and the stamped tokenizer digest matches this model's vocab. Mirrors the
    /// runtime's load-time check so setup never trusts a profile the runtime would later reject.
    private static func profileIsValid(
        at url: URL,
        vocabSize: Int,
        family: String,
        introspector: LlamaVocabIntrospector
    ) -> Bool {
        do {
            _ = try MmapAutocompleteProfile.open(
                at: url,
                tokenizerVocabSize: vocabSize,
                tokenizerBytes: { try introspector.bytes(for: $0) },
                expectedModelFamily: family
            )
            return true
        } catch {
            return false
        }
    }
}
