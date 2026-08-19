import Foundation

/// Resolves the tokenizer-family identifier for a model file.
///
/// The family string is used twice: it names the model's ACPF profile (`<family>.acpf.bin`) and it
/// is validated against the family stamped inside that profile when the runtime opens it. The ACPF
/// builder and the runtime must therefore agree on the same string, so this is the single source of
/// truth for both the build path (`ProfileGenerator`) and the load path (`CompletionController`).
public enum ModelFamilyResolver {

    /// Family for `filename`. Catalog models declare their family directly; an imported/unknown
    /// GGUF gets a stable family derived from its base name and tokenizer vocabulary size, so two
    /// different tokenizers can never collide on one profile file.
    public static func family(forFilename filename: String, vocabSize: Int) -> String {
        if let model = RuntimeModelCatalog.model(forFilename: filename) {
            return model.tokenizerFamily
        }
        return derivedFamily(forFilename: filename, vocabSize: vocabSize)
    }

    /// Deterministic `<sanitized-base-name>-v<vocabSize>` family for an off-catalog model.
    public static func derivedFamily(forFilename filename: String, vocabSize: Int) -> String {
        let base = (filename as NSString).deletingPathExtension
        let sanitized = base
            .lowercased()
            .map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var collapsed = ""
        var lastWasDash = false
        for character in sanitized {
            if character == "-" {
                if !lastWasDash { collapsed.append(character) }
                lastWasDash = true
            } else {
                collapsed.append(character)
                lastWasDash = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = trimmed.isEmpty ? "model" : trimmed
        return "\(stem)-v\(vocabSize)"
    }
}
