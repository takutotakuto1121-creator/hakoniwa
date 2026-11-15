// Renders the 1024×1024 app icon: a bioluminescent creature in a dark lagoon.
// usage: swift scripts/make-icon.swift OUTPUT.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let S = CGFloat(size)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

// macOS icon grid: 824×824 rounded square centred in 1024.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(color(0.02, 0.05, 0.08))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Lagoon gradient.
let bg = CGGradient(colorsSpace: cs, colors: [color(0.05, 0.30, 0.34), color(0.02, 0.10, 0.16), color(0.01, 0.03, 0.07)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: S * 0.42, y: S * 0.62), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.5, y: S * 0.5), endRadius: S * 0.62, options: [.drawsAfterEndLocation])

// Caustic filaments.
ctx.setBlendMode(.screen)
var seed: UInt64 = 7
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
for k in 0..<14 {
    let path = CGMutablePath()
    let y0 = tile.minY + CGFloat(k) / 14 * tile.height
    path.move(to: CGPoint(x: tile.minX, y: y0))
    var x = tile.minX
    while x < tile.maxX {
        x += 8
        let y = y0 + sin(x / 70 + CGFloat(k)) * 26 + sin(x / 23 + CGFloat(k) * 2) * 8
        path.addLine(to: CGPoint(x: x, y: y))
    }
    ctx.addPath(path)
    ctx.setStrokeColor(color(0.35, 0.85, 0.85, 0.05 + 0.04 * rnd()))
    ctx.setLineWidth(3 + 4 * rnd())
    ctx.strokePath()
}

// Floating algae.
for _ in 0..<38 {
    let p = CGPoint(x: tile.minX + rnd() * tile.width, y: tile.minY + rnd() * tile.height)
    let r = 3 + rnd() * 5
    let g = CGGradient(colorsSpace: cs, colors: [color(0.45, 1.0, 0.55, 0.9), color(0.2, 0.9, 0.5, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * 2.4, options: [])
}

// The creature: segmented glowing body, tail fan, fins, big eye.
let hue = (r: CGFloat(0.55), g: CGFloat(1.0), b: CGFloat(0.85))
let center = CGPoint(x: S * 0.56, y: S * 0.52)
let angle: CGFloat = 0.32
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: angle)

// Halo.
let halo = CGGradient(colorsSpace: cs, colors: [color(hue.r, hue.g, hue.b, 0.55), color(hue.r, hue.g, hue.b, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(halo, startCenter: CGPoint(x: -60, y: 0), startRadius: 0, endCenter: CGPoint(x: -60, y: 0), endRadius: 420, options: [])

ctx.setBlendMode(.normal)
// Tail fan.
let tail = CGMutablePath()
tail.move(to: CGPoint(x: -230, y: 0))
tail.addQuadCurve(to: CGPoint(x: -400, y: 95), control: CGPoint(x: -310, y: 15))
tail.addQuadCurve(to: CGPoint(x: -360, y: 0), control: CGPoint(x: -390, y: 40))
tail.addQuadCurve(to: CGPoint(x: -400, y: -95), control: CGPoint(x: -390, y: -40))
tail.addQuadCurve(to: CGPoint(x: -230, y: 0), control: CGPoint(x: -310, y: -15))
ctx.addPath(tail)
ctx.setFillColor(color(0.3, 0.9, 0.85, 0.75))
ctx.fillPath()

// Fins.
for s: CGFloat in [-1, 1] {
    let fin = CGMutablePath()
    fin.move(to: CGPoint(x: 20, y: s * 95))
    fin.addQuadCurve(to: CGPoint(x: -120, y: s * 205), control: CGPoint(x: -10, y: s * 210))
    fin.addQuadCurve(to: CGPoint(x: -60, y: s * 90), control: CGPoint(x: -110, y: s * 120))
    fin.closeSubpath()
    ctx.addPath(fin)
    ctx.setFillColor(color(0.3, 0.85, 0.9, 0.55))
    ctx.fillPath()
}

// Body segments (back to front).
let segs: [(x: CGFloat, r: CGFloat)] = [(-205, 58), (-130, 82), (-40, 104), (70, 118)]
for (i, sg) in segs.enumerated() {
    let rect = CGRect(x: sg.x - sg.r, y: -sg.r, width: sg.r * 2, height: sg.r * 2)
    let t = CGFloat(i) / CGFloat(segs.count - 1)
    let g = CGGradient(colorsSpace: cs, colors: [color(0.85, 1.0, 0.95), color(0.35 + 0.1 * t, 0.95, 0.85), color(0.05, 0.45, 0.55)] as CFArray,
                       locations: [0, 0.45, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: sg.x + sg.r * 0.25, y: sg.r * 0.35), startRadius: 0,
                           endCenter: CGPoint(x: sg.x, y: 0), endRadius: sg.r * 1.05, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // Rim light.
    ctx.addEllipse(in: rect.insetBy(dx: 2, dy: 2))
    ctx.setStrokeColor(color(0.8, 1.0, 0.95, 0.65))
    ctx.setLineWidth(4)
    ctx.strokePath()
}
// Photophores.
for (x, y, r) in [(-140.0, 30.0, 9.0), (-100, -42, 7), (-30, 52, 10), (-10, -30, 8), (40, 58, 7), (-185, -14, 6)] {
    let p = CGPoint(x: x, y: y)
    let g = CGGradient(colorsSpace: cs, colors: [color(1, 1, 0.85, 1), color(1, 1, 0.7, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: CGFloat(r) * 2.4, options: [])
}
// Eye.
let eye = CGRect(x: 108, y: 18, width: 74, height: 74)
ctx.addEllipse(in: eye)
ctx.setFillColor(color(0.98, 0.99, 1.0))
ctx.fillPath()
ctx.addEllipse(in: CGRect(x: 132, y: 34, width: 44, height: 44))
ctx.setFillColor(color(0.02, 0.03, 0.06))
ctx.fillPath()
ctx.addEllipse(in: CGRect(x: 140, y: 58, width: 14, height: 14))
ctx.setFillColor(color(1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// Glass highlight along the top edge.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let hl = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.14), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: S / 2, y: tile.maxY), end: CGPoint(x: S / 2, y: tile.maxY - 260), options: [])
ctx.restoreGState()
ctx.addPath(tilePath)
ctx.setStrokeColor(color(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
