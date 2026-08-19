//
//  SuggestionCapsuleView.swift
//  CompletionUI
//
//  The surface a rewrite is offered on. Three jobs, in order of importance:
//
//    1. Show what is changing. The changed words are emphasised via `RewriteDiff`, so accepting is a
//       glance rather than a mental diff of two sentences under time pressure.
//    2. Say how to take it. A `Tab` key cap on the trailing edge — the gesture is not discoverable
//       otherwise, and a suggestion nobody knows how to accept is a suggestion nobody accepts.
//    3. Stay out of the way. Neutral grey rather than a saturated brand colour, because this appears
//       over the user's own writing many times a day.
//
//  Unlike `CapsuleCompletionView` (a plain pill used for mid-line completions), this wraps to
//  multiple lines: a whole-sentence grammar fix does not fit on one, and truncating the very text
//  the user is being asked to accept would be worse than useless.
//

import AppKit
import AutocompleteCore
import SwiftUI

public struct SuggestionCapsuleView: View {
    public var diff: RewriteDiff
    public var font: NSFont
    public var showsAcceptHint: Bool

    public init(diff: RewriteDiff, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), showsAcceptHint: Bool = true) {
        self.diff = diff
        self.font = font
        self.showsAcceptHint = showsAcceptHint
    }

    public static let horizontalPadding: CGFloat = 14
    public static let verticalPadding: CGFloat = 10
    public static let cornerRadius: CGFloat = 14
    public static let gapBelowCaret: CGFloat = 7
    /// Wide enough for a sentence at a readable measure, narrow enough not to span the screen.
    public static let maximumTextWidth: CGFloat = 420

    /// Explicitly grey in both appearances rather than `windowBackgroundColor`, which renders
    /// near-white on a light desktop and near-black on a dark one — neither of which reads as a
    /// surface sitting *over* the document. Grey separates the suggestion from the page it floats
    /// above without introducing a colour that competes with the highlighted words.
    static var surface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.235, alpha: 1)
                : NSColor(calibratedWhite: 0.902, alpha: 1)
        })
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: NSFont.systemFontSize * 0.85, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(attributed)
                .font(Font(font as CTFont))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.maximumTextWidth, alignment: .leading)

            if showsAcceptHint {
                Text("Tab")
                    .font(.system(size: NSFont.smallSystemFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Self.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Suggested correction: \(diff.segments.map(\.text).joined())")
    }

    /// The replacement, with the changed words carrying the weight. Emphasis is weight plus colour
    /// rather than colour alone, so it still reads for someone who cannot distinguish the two.
    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in diff.segments {
            var piece = AttributedString(segment.text)
            if segment.isChanged {
                piece.font = Font(font as CTFont).weight(.semibold)
                piece.foregroundColor = Color.accentColor
            } else {
                piece.foregroundColor = Color.primary
            }
            result.append(piece)
        }
        return result
    }
}
