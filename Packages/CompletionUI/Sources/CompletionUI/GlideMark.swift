//
//  GlideMark.swift
//  CompletionUI
//
//  Glide's mark — a caret that has travelled, leaving a trail — drawn rather than bundled.
//
//  Drawn for two reasons. It scales to any size without a set of raster assets, and it lives in this
//  package where both floating surfaces can reach it: the suggestion capsule here, and the selection
//  popover in the app target. A bundled PNG would have to be duplicated into the package or hoisted
//  out of the app's asset catalog, and would then be a second copy of the artwork to keep in step
//  with the app icon.
//
//  Proportions match `Scripts/Icon/render-menubar.swift`, so this is recognisably the same mark at
//  12pt as the icon is at 1024.
//

import SwiftUI

public struct GlideMark: View {
    /// The trail only reads as motion if the streaks fade, so the fade is carried by opacity — that
    /// way a single tint colour still produces the gradient.
    private struct Streak {
        let start: CGFloat
        let end: CGFloat
        let thickness: CGFloat
        let offset: CGFloat
        let opacity: Double
    }

    private static let streaks = [
        Streak(start: 0.08, end: 0.60, thickness: 0.115, offset: 0, opacity: 1.00),
        Streak(start: 0.26, end: 0.52, thickness: 0.095, offset: 0.20, opacity: 0.55),
        Streak(start: 0.30, end: 0.50, thickness: 0.095, offset: -0.20, opacity: 0.40),
    ]

    private static let caretX: CGFloat = 0.70
    private static let caretWidth: CGFloat = 0.125
    private static let caretHeight: CGFloat = 0.72

    public var size: CGFloat

    public init(size: CGFloat = 13) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let midY = canvasSize.height / 2

            for streak in Self.streaks {
                let height = side * streak.thickness
                let rect = CGRect(
                    x: side * streak.start,
                    y: midY - height / 2 + side * streak.offset,
                    width: side * (streak.end - streak.start),
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: height / 2),
                    with: .style(.tint.opacity(streak.opacity))
                )
            }

            let caretW = side * Self.caretWidth
            let caretH = side * Self.caretHeight
            let caret = CGRect(x: side * Self.caretX, y: midY - caretH / 2, width: caretW, height: caretH)
            context.fill(Path(roundedRect: caret, cornerRadius: caretW / 2), with: .style(.tint))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
