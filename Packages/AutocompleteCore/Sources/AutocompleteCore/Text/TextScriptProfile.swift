import Foundation

public enum TextSubstantiveScript: Equatable {
    case latin
    case cjk
    case other
}

public enum TextScriptProfile {
    public static func firstSubstantiveScript(in text: String) -> TextSubstantiveScript? {
        for character in text {
            if let script = substantiveScript(of: character) {
                return script
            }
        }
        return nil
    }

    public static func lastSubstantiveScript(in text: String) -> TextSubstantiveScript? {
        for character in text.reversed() {
            if let script = substantiveScript(of: character) {
                return script
            }
        }
        return nil
    }

    public static func containsCJK(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    public static func containsLatinLetter(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isLatinLetter)
    }

    public static func hasMajorScriptChange(anchor: TextFieldContext, live: TextFieldContext) -> Bool {
        guard let anchorScript = lastSubstantiveScript(in: anchor.beforeCursor),
              let liveScript = lastSubstantiveScript(in: live.beforeCursor) else {
            return false
        }
        return anchorScript != liveScript
    }

    private static func substantiveScript(of character: Character) -> TextSubstantiveScript? {
        var sawOtherLetterOrNumber = false
        for scalar in character.unicodeScalars {
            if isCJKScalar(scalar) {
                return .cjk
            }
            if isLatinLetter(scalar) {
                return .latin
            }
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                sawOtherLetterOrNumber = true
            }
        }
        return sawOtherLetterOrNumber ? .other : nil
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, // Basic Latin uppercase
             0x0061...0x007A, // Basic Latin lowercase
             0x00C0...0x024F, // Latin-1 supplement, Extended-A/B
             0x1E00...0x1EFF: // Latin Extended Additional
            return CharacterSet.letters.contains(scalar)
        default:
            return false
        }
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0x1100...0x11FF,   // Hangul jamo
             0x3130...0x318F,   // Hangul compatibility jamo
             0xA960...0xA97F,   // Hangul jamo extended-A
             0xD7B0...0xD7FF,   // Hangul jamo extended-B
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
             0x2A700...0x2B73F, // Extension C
             0x2B740...0x2B81F, // Extension D
             0x2B820...0x2CEAF, // Extension E/F
             0x2CEB0...0x2EBEF, // Extension F/G
             0x30000...0x3134F: // Extension G/H
            return true
        default:
            return false
        }
    }
}
