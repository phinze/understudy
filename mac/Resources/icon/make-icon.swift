// Draws Understudy's app icon: a camera lens inside blob-tracking brackets.
// Regenerate with Resources/icon/make-icon.sh after changing this.
import AppKit
import CoreGraphics
import CoreText

let size = 1024.0
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(
        srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ stops: [(UInt32, Double)]) -> CGGradient {
    let colors: [CGColor] = stops.map { color($0.0) }
    let locations: [CGFloat] = stops.map { CGFloat($0.1) }
    return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// The body, on Apple's icon grid: 824pt squircle-ish rounded rect, centered.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x101318))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([(0x2A2F38, 0), (0x0C0E12, 1)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

let c = CGPoint(x: 512, y: 500)
func disc(_ r: Double, _ fill: (CGContext) -> Void) {
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    fill(ctx)
    ctx.restoreGState()
}

// Lens barrel, inner ring, then the glass.
disc(250) {
    $0.drawLinearGradient(
        gradient([(0x4A505B, 0), (0x1A1D23, 1)]), start: CGPoint(x: c.x, y: c.y + 250), end: CGPoint(x: c.x, y: c.y - 250),
        options: [])
}
disc(214) {
    $0.drawLinearGradient(
        gradient([(0x07080B, 0), (0x22262D, 1)]), start: CGPoint(x: c.x, y: c.y + 214), end: CGPoint(x: c.x, y: c.y - 214),
        options: [])
}
disc(172) {
    $0.drawRadialGradient(
        gradient([(0x3B4FA8, 0), (0x15204A, 0.55), (0x04060C, 1)]),
        startCenter: CGPoint(x: c.x + 30, y: c.y - 40), startRadius: 0, endCenter: c, endRadius: 172, options: [])
}
// Iris and glints.
disc(64) { $0.setFillColor(color(0x020306)); $0.fill(CGRect(x: 0, y: 0, width: size, height: size)) }
ctx.setFillColor(color(0xFFFFFF, 0.55))
ctx.fillEllipse(in: CGRect(x: c.x - 105, y: c.y + 52, width: 70, height: 44))
ctx.setFillColor(color(0xFFFFFF, 0.25))
ctx.fillEllipse(in: CGRect(x: c.x + 62, y: c.y - 92, width: 26, height: 26))

// Tracking brackets around the lens, in the overlay's default green.
let green = color(0x3CFF8C)
let half = 272.0
let arm = 84.0
ctx.setStrokeColor(green)
ctx.setLineWidth(20)
ctx.setLineCap(.square)
for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] {
    let corner = CGPoint(x: c.x + sx * half, y: c.y + sy * half)
    ctx.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
    ctx.addLine(to: corner)
    ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
}
ctx.strokePath()

// The overlay's label, above the top-left bracket.
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 36, nil)
let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: green] as CFDictionary
let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "ID 0001" as CFString, attrs))
ctx.textPosition = CGPoint(x: c.x - half - 10, y: c.y + half + 24)
CTLineDraw(line, ctx)

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
