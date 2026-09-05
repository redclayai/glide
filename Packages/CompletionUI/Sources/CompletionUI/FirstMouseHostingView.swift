//
//  FirstMouseHostingView.swift
//  CompletionUI
//
//  The one thing SwiftUI cannot say for itself on a floating panel.
//
//  Glide's surfaces are borderless, non-activating panels: they appear over whatever app the user is
//  writing in, and that app stays frontmost. A click arriving at a window whose application is not
//  active is a *first mouse* event, and AppKit's default is to spend it activating rather than
//  delivering it. On a panel that never activates, that means the click is simply swallowed — the
//  user presses a button, nothing happens, and the panel is usually gone before they try again.
//
//  `acceptsFirstMouse` is the fix, it can only be answered by an `NSView`, and it is why hosting a
//  SwiftUI view here rather than in a plain `NSHostingView` is load-bearing rather than incidental.
//  See ADR-119.
//

import AppKit
import SwiftUI

public final class FirstMouseHostingView: NSHostingView<AnyView> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public required init(rootView: AnyView) { super.init(rootView: rootView) }
}
