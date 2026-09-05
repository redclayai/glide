//
//  SuggestionCapsuleView.swift
//  CompletionUI
//
//  The surface a rewrite is offered on. Three jobs, in order of importance:
//
//    1. Show what is changing. The changed words are emphasised via `RewriteDiff`, so accepting is a
//       glance rather than a mental diff of two sentences under time pressure.
//    2. Say how to take it. A `Tab` chip on the trailing edge — the gesture is not discoverable
//       otherwise, and a suggestion nobody knows how to accept is a suggestion nobody accepts.
//    3. Stay out of the way. A neutral surface, no saturated fill, because this appears over the
//       user's own writing many times a day.
//
//  Geometry, colour and motion come from `SuggestionStyle`, transcribed from the Claude Design
//  project's 1A variant. It wraps to multiple lines: a whole-sentence grammar fix does not fit on
//  one, and truncating the very text the user is being asked to accept would be worse than useless.
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

    public init(
        diff: RewriteDiff,
        font: NSFont = .systemFont(ofSize: SuggestionStyle.textSize),
        showsAcceptHint: Bool = true
    ) {
        self.diff = diff
        self.font = font
        self.showsAcceptHint = showsAcceptHint
    }

    /// Wide enough for a sentence at a readable measure, narrow enough not to span the screen.
    public static let maximumTextWidth: CGFloat = 420
    public static let gapBelowCaret = SuggestionStyle.gapBelowCaret

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SuggestionStyle.inlineSpacing) {
            // Glide's own mark rather than a generic glyph: this surface should be identifiable as
            // the app at a glance, and the caret-and-trail is what the icon and menu bar already use.
            GlideMark(size: SuggestionStyle.glyphSize)
                .foregroundStyle(SuggestionStyle.accent)
                .offset(x: appeared ? 0 : -3)
                .opacity(appeared ? 1 : 0)

            Text(attributed)
                .font(Font(font as CTFont))
                .tracking(SuggestionStyle.textTracking)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.maximumTextWidth, alignment: .leading)

            if showsAcceptHint {
                Text("Tab")
                    .font(.system(size: SuggestionStyle.chipSize, weight: .medium))
                    .foregroundStyle(SuggestionStyle.chipLabel)
                    .padding(.horizontal, SuggestionStyle.chipHorizontalPadding)
                    .padding(.vertical, SuggestionStyle.chipVerticalPadding)
                    .background(chip)
                    // Never compressed. The suggestion text next to it is happy to wrap, so under a
                    // tight width the layout took its space from the chip instead and rendered the
                    // key as "T…" — an instruction the user cannot follow.
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, SuggestionStyle.inlineLeadingPadding)
        .padding(.trailing, SuggestionStyle.inlineTrailingPadding)
        .padding(.vertical, SuggestionStyle.inlineVerticalPadding)
        .background(surface)
        // Rises the few points it sits below the caret and settles — the direction reads as "this
        // belongs to the line above", which is what it is attached to.
        .scaleEffect(appeared ? 1 : SuggestionStyle.entranceScale, anchor: .topLeading)
        .offset(y: appeared ? 0 : SuggestionStyle.entranceOffset)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(SuggestionStyle.entrance) { appeared = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Suggested correction: \(diff.segments.map(\.text).joined())")
    }

    /// Blur, then tint, then hairline, then two shadows — in that order, because that layering is
    /// what makes the surface read as floating over the document rather than filled on top of it.
    /// One shadow cannot be both a contact shadow and an ambient one, hence two.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: SuggestionStyle.inlineCornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(SuggestionStyle.surfaceTint))
            .overlay(shape.strokeBorder(SuggestionStyle.hairline, lineWidth: SuggestionStyle.hairlineWidth))
            .shadow(
                color: SuggestionStyle.contactShadow.color,
                radius: SuggestionStyle.contactShadow.radius,
                y: SuggestionStyle.contactShadow.y
            )
            .shadow(
                color: SuggestionStyle.ambientShadow.color,
                radius: SuggestionStyle.ambientShadow.radius,
                y: SuggestionStyle.ambientShadow.y
            )
    }

    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: SuggestionStyle.chipCornerRadius, style: .continuous)
        return shape
            .fill(SuggestionStyle.chipFill)
            .overlay(shape.strokeBorder(SuggestionStyle.chipHairline, lineWidth: SuggestionStyle.hairlineWidth))
    }

    /// The replacement, with the changed words carrying the weight. Emphasis is weight plus colour
    /// rather than colour alone, so it still reads for someone who cannot distinguish the two.
    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in diff.segments {
            var piece = AttributedString(segment.text)
            if segment.isChanged {
                piece.font = Font(font as CTFont).weight(.semibold)
                piece.foregroundColor = SuggestionStyle.accent
            } else {
                piece.foregroundColor = SuggestionStyle.label
            }
            result.append(piece)
        }
        return result
    }
}
