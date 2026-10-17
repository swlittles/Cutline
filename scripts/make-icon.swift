// Draws the Cutline app icon (a vertical short cut in two on a terracotta tile) and writes
// Config/AppIcon.icns. Run from the repository root: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s, y: s)
    // macOS icon grid: an 824 pt tile centred in 1024 with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    context.addPath(tilePath); context.setFillColor(color(0xC6613F)); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tilePath); context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xE08A68), color(0xB9532F)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // The dashed cut line runs across the whole tile.
    context.setStrokeColor(color(0xFAF9F5, 0.55)); context.setLineWidth(14); context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [30, 30])
    context.move(to: CGPoint(x: 150, y: 560)); context.addLine(to: CGPoint(x: 874, y: 560)); context.strokePath()
    context.restoreGState()
    // A 9:16 short, split at the cut line into two pieces nudged apart.
    let card = CGRect(x: 512 - 165, y: 512 - 293, width: 330, height: 586)
    let cut: CGFloat = 560, gap: CGFloat = 22
    let ivory = color(0xFAF9F5)
    func piece(_ clip: CGRect, dx: CGFloat, dy: CGFloat) {
        context.saveGState()
        context.translateBy(x: dx, y: dy)
        context.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x5A2412, 0.35))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.clip(to: clip)
        context.addPath(CGPath(roundedRect: card, cornerWidth: 54, cornerHeight: 54, transform: nil))
        context.setFillColor(ivory); context.fillPath()
        context.endTransparencyLayer()
        context.restoreGState()
    }
    piece(CGRect(x: 0, y: cut + gap / 2, width: 1024, height: 1024), dx: -18, dy: 10)
    piece(CGRect(x: 0, y: 0, width: 1024, height: cut - gap / 2), dx: 18, dy: -10)
    // Play mark on the lower piece.
    context.translateBy(x: 18, y: -10)
    let play = CGMutablePath()
    play.move(to: CGPoint(x: 478, y: 446)); play.addLine(to: CGPoint(x: 478, y: 318)); play.addLine(to: CGPoint(x: 584, y: 382)); play.closeSubpath()
    context.addPath(play); context.setFillColor(color(0xC6613F)); context.setLineJoin(.round); context.setLineWidth(18)
    context.setStrokeColor(color(0xC6613F)); context.drawPath(using: .fillStroke)
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cutline-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let preview = CommandLine.arguments.dropFirst().first { try draw(1024).write(to: URL(fileURLWithPath: preview)) }
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Config/AppIcon.icns"]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Config/AppIcon.icns")
