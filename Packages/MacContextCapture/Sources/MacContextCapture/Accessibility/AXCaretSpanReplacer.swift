//
//  AXCaretSpanReplacer.swift
//  MacContextCapture
//
//  The accessibility path for rewrite replacement: select the span behind the caret via
//  `AXSelectedTextRange`, then overwrite it via `AXSelectedText`. When it works this is by far the
//  best mechanism — no synthesized keystrokes, no pasteboard round-trip, no visible flicker, and
//  it is the only path whose result can be verified.
//
//  It refuses rather than guesses. Three gates must pass before anything is written:
//
//    1. The focused element must expose a settable `AXSelectedTextRange`. Native AppKit text
//       controls do; most web and Electron fields do not.
//    2. The caret must be a collapsed insertion point (nothing selected) with at least the span's
//       worth of text behind it.
//    3. The text actually sitting behind the caret must still equal what the rewrite was computed
//       against — the user keeps typing while the model works, and replacing a stale span would
//       eat characters.
//
//  After writing, the element is re-read and the replacement confirmed. Any failure returns false
//  so `PasteboardTextReplacer` falls back to keystrokes. See ADR-104.
//

import AppKit
import ApplicationServices
import AutocompleteCore
import Foundation

@MainActor
public final class AXCaretSpanReplacer: CaretSpanReplacing {
    public init() {}

    public func replaceBehindCaret(_ span: CaretSpan, with replacement: String) -> Bool {
        guard !span.isEmpty, !replacement.isEmpty else { return false }
        guard let element = AXCaretHelper.focusedElementInFrontmostApplication() else { return false }

        let selectedRangeAttribute = kAXSelectedTextRangeAttribute as CFString
        let selectedTextAttribute = kAXSelectedTextAttribute as CFString

        guard AXCaretHelper.isAttributeSettable(selectedRangeAttribute, on: element),
              AXCaretHelper.isAttributeSettable(selectedTextAttribute, on: element)
        else { return false }

        guard let caretRange = AXCaretHelper.rangeValue(for: selectedRangeAttribute, on: element),
              caretRange.length == 0,
              let value = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
        else { return false }

        let spanLength = span.utf16Length
        let spanStart = caretRange.location - spanLength
        guard spanStart >= 0 else { return false }

        let utf16 = Array(value.utf16)
        guard caretRange.location <= utf16.count else { return false }

        // Gate 3: the field must still hold the text this rewrite was computed against.
        let currentSpan = String(decoding: utf16[spanStart..<caretRange.location], as: UTF16.self)
        guard currentSpan == span.original else { return false }

        let spanRange = NSRange(location: spanStart, length: spanLength)
        guard setRange(spanRange, attribute: selectedRangeAttribute, on: element) else { return false }
        guard AXUIElementSetAttributeValue(element, selectedTextAttribute, replacement as CFTypeRef) == .success
        else {
            // Leave the caret where we found it rather than stranding a selection the user would
            // overtype on their next keystroke.
            _ = setRange(NSRange(location: caretRange.location, length: 0), attribute: selectedRangeAttribute, on: element)
            return false
        }

        return verify(replacement: replacement, spanStart: spanStart, on: element)
    }

    public func currentSelection() -> String? {
        guard let element = AXCaretHelper.focusedElementInFrontmostApplication() else { return nil }
        let selected = AXCaretHelper.stringValue(for: kAXSelectedTextAttribute as CFString, on: element)
        // An empty string is a real answer — "the caret is collapsed" — and must not be flattened
        // into nil, because that is exactly the state worth catching.
        return selected
    }

    // MARK: - Helpers

    private func setRange(_ range: NSRange, attribute: CFString, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    /// Confirm the replacement really landed: the element's value must now contain `replacement`
    /// starting where the old span began. Some elements report `.success` on a write they silently
    /// dropped, which is exactly the case the keystroke fallback exists for.
    private func verify(replacement: String, spanStart: Int, on element: AXUIElement) -> Bool {
        guard let updated = AXCaretHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
        else { return false }

        let utf16 = Array(updated.utf16)
        let replacementLength = replacement.utf16.count
        let end = spanStart + replacementLength
        guard end <= utf16.count else { return false }

        return String(decoding: utf16[spanStart..<end], as: UTF16.self) == replacement
    }
}
