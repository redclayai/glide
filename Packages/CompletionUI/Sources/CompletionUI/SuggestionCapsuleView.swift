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

    /// Drives the entrance. A fresh view is built on every show, so this starts false each time and
    /// `onAppear` animates it — no external trigger needed.
    @State private var appeared = false

    public init(diff: RewriteDiff, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), showsAcceptHint: Bool = true) {
        self.diff = diff
        self.font = font
        self.showsAcceptHint = showsAcceptHint
    }

    /// Fast, and settles without overshoot on purpose. This appears many times an hour directly over
    /// what someone is reading; a bouncy entrance would pull the eye every single time, which is the
    /// opposite of what a suggestion offered mid-sentence should do.
    static let entrance = Animation.spring(response: 0.26, dampingFraction: 0.9)

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
            // Glide's own mark rather than a generic sparkle: this surface should be identifiable as
            // the app at a glance, and the caret-and-trail is what the icon and menu bar already use.
            GlideMark(size: NSFont.systemFontSize)
                .foregroundStyle(Color.accentColor)
                .offset(x: appeared ? 0 : -3)
                .opacity(appeared ? 1 : 0)

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
        // Rises the couple of points it sits below the caret and settles — the direction reads as
        // "this belongs to the line above", which is exactly what it is attached to.
        .scaleEffect(appeared ? 1 : 0.96, anchor: .topLeading)
        .offset(y: appeared ? 0 : -4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(Self.entrance) { appeared = true }
        }
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
