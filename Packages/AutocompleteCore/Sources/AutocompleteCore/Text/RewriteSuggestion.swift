//
//  RewriteSuggestion.swift
//  AutocompleteCore
//
//  The rewrite path's counterpart to `CompletionCandidate`. A completion is text to *append* at
//  the caret; a rewrite is a span behind the caret plus what should stand in its place.
//
//  Keeping the two separate matters: the suppression rules differ. A completion is discarded when
//  it isn't insertable; a rewrite is discarded when it isn't *better* — an unchanged, longer, or
//  merely differently-worded span is worse than showing nothing, because the user already committed
//  to what they typed.
//

import Foundation

/// Where a rewrite came from — surfaced in the prediction log and used to gate cloud calls.
public enum RewriteOrigin: String, Equatable, Sendable {
    /// Deterministic, on-device, rules-based: spelling and grammar. Always available, offline.
    case proofreader
    /// A language model — local or cloud — asked to improve phrasing.
    case model
}

public struct RewriteSuggestion: Equatable {
    /// The text to be replaced, ending exactly at the caret.
    public let span: CaretSpan
    /// What should stand in its place.
    public let replacement: String
    public let origin: RewriteOrigin

    public init(span: CaretSpan, replacement: String, origin: RewriteOrigin) {
        self.span = span
        self.replacement = replacement
        self.origin = origin
    }

    /// A rewrite is only worth showing when it actually changes the text.
    public var isMeaningful: Bool {
        !span.isEmpty && !replacement.isEmpty && span.original != replacement
    }
}

/// Produces at most one rewrite for the text behind the caret.
///
/// Implementations must return nil rather than a marginal suggestion — see the suppression
/// principle in `docs/00-overview.md`.
public protocol SentenceRewriting {
    func suggestion(for context: TextFieldContext) async -> RewriteSuggestion?
}
