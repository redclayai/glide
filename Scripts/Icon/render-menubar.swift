// The menu-bar glyph: the same mark as the app icon, redrawn for ~16pt rather than scaled down.
//
// Scaling the app artwork would not work. At this size the icon's three streaks collapse into a
// grey smudge and the gradient fades to nothing, so the mark is rebuilt with two streaks, heavier
// strokes, and flat opacity — the silhouette survives, the detail is not missed.
//
// Rendered as a template image: pure black plus alpha, which AppKit recolours for light and dark
// menu bars and inverts when the menu is open.

import AppKit
import Foundation

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(points: CGFloat, scale: CGFloat) -> CGImage {
    let px = Int(points * scale)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    let s = CGFloat(px)

    func bar(x0: CGFloat, x1: CGFloat, thickness: CGFloat, dy: CGFloat, alpha: CGFloat) {
        let h = s * thickness
        let r = CGRect(x: s * x0, y: s * (0.5 + dy) - h / 2, width: s * (x1 - x0), height: h)
        ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.fillPath()
    }

    // Caret on the right, trail running into it. Two streaks only: a third is indistinguishable
    // from noise once the whole mark is 16 points wide.
    bar(x0: 0.08, x1: 0.60, thickness: 0.115, dy: 0,     alpha: 1.00)
    bar(x0: 0.26, x1: 0.52, thickness: 0.095, dy: 0.20,  alpha: 0.55)
    bar(x0: 0.30, x1: 0.50, thickness: 0.095, dy: -0.20, alpha: 0.40)

    let caretW = s * 0.125
    let caretH = s * 0.72
    let caret = CGRect(x: s * 0.70, y: (s - caretH) / 2, width: caretW, height: caretH)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: caret, cornerWidth: caretW / 2, cornerHeight: caretW / 2, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()!
}

for scale in [CGFloat(1), 2, 3] {
    let image = render(points: 18, scale: scale)
    let suffix = scale == 1 ? "" : "@\(Int(scale))x"
    let url = outDir.appendingPathComponent("menubar\(suffix).png")
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) (\(Int(18 * scale))px)")
}
