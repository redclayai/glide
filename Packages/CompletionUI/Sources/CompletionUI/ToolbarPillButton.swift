//
//  ToolbarPillButton.swift
//  CompletionUI
//
//  The action buttons in the selection toolbar, styled to the Claude Design 1A variant: a raised
//  pill — `border-radius:10px`, near-white fill, hairline, soft contact shadow — that brightens on
//  hover and depresses on press.
//
//  An `NSButton` subclass rather than SwiftUI, because the toolbar is an AppKit panel whose click
//  handling was hard-won: a borderless non-activating panel only delivers clicks to its controls
//  when it can become key, and `acceptsFirstMouse` has to be overridden for the click that arrives
//  while another app is frontmost. Rebuilding that in SwiftUI to gain styling would risk the one
//  behaviour that took several attempts to get right, so this keeps the working control and restyles
//  its layer.
//
//  `bezelStyle` is deliberately untouched — the appearance comes entirely from the backing layer, so
//  target/action, first-mouse and key-view behaviour are exactly as they were.
//

import AppKit

public final class ToolbarPillButton: NSButton {
    /// The click that arrives while another application is frontmost. Without this the first click is
    /// spent activating, the user sees nothing happen, and the panel is usually gone by the second.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    public init(title: String, symbolName: String) {
        super.init(frame: .zero)

        self.title = " " + title
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        imagePosition = .imageLeading
        // 1A: `font-size:13px; font-weight:500`.
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        bezelStyle = .accessoryBarAction
        wantsLayer = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Style

    /// 1A rest / hover / pressed, resolved for the current appearance:
    ///   light  `rgba(255,255,255,.9)` → `#FFFFFF` → `rgba(240,240,244,.95)` with an inset shadow
    ///   dark   `rgba(120,120,128,.32)` → `.48`
    private func applyStyle() {
        guard let layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        contentTintColor = isDark ? NSColor(srgbRed: 245/255, green: 245/255, blue: 247/255, alpha: 1)
                                  : NSColor(srgbRed: 29/255, green: 29/255, blue: 31/255, alpha: 1)

        let fill: NSColor
        if isDark {
            fill = NSColor(white: 0.5, alpha: isPressed ? 0.56 : (isHovering ? 0.48 : 0.32))
        } else if isPressed {
            fill = NSColor(srgbRed: 240/255, green: 240/255, blue: 244/255, alpha: 0.95)
        } else {
            fill = NSColor(white: 1, alpha: isHovering ? 1.0 : 0.9)
        }
        layer.backgroundColor = fill.cgColor

        // The hairline and contact shadow are what make it read as raised. Light appearance only —
        // 1A gives the dark variant a flat translucent fill with no border, and adding one there
        // makes the pill look pasted on.
        layer.borderWidth = isDark ? 0 : 0.5
        layer.borderColor = NSColor(white: 0, alpha: isHovering ? 0.10 : 0.07).cgColor

        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowRadius = isHovering ? 3 : 0.75
        layer.shadowOpacity = isDark ? 0 : (isPressed ? 0 : (isHovering ? 0.12 : 0.07))
        layer.masksToBounds = false
    }

    private var isPressed = false

    // MARK: - State

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyStyle()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        applyStyle()
    }

    /// `super.mouseDown` runs the cell's tracking loop and does not return until the mouse is
    /// released — so the pressed style is applied around it rather than in a separate mouseUp, which
    /// would never be delivered.
    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyStyle()
        super.mouseDown(with: event)
        isPressed = false
        applyStyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

/// The dismiss control: 1A gives it a transparent 26×26 square with an 8pt radius that fills in on
/// hover — quieter than the actions, because it is a way out rather than a third thing to do.
public final class ToolbarDismissButton: NSButton {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    public init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        toolTip = "Dismiss (Escape)"
        setAccessibilityLabel("Dismiss")
        applyStyle()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyStyle() {
        guard let layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.backgroundColor = isHovering
            ? NSColor(white: isDark ? 0.92 : 0.47, alpha: isDark ? 0.16 : 0.14).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isHovering
            ? (isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.11, alpha: 1))
            : NSColor(white: isDark ? 0.60 : 0.56, alpha: 1)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true; applyStyle() }
    public override func mouseExited(with event: NSEvent) { isHovering = false; applyStyle() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}
