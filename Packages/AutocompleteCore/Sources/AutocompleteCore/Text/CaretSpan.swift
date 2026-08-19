//
//  CaretSpan.swift
//  AutocompleteCore
//
//  A run of already-typed text immediately behind the caret, plus the seam for replacing it
//  through the accessibility API. Rewrites (unlike completions) have to *remove* text before
//  they write, and the two removal units differ: the AX API addresses text in UTF-16 units,
//  while a synthesized arrow keystroke moves by one grapheme cluster. A span carries the
//  original substring so callers can ask for whichever count they need instead of guessing.
//

import Foundation

/// The stretch of text a rewrite intends to replace, anchored to end at the caret.
public struct CaretSpan: Equatable {
    /// The text currently in the field, ending at the caret.
    public let original: String

    public init(original: String) {
        self.original = original
    }

    /// Length in UTF-16 units — the unit the accessibility API addresses text in.
    public var utf16Length: Int { original.utf16.count }

    /// Length in grapheme clusters — the unit one arrow or delete keystroke moves by.
    public var keystrokeLength: Int { original.count }

    public var isEmpty: Bool { original.isEmpty }

    /// Resolve the span ending at the caret from the text before the caret.
    /// Returns nil when `beforeCursor` is shorter than the requested span.
    public static func trailing(of beforeCursor: String, keystrokeLength length: Int) -> CaretSpan? {
        guard length > 0, beforeCursor.count >= length else { return nil }
        return CaretSpan(original: String(beforeCursor.suffix(length)))
    }
}

/// Seam for replacing the span behind the caret through the accessibility API.
///
/// The AX path is the only mechanism that can be *verified* — after writing we re-read the
/// element and confirm the text landed. Keystroke-based replacement is fire-and-forget, which
/// is why a caller must never chain two keystroke mechanisms after each other: a partially
/// applied selection followed by a second attempt corrupts the user's text.
@MainActor
public protocol CaretSpanReplacing {
    /// Replace the span immediately preceding the caret with `replacement`.
    ///
    /// Implementations must confirm the field still holds `span.original` at the caret before
    /// writing — the user may have typed since the rewrite was computed — and must verify the
    /// result afterwards.
    ///
    /// Returns `true` only when the write was applied *and* verified. A `false` return means the
    /// focused element refused the write (common in web and Electron fields) or the field moved
    /// underneath us; the caller should fall back to synthesized keystrokes.
    func replaceBehindCaret(_ span: CaretSpan, with replacement: String) -> Bool
}
