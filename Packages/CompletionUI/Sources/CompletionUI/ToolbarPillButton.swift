//
//  ToolbarPillButton.swift
//  CompletionUI
//
//  The controls inside the rewrite card.
//
//  These are `NSButton` subclasses rather than SwiftUI, because the card is an AppKit panel whose
//  click handling was hard-won: a borderless non-activating panel only delivers clicks to its
//  controls when it can become key, and `acceptsFirstMouse` has to be overridden for the click that
//  arrives while another app is frontmost (ADR-119). Rebuilding that in SwiftUI to gain styling
//  would risk the one behaviour that took several attempts to get right, so these keep the working
//  control and restyle its layer.
//
//  Every colour, size and weight comes from `CardStyle`, which holds the measurements. Nothing here
//  should name a colour or a point size directly.
//

import AppKit
import AutocompleteCore

/// One thing the card can offer: a button, or a menu of buttons.
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

/// What the card is showing.
public enum SelectionToolbarState {
    case actions([SelectionToolbarEntry])
    /// A finished rewrite, shown as a diff against what the user wrote.
    case diff(title: String, edits: [RewriteDiff.Edit], replacement: String)
    case working(title: String)
    case result(text: String, canReplace: Bool)
    case message(String)
    /// Nothing to change — the badge-and-heading state, not an error.
    case clean(title: String, detail: String)
}

/// A text item in the card's body. Flat by default; `isPrimary` fills it with the accent so the one
/// action that applies the rewrite reads as the one action.
public final class ToolbarPillButton: NSButton {
    /// The click that arrives while another application is frontmost. Without this the first click
    /// is spent activating, the user sees nothing happen, and the card is usually gone by the second.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    public var isPrimary = false { didSet { applyStyle() } }

    public static let itemHeight: CGFloat = 28
    private static let horizontalPadding: CGFloat = 12

    /// `symbolName` is accepted and ignored. The callers still name a symbol for each action, and
    /// keeping the parameter means this stayed a one-file change — but no symbol is drawn. A label
    /// that already says "Polish" is not clarified by a wand beside it.
    public init(title: String, symbolName: String) {
        super.init(frame: .zero)
        self.title = title
        imagePosition = .noImage
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
        layer.cornerRadius = Self.itemHeight / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 0
        layer.shadowOpacity = 0

        let text: NSColor = isPrimary ? .white : (isEnabled ? CardStyle.primaryText : CardStyle.secondaryText)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: CardStyle.font(14, isPrimary ? .semibold : .medium),
            .foregroundColor: text,
        ])

        let fill: NSColor
        if isPrimary {
            fill = isPressed
                ? CardStyle.badgeFill
                : (isHovering ? CardStyle.accentText : CardStyle.accentRule)
        } else if isPressed {
            fill = NSColor(white: 0, alpha: 0.11)
        } else if isHovering {
            fill = NSColor(white: 0, alpha: 0.06)
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
}

/// The dismiss control, which lives in the dark strip and is therefore light-on-dark.
public final class ToolbarDismissButton: NSButton {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    /// Set when the button sits on the card rather than on the dark strip.
    public var isOnLightSurface = false { didSet { applyStyle() } }

    public init() {
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Dismiss"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        toolTip = "Dismiss (Escape)"
        setAccessibilityLabel("Dismiss")
        applyStyle()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func applyStyle() {
        guard let layer else { return }
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        let tintWhite: CGFloat = isOnLightSurface ? 0 : 1
        if isPressed {
            layer.backgroundColor = NSColor(white: tintWhite, alpha: 0.22).cgColor
        } else if isHovering {
            layer.backgroundColor = NSColor(white: tintWhite, alpha: 0.13).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
        if isOnLightSurface {
            contentTintColor = isHovering ? CardStyle.primaryText : CardStyle.secondaryText
        } else {
            contentTintColor = isHovering ? .white : NSColor(white: 1, alpha: 0.65)
        }
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
}

/// A header tab: flat text with no chrome at all, the selected one carrying the weight and the
/// colour. A segmented control, a pill or an underline would each put a second edge inside a card
/// that already has one, which is exactly what the reference avoids.
public final class ToolbarTabButton: NSButton {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    public var isSelectedTab = false { didSet { applyStyle() } }

    public init(title: String) {
        super.init(frame: .zero)
        self.title = title
        imagePosition = .noImage
        isBordered = false
        wantsLayer = true
        applyStyle()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Exactly the label's width.
    ///
    /// `super.intrinsicContentSize` adds the cell's own padding — about 3.5pt a side — which turned
    /// a 30pt stack spacing into a measured 37pt gap and pushed the first tab 3pt further in than
    /// the reference. The gap is specified label-edge to label-edge, so the button has to be the
    /// label and nothing else.
    public override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width), height: CardStyle.tabRowHeight)
    }

    private func applyStyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        let colour: NSColor
        if isSelectedTab {
            colour = CardStyle.primaryText
        } else {
            colour = isHovering ? CardStyle.primaryText : CardStyle.secondaryText
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: isSelectedTab ? CardStyle.tabFont : CardStyle.tabFontUnselected,
            .foregroundColor: colour,
        ])
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
}

/// Renders a rewrite as what changed: insertions tinted and highlighted, removals struck through.
///
/// The card shows the result *after* the original has scrolled out of mind, so a plain paragraph of
/// corrected text asks the reader to diff two sentences from memory — the work the feature exists to
/// save.
public enum RewriteDiffRendering {
    public static func attributed(_ edits: [RewriteDiff.Edit], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4

        for edit in edits {
            switch edit {
            case let .kept(text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: CardStyle.primaryText,
                ]))
            case let .inserted(text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: CardStyle.font(font.pointSize, .semibold),
                    .foregroundColor: CardStyle.insertedText,
                    .backgroundColor: CardStyle.insertedFill,
                ]))
            case let .removed(text):
                result.append(NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: CardStyle.removedText,
                    .backgroundColor: CardStyle.removedFill,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: CardStyle.removedText,
                ]))
            }
        }
        result.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }
}
