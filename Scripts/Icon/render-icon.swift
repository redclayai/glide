// Renders Glide's app icon artwork at 1024x1024, one PNG per appearance, matching the layer
// layout the existing .icon bundle expects (full-bleed squircle art, one image per appearance).
//
// The mark: a caret with the text gliding out of it. That is literally what the app does — a
// suggestion streaming to the right of the insertion point — and it reads at 16pt, which a keycap
// with three dashes does not.

import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

enum Appearance: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case clear = "Clear"
}

/// Apple's squircle is a continuous-curvature rounded rect; a plain rounded rect reads subtly wrong
/// next to the rest of the Dock, so approximate the superellipse directly.
func squirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = radius
    let k: CGFloat = 0.37   // control-point ratio that approximates the continuous corner
    let (x, y, w, h) = (rect.minX, rect.minY, rect.width, rect.height)

    path.move(to: CGPoint(x: x + r, y: y))
    path.addLine(to: CGPoint(x: x + w - r, y: y))
    path.addCurve(to: CGPoint(x: x + w, y: y + r),
                  control1: CGPoint(x: x + w - r * k, y: y),
                  control2: CGPoint(x: x + w, y: y + r * k))
    path.addLine(to: CGPoint(x: x + w, y: y + h - r))
    path.addCurve(to: CGPoint(x: x + w - r, y: y + h),
                  control1: CGPoint(x: x + w, y: y + h - r * k),
                  control2: CGPoint(x: x + w - r * k, y: y + h))
    path.addLine(to: CGPoint(x: x + r, y: y + h))
    path.addCurve(to: CGPoint(x: x, y: y + h - r),
                  control1: CGPoint(x: x + r * k, y: y + h),
                  control2: CGPoint(x: x, y: y + h - r * k))
    path.addLine(to: CGPoint(x: x, y: y + r))
    path.addCurve(to: CGPoint(x: x + r, y: y),
                  control1: CGPoint(x: x, y: y + r * k),
                  control2: CGPoint(x: x + r * k, y: y))
    path.closeSubpath()
    return path
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray,
               locations: locations)!
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(_ appearance: Appearance) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // No plate is drawn. Icon Composer supplies the background itself — that is what the
    // `fill-specializations` in icon.json are — and the layers are meant to be foreground art on
    // transparency. Drawing our own plate produced a second bevelled squircle nested inside the
    // system's, which is the muddy double-frame the first attempt shipped with.

    // MARK: The mark — a caret that has travelled, leaving a trail

    // Read left to right: the trail dissolves in from the left, gathers into a solid bar, and stops
    // at the caret. Three ragged lines beside a caret read as a paragraph; one tapering streak
    // ending in the caret reads as movement, which is the name of the app.

    let centerY = size * 0.5
    let caretWidth = size * 0.062
    let caretHeight = size * 0.355
    let caretX = size * 0.605

    let accent: CGColor
    let caretColor: CGColor
    switch appearance {
    case .light:
        accent = rgb(0, 118, 255)
        caretColor = rgb(26, 28, 34)
    case .dark:
        accent = rgb(60, 160, 255)
        caretColor = rgb(246, 247, 251)
    case .clear:
        accent = CGColor(gray: 1, alpha: 1)
        caretColor = CGColor(gray: 1, alpha: 1)
    }

    /// One streak: a rounded bar fading out towards its tail on the left.
    func streak(fromX: CGFloat, toX: CGFloat, thickness: CGFloat, dy: CGFloat, alpha: CGFloat) {
        let h = size * thickness
        let bar = CGRect(x: fromX, y: centerY - h / 2 + size * dy, width: toX - fromX, height: h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([accent.copy(alpha: 0)!, accent.copy(alpha: alpha)!], [0, 1]),
            start: CGPoint(x: bar.minX, y: bar.midY),
            end: CGPoint(x: bar.maxX, y: bar.midY),
            options: []
        )
        ctx.restoreGState()
    }

    // The main trail runs into the caret. Two shorter, fainter ones sit just above and below,
    // close enough to read as one gesture rather than as separate marks.
    streak(fromX: size * 0.145, toX: caretX - size * 0.014, thickness: 0.062, dy: 0, alpha: 1.0)
    streak(fromX: size * 0.280, toX: size * 0.530, thickness: 0.034, dy: 0.082, alpha: 0.45)
    streak(fromX: size * 0.335, toX: size * 0.500, thickness: 0.034, dy: -0.082, alpha: 0.30)

    let caret = CGRect(x: caretX, y: centerY - caretHeight / 2, width: caretWidth, height: caretHeight)
    ctx.setFillColor(caretColor)
    ctx.addPath(CGPath(roundedRect: caret, cornerWidth: caretWidth / 2, cornerHeight: caretWidth / 2, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()!
}

for appearance in Appearance.allCases {
    let image = render(appearance)
    let url = outDir.appendingPathComponent("Glide-\(appearance.rawValue).png")
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
