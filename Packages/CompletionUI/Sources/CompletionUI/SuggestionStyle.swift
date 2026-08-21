//
//  SuggestionStyle.swift
//  CompletionUI
//
//  The design tokens for Glide's two floating surfaces, in one place.
//
//  Imported from the Claude Design project "AppleOS popovers redesign", variant **1A — Inline
//  suggestion & selection actions, appleOS**. That variant was chosen over 2A ("Liquid glass —
//  capsule geometry, tinted actions") for two reasons: its neutral surfaces and grey Tab chip match
//  the grey the surfaces were deliberately given, where 2A tints both blue; and it needs no
//  macOS 26 gating, where 2A's capsule glass does. 2A remains a small change from here — every value
//  it differs on is a constant in this file.
//
//  Values are transcribed from the design rather than approximated, including the half-pixel
//  hairlines and the three-layer shadows, because those are what make the surface read as a floating
//  panel rather than a filled rectangle.
//

import AppKit
import SwiftUI

public enum SuggestionStyle {
    // MARK: - Shape

    /// 1A: inline suggestion `border-radius:13px`, selection toolbar `15px`.
    public static let inlineCornerRadius: CGFloat = 13
    public static let toolbarCornerRadius: CGFloat = 15

    /// 1A inline: `padding:7px 8px 7px 11px`, `gap:10px`.
    public static let inlineLeadingPadding: CGFloat = 11
    public static let inlineTrailingPadding: CGFloat = 8
    public static let inlineVerticalPadding: CGFloat = 7
    public static let inlineSpacing: CGFloat = 10

    /// 1A toolbar: `padding:6px`, `gap:6px`.
    public static let toolbarPadding: CGFloat = 6
    public static let toolbarSpacing: CGFloat = 6

    /// Gap between the caret and the surface below it. Not in the design (which positions absolutely
    /// in a mock), so this stays the app's own value.
    public static let gapBelowCaret: CGFloat = 7

    // MARK: - Type

    /// 1A: suggestion text `font-size:14px; letter-spacing:-.01em`.
    public static let textSize: CGFloat = 14
    public static let textTracking: CGFloat = -0.14   // -.01em at 14px

    /// 1A: the Tab chip — `font-size:11px; font-weight:500`.
    public static let chipSize: CGFloat = 11

    /// 1A: leading glyph rendered at 15×15.
    public static let glyphSize: CGFloat = 15

    // MARK: - Colour

    /// Appearance-resolving colour. The design gives explicit light and dark values for every
    /// surface; this keeps them paired so neither can be updated without the other.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    /// Surface tint over the blur. 1A light `rgba(250,250,252,.82)`, dark `rgba(58,58,60,.72)`.
    public static let surfaceTint = dynamic(
        light: rgba(250, 250, 252, 0.82),
        dark: rgba(58, 58, 60, 0.72)
    )

    /// The hairline. 1A light `0 0 0 .5px rgba(0,0,0,.06)`, dark `rgba(255,255,255,.12)`.
    public static let hairline = dynamic(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.12)
    )
    public static let hairlineWidth: CGFloat = 0.5

    /// 1A: text `#1D1D1F` light, `#F5F5F7` dark.
    public static let label = dynamic(light: rgba(29, 29, 31), dark: rgba(245, 245, 247))

    /// 1A: the leading glyph and changed words — `#007AFF` light, `#0A84FF` dark. Apple's system
    /// blue in both cases, so this tracks `controlAccentColor` rather than hardcoding it, and follows
    /// the user's accent-colour preference for free.
    public static let accent = Color.accentColor

    /// 1A Tab chip: light text `#6E6E73` on `rgba(120,120,128,.12)`; dark `#EBEBF5` on
    /// `rgba(235,235,245,.18)`.
    public static let chipLabel = dynamic(light: rgba(110, 110, 115), dark: rgba(235, 235, 245))
    public static let chipFill = dynamic(
        light: rgba(120, 120, 128, 0.12),
        dark: rgba(235, 235, 245, 0.18)
    )
    public static let chipCornerRadius: CGFloat = 6
    public static let chipHorizontalPadding: CGFloat = 7
    public static let chipVerticalPadding: CGFloat = 3
    /// 1A: `box-shadow:inset 0 0 0 .5px rgba(0,0,0,.05)` — light only.
    public static let chipHairline = dynamic(
        light: NSColor(white: 0, alpha: 0.05),
        dark: NSColor(white: 1, alpha: 0)
    )

    // MARK: - Shadow

    /// 1A inline: `0 1px 2px rgba(0,0,0,.08), 0 12px 34px -8px rgba(0,0,0,.28)`; dark deepens the
    /// ambient layer to `.6`. Rendered as two shadows because one cannot be both a contact shadow
    /// and an ambient one.
    public struct Shadow {
        public let color: Color
        public let radius: CGFloat
        public let y: CGFloat
        public init(color: Color, radius: CGFloat, y: CGFloat) {
            self.color = color
            self.radius = radius
            self.y = y
        }
    }

    public static let contactShadow = Shadow(
        color: dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 0, alpha: 0.5)),
        radius: 1,
        y: 1
    )

    public static let ambientShadow = Shadow(
        color: dynamic(light: NSColor(white: 0, alpha: 0.28), dark: NSColor(white: 0, alpha: 0.6)),
        radius: 17,   // 34px CSS blur ≈ 17pt SwiftUI radius
        y: 8
    )

    // MARK: - Motion

    /// 1A: `animation:popIn .22s cubic-bezier(.32,.72,0,1)` with
    /// `from { opacity:0; transform:translateY(6px) scale(.96) }`.
    ///
    /// That curve is Apple's standard decelerating ease — a fast start settling without overshoot,
    /// which is what this needs: the surface appears over text many times an hour, and anything that
    /// bounces pulls the eye every time.
    public static let entranceDuration: Double = 0.22
    public static let entranceOffset: CGFloat = 6
    public static let entranceScale: CGFloat = 0.96

    public static var entrance: Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: entranceDuration)
    }

    /// The same curve for the AppKit panel, which cannot use a SwiftUI animation.
    public static var entranceTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
    }
}
