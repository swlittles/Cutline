import AppKit
import CoreText

/// The channel badge on shorts: a rounded container in the platform's colour with its logo and
/// the creator's @username. Proportions follow a 76-unit-tall badge; the width follows the name.
public enum BrandBadge {
    public static func color(_ platform: ShortBranding.Platform) -> CGColor {
        platform == .kick ? CGColor(srgbRed: 0x53 / 255.0, green: 0xFC / 255.0, blue: 0x18 / 255.0, alpha: 1) : CGColor(srgbRed: 0x91 / 255.0, green: 0x46 / 255.0, blue: 0xFF / 255.0, alpha: 1)
    }
    /// Logo artwork on a 24×24 grid.
    public static func logo(_ platform: ShortBranding.Platform) -> CGPath {
        platform == .kick ? kickLogo : twitchLogo
    }
    static let kickLogo = SVGPath.parse("M1.333 0h8v5.333H12V2.667h2.667V0h8v8H20v2.667h-2.667v2.666H20V16h2.667v8h-8v-2.667H12v-2.666H9.333V24h-8Z")
    static let twitchLogo = SVGPath.parse("M11.571 4.714h1.715v5.143H11.57zm4.715 0H18v5.143h-1.714zM6 0L1.714 4.286v15.428h5.143V24l4.286-4.286h3.428L22.286 12V0zm14.571 11.143l-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714Z")

    /// The badge's pixel height on a frame of this size.
    public static func height(for branding: ShortBranding, canvas: CGSize) -> CGFloat {
        (canvas.height * BadgePlacement.standardHeight * branding.placement.size).rounded()
    }

    /// Draws the badge `height` pixels tall, no wider than `maxWidth`. Nil without a username.
    public static func image(_ branding: ShortBranding, height: CGFloat, maxWidth: CGFloat = .infinity) -> CGImage? {
        let text = branding.displayText
        guard !text.isEmpty, height >= 4 else { return nil }
        let unit = height / 76
        func line(_ size: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white,
                .strokeColor: NSColor.white, .strokeWidth: -2.0
            ]))
        }
        var fontSize = 38 * unit, label = line(fontSize)
        var textWidth = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
        let inset = 96 * unit, trailing = 28 * unit
        // Long names shrink to fit rather than leave the frame.
        for _ in 0..<4 where inset + textWidth + trailing > maxWidth && textWidth > 0 {
            fontSize *= max(0.05, (maxWidth - inset - trailing) / textWidth * 0.98); label = line(fontSize)
            textWidth = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
        }
        let width = Int(min(ceil(inset + textWidth + trailing), maxWidth.rounded(.down))), pixels = Int(ceil(height))
        guard width > 0, let cg = CGContext(data: nil, width: width, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(pixels))
        let brand = color(branding.badge)
        // A 6-unit platform-colour border around a near-black body.
        cg.addPath(CGPath(roundedRect: bounds, cornerWidth: 20 * unit, cornerHeight: 20 * unit, transform: nil)); cg.setFillColor(brand); cg.fillPath()
        cg.addPath(CGPath(roundedRect: bounds.insetBy(dx: 6 * unit, dy: 6 * unit), cornerWidth: 14 * unit, cornerHeight: 14 * unit, transform: nil))
        cg.setFillColor(CGColor(srgbRed: 0x05 / 255.0, green: 0x05 / 255.0, blue: 0x05 / 255.0, alpha: 1)); cg.fillPath()
        // The 24-unit logo, 54 units tall, 20 in from the left and centred vertically.
        cg.saveGState()
        cg.translateBy(x: 20 * unit, y: bounds.height - 11 * unit); cg.scaleBy(x: 2.25 * unit, y: -2.25 * unit)
        cg.addPath(logo(branding.badge)); cg.setFillColor(brand); cg.fillPath(using: .winding)
        cg.restoreGState()
        // Centre the capitals: handles rarely descend, and @ sits on the cap height.
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(label, &ascent, nil, nil)
        let capHeight = NSFont.systemFont(ofSize: fontSize, weight: .bold).capHeight
        cg.textPosition = CGPoint(x: inset, y: (bounds.height - capHeight) / 2)
        CTLineDraw(label, cg)
        return cg.makeImage()
    }
}

/// Enough of SVG path syntax for logo artwork: move, line, horizontal, vertical and close,
/// absolute or relative, with repeated coordinates.
enum SVGPath {
    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = [], number = ""
        func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
        for character in data {
            if character.isLetter && character != "e" { flush(); tokens.append(String(character)) }
            else if character == "-" && !number.isEmpty && !number.hasSuffix("e") { flush(); number = "-" }
            else if character == "," || character == " " { flush() }
            else if character == "." && number.contains(".") { flush(); number = "." }
            else { number.append(character) }
        }
        flush()
        var index = 0, command = "M", current = CGPoint.zero, start = CGPoint.zero
        func next() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index]) ?? 0) }
        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter { command = tokens[index]; index += 1 }
            let relative = command == command.lowercased()
            switch command.uppercased() {
            case "M":
                let x = next(), y = next()
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                start = current; path.move(to: current)
                command = relative ? "l" : "L"
            case "L":
                let x = next(), y = next()
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y); path.addLine(to: current)
            case "H":
                let x = next(); current.x = relative ? current.x + x : x; path.addLine(to: current)
            case "V":
                let y = next(); current.y = relative ? current.y + y : y; path.addLine(to: current)
            case "Z":
                path.closeSubpath(); current = start
                if index < tokens.count, let first = tokens[index].first, !first.isLetter { command = "L" }
            default:
                index += 1
            }
        }
        return path
    }
}
