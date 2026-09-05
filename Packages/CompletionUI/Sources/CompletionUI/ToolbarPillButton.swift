//
//  ToolbarPillButton.swift
//  CompletionUI
//
//  The items in the selection toolbar.
//
//  These were raised white pills with SF Symbols, sitting inside a white capsule. That reads as a
//  web component, not a system control: Apple's text-selection callout — the one that appears over a
//  selection on both iOS and macOS — is a single capsule of *flat* text items divided by hairlines,
//  with no per-item background at rest and no iconography. Nothing inside it competes with the
//  surface for depth; the material does all the lifting. So these are flat now, and the shape,
//  blur and shadow belong to the panel alone.
//
//  An `NSButton` subclass rather than SwiftUI, because the toolbar is an AppKit panel whose click
//  handling was hard-won: a borderless non-activating panel only delivers clicks to its controls
//  when it can become key, and `acceptsFirstMouse` has to be overridden for the click that arrives
//  while another app is frontmost. Rebuilding that in SwiftUI to gain styling would risk the one
//  behaviour that took several attempts to get right, so this keeps the working control and restyles
//  its layer.
//

import AppKit

/// One thing the selection toolbar can offer: a button, or a menu of buttons.
///
/// A plain description, deliberately free of `SelectionAction` — `CompletionUI` does not depend on
/// the action engine, and the panel translates between them.
public enum SelectionToolbarEntry {
    case action(id: String, title: String)
    case menu(id: String, title: String, items: [SelectionToolbarEntry])

    public var id: String {
        switch self {
        case let .action(id, _), let .menu(id, _, _): return id
        }
    }

    public var title: String {
        switch self {
        case let .action(_, title), let .menu(_, title, _): return title
        }
    }
}

/// What the panel is showing.
public enum SelectionToolbarState {
    case actions([SelectionToolbarEntry])
    case working(title: String)
    case result(text: String, canReplace: Bool)
    case message(String)
}

/// A flat text item in the selection toolbar. No fill at rest; a quiet rounded highlight on hover,
/// inset from the capsule's edges the way a menu item's highlight is inset from its menu.
public final class ToolbarPillButton: NSButton {
    /// The click that arrives while another application is frontmost. Without this the first click is
    /// spent activating, the user sees nothing happen, and the panel is usually gone by the second.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    /// Menu metrics. `NSFont.menuFont(ofSize: 0)` is 13pt+, and matching it is most of what makes a
    /// floating control feel like it came with the system.
    public static let itemHeight: CGFloat = 26
    private static let horizontalPadding: CGFloat = 11

    /// `symbolName` is accepted and ignored. The callers still name a symbol for each action, and
    /// keeping the parameter means this stayed a one-file change — but no symbol is drawn. A label
    /// that already says "Polish" is not clarified by a wand beside it, and the symbol that had been
    /// standing in for "Grammar" was `checkmark.gobackward`, which means *revert*.
    public init(title: String, symbolName: String) {
        super.init(frame: .zero)

        self.title = title
        imagePosition = .noImage
        font = .menuFont(ofSize: 0)
        isBordered = false
        bezelStyle = .accessoryBarAction
        wantsLayer = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += Self.horizontalPadding * 2
        size.height = Self.itemHeight
        return size
    }

    // MARK: - Style

    private func applyStyle() {
        guard let layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Inset from the panel's own rounding so the highlight sits *within* the capsule rather than
        // fighting its edge — the same relationship a menu item's highlight has to its menu.
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.borderWidth = 0
        layer.shadowOpacity = 0

        contentTintColor = .labelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.menuFont(ofSize: 0),
                .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            ]
        )

        let fill: NSColor
        if isPressed {
            fill = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.16 : 0.11)
        } else if isHovering {
            fill = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.10 : 0.06)
        } else {
            fill = .clear
        }
        layer.backgroundColor = fill.cgColor
    }

    public override var isEnabled: Bool {
        didSet { applyStyle() }
    }

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

/// The dismiss control. Square, symbol-only, and styled exactly like the text items otherwise — it
/// is one more item in the same row, not a decoration bolted to the end.
public final class ToolbarDismissButton: NSButton {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    public init() {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        toolTip = "Dismiss (Escape)"
        setAccessibilityLabel("Dismiss")
        applyStyle()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ToolbarPillButton.itemHeight),
            heightAnchor.constraint(equalToConstant: ToolbarPillButton.itemHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyStyle() {
        guard let layer else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        if isPressed {
            layer.backgroundColor = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.16 : 0.11).cgColor
        } else if isHovering {
            layer.backgroundColor = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.10 : 0.06).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
        // Quieter than the actions at rest — it is a way out, not a third thing to do — and resolves
        // to full label colour once the pointer is on it.
        contentTintColor = isHovering ? .labelColor : .secondaryLabelColor
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true; applyStyle() }
    public override func mouseExited(with event: NSEvent) { isHovering = false; isPressed = false; applyStyle() }

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
