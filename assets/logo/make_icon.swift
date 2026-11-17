// Draws the VocalCord mark (W2: six silver bars) and the macOS app icon.
// Usage: swift make_icon.swift <output folder>
import AppKit

let heights: [CGFloat] = [0.28, 0.55, 1.00, 0.70, 0.40, 0.18]

func gray(_ w: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: w, alpha: a) }

/// Draws the six bars centred at `center`, `maxH` tall, as polished silver tubes.
func drawMark(_ ctx: CGContext, center: CGPoint, maxH: CGFloat) {
    let w = maxH * 64 / 560, gap = maxH * 40 / 560
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    let space = CGColorSpaceCreateDeviceGray()
    // Across each tube: dark rim, bright highlight, soft body, dark rim.
    let across = CGGradient(colorsSpace: space, colors: [gray(0.36), gray(0.82), gray(1.0), gray(0.84), gray(0.62), gray(0.74), gray(0.34)] as CFArray,
                            locations: [0, 0.16, 0.27, 0.45, 0.72, 0.86, 1])!
    // Along the mark: a faint reflection band just below the middle.
    let along = CGGradient(colorsSpace: space, colors: [gray(1, 0.18), gray(1, 0), gray(0.2, 0.32), gray(1, 0.16), gray(1, 0)] as CFArray,
                           locations: [0, 0.38, 0.52, 0.64, 1])!
    for (i, h) in heights.enumerated() {
        let x = center.x - total / 2 + CGFloat(i) * (w + gap)
        let height = max(w, maxH * h)
        let rect = CGRect(x: x, y: center.y - height / 2, width: w, height: height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(across, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        ctx.drawLinearGradient(along, start: CGPoint(x: 0, y: center.y + maxH / 2), end: CGPoint(x: 0, y: center.y - maxH / 2), options: [])
        // Specular stripe.
        ctx.setFillColor(gray(1, 0.9))
        let stripe = CGRect(x: rect.minX + w * 0.22, y: rect.minY + w * 0.35, width: w * 0.08, height: max(0, rect.height - w * 0.7))
        ctx.addPath(CGPath(roundedRect: stripe, cornerWidth: w * 0.05, cornerHeight: w * 0.05, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

func png(size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let darkTop = CGColor(red: 0.105, green: 0.11, blue: 0.12, alpha: 1)
let darkBottom = CGColor(red: 0.024, green: 0.027, blue: 0.031, alpha: 1)

func icon(_ ctx: CGContext, _ size: CGFloat) {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape); ctx.setFillColor(darkBottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [darkTop, darkBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    drawMark(ctx, center: CGPoint(x: 512, y: 512), maxH: 500)
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(gray(1, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base, icon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2, icon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024, icon).write(to: out.appendingPathComponent("AppIcon-1024.png"))
try! png(size: 1024) { ctx, _ in
    ctx.setFillColor(CGColor(red: 0.027, green: 0.03, blue: 0.035, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    drawMark(ctx, center: CGPoint(x: 512, y: 512), maxH: 560)
}.write(to: out.appendingPathComponent("vocalcord-logo-black.png"))
try! png(size: 1024) { ctx, _ in drawMark(ctx, center: CGPoint(x: 512, y: 512), maxH: 560) }
    .write(to: out.appendingPathComponent("vocalcord-mark.png"))
