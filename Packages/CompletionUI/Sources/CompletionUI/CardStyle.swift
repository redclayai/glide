//
//  CardStyle.swift
//  CompletionUI
//
//  The measured appearance of the rewrite card.
//
//  Every value here was sampled from screenshots of the reference, not chosen: the colours by
//  reading pixels, the metrics by finding the runs between edges. Where a number is derived rather
//  than measured it says so. Keeping them in one place is what makes the card checkable — a
//  disagreement with the reference is a disagreement with a constant, not a hunt through layout
//  code.
//
//  Deliberately fixed colours rather than semantic ones. The reference is a light card in every
//  appearance, so `labelColor` and friends — which would flip to white text on white in Dark Mode —
//  are wrong here. The panel pins itself to `.aqua` for the same reason.
//

import AppKit

public enum CardStyle {

    // MARK: - Palette

    /// Builds a colour whose components are taken to be in the display's own space, so they reach
    /// the framebuffer unchanged.
    ///
    /// This is not pedantry. The reference values were read out of a screenshot, and a screenshot
    /// records what reached the framebuffer. An `NSColor(srgbRed:…)` is colour-managed on the way
    /// there: `#44A295` specified in sRGB was measured back as `#599F95`, 21 points adrift in red
    /// and a plainly lighter rule than the reference. Greys are unaffected by the conversion, which
    /// is why `#2E2E2E` matched all along and hid the problem — and why `deviceRed:` did not fix
    /// it either, being colour-managed just the same.
    ///
    /// The browser the reference was captured from writes its colours into the display's buffer
    /// without converting them, so the only way for this card to *look* the same beside it is to do
    /// likewise. `NSScreen.colorSpace` is the display's profile, and declaring the components to be
    /// already in it is what suppresses the conversion. The fallback is sRGB, which is the correct
    /// answer when there is no screen to ask.
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        let components: [CGFloat] = [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1]
        guard let space = NSScreen.main?.colorSpace else {
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
        }
        return NSColor(colorSpace: space, components: components, count: 4)
    }

    /// The dark surround.
    public static var chrome: NSColor { rgb(0x2E, 0x2E, 0x2E) }
    /// The card itself.
    public static let cardFill = NSColor.white
    /// Every hairline: the card's border, the rule under the tabs, the field's edge.
    public static var hairline: NSColor { rgb(0xD9, 0xD9, 0xD9) }
    /// Headings.
    public static var accentText: NSColor { rgb(0x2F, 0x7B, 0x70) }
    /// The rule down the left of a proposal — lighter than the heading it sits beside.
    public static var accentRule: NSColor { rgb(0x44, 0xA2, 0x95) }
    /// The "nothing to change" badge.
    public static var badgeFill: NSColor { rgb(0x27, 0x67, 0x5E) }
    /// Body copy and the selected tab.
    public static var primaryText: NSColor { rgb(0x1C, 0x1C, 0x1C) }
    /// Unselected tabs, secondary lines, placeholder text.
    public static var secondaryText: NSColor { rgb(0x70, 0x70, 0x70) }
    /// The instruction field.
    public static var fieldFill: NSColor { rgb(0xF5, 0xF5, 0xF5) }
    /// The star in the dark strip.
    public static var gold: NSColor { rgb(0xF6, 0xA6, 0x30) }

    /// Insertion and removal tints.
    ///
    /// Derived, not measured: the only reference frame showing a diff had the body blurred behind a
    /// paywall, so the hues survived but the values did not. These are tints of `accentRule` and of
    /// the matching red, chosen to sit at the same lightness as each other.
    public static var insertedText: NSColor { rgb(0x1C, 0x66, 0x58) }
    public static var insertedFill: NSColor { rgb(0xDC, 0xF1, 0xED) }
    public static var removedText: NSColor { rgb(0xA1, 0x2C, 0x38) }
    public static var removedFill: NSColor { rgb(0xFB, 0xE5, 0xE7) }

    // MARK: - Metrics

    /// Card width. The reference is 720pt across; `width(for:)` clamps it to the screen.
    public static let cardWidth: CGFloat = 720
    public static let chromeRadius: CGFloat = 12
    /// The dark surround showing past the card on three sides.
    public static let chromeInset: CGFloat = 6
    /// …and at the top, where it is tall enough to hold a line of text.
    public static let chromeStripHeight: CGFloat = 37
    public static let cardRadius: CGFloat = 8

    public static let tabRowHeight: CGFloat = 48
    /// Tab labels start this far in from the card's edge.
    public static let tabRowPadding: CGFloat = 20
    /// Measured between the end of one label and the start of the next.
    public static let tabGap: CGFloat = 30

    public static let fieldWidth: CGFloat = 146
    public static let fieldHeight: CGFloat = 26
    /// A pill: the radius is half the height.
    public static var fieldRadius: CGFloat { fieldHeight / 2 }

    public static let ruleWidth: CGFloat = 4
    /// The rule's own distance from the card's left edge…
    public static let ruleInset: CGFloat = 14
    /// …and the body's, which clears the rule by 20pt.
    public static let bodyInset: CGFloat = 38
    public static let bodyTopGap: CGFloat = 15

    /// Fits the card to `screen`, leaving a margin, so a 720pt card does not hang off a laptop
    /// display or a narrow window.
    public static func width(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return cardWidth }
        return min(cardWidth, screen.visibleFrame.width - 80)
    }

    // MARK: - Type

    /// Inter, which is the reference's own UI face — and, being SIL Open Font Licensed, one that can
    /// ship inside the app. The three weights in `KeyType/Resources` are registered by
    /// `ATSApplicationFontsPath` in Info.plist; the fallback is the system font, so a missing
    /// resource degrades to something readable rather than to nothing.
    public static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Inter-SemiBold"
        case .medium: name = "Inter-Medium"
        default: name = "Inter-Regular"
        }
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Sampled cap heights put the dark strip at 14pt, the tabs at 15pt, a heading at 16pt and body
    /// copy at 15pt.
    public static var stripFont: NSFont { font(14, .semibold) }
    public static var stripSubtitleFont: NSFont { font(14) }
    public static var tabFont: NSFont { font(15, .semibold) }
    public static var tabFontUnselected: NSFont { font(15) }
    public static var headingFont: NSFont { font(16, .semibold) }
    public static var bodyFont: NSFont { font(15) }
    public static var fieldFont: NSFont { font(13) }
}
