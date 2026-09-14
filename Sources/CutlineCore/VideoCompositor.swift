import AVFoundation
import CoreImage
import AppKit
import CoreText

final class LayerRecipe: Sendable {
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let overlay: OverlayClip?
    init(trackID: CMPersistentTrackID, transform: CGAffineTransform, overlay: OverlayClip? = nil) {
        self.trackID = trackID; self.transform = transform; self.overlay = overlay
    }
}

final class FrameInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let main: LayerRecipe
    let overlays: [LayerRecipe]
    let adjustments: ClipAdjustments
    let captions: [ProjectedCaption]
    let captionStyle: CaptionStyle
    let sourceIn: Double
    let shortFraming: ShortFraming?
    let hook: String
    init(range: CMTimeRange, main: LayerRecipe, overlays: [LayerRecipe], adjustments: ClipAdjustments, captions: [ProjectedCaption], style: CaptionStyle, sourceIn: Double, shortFraming: ShortFraming? = nil, hook: String = "") {
        self.shortFraming = shortFraming; self.hook = hook
        timeRange = range; self.main = main; self.overlays = overlays; self.adjustments = adjustments
        self.captions = captions; captionStyle = style; self.sourceIn = sourceIn
        requiredSourceTrackIDs = ([main] + overlays).map { NSNumber(value: $0.trackID) }
    }
}

private final class CaptionBitmap {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

@objc(CutlineVideoCompositor)
// Mutable rendering state is isolated on queue; instruction data is immutable.
public final class CutlineVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "studio.cutline.compositor", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let bitmapCache = NSCache<NSString, CaptionBitmap>()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let cancellationLock = NSLock()
    private var cancellationGeneration = 0
    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    public override init() { super.init(); bitmapCache.totalCostLimit = 64 * 1024 * 1024 }
    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    public func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock(); cancellationGeneration += 1; cancellationLock.unlock()
    }
    private func generation() -> Int { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancellationGeneration }
    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let token = generation()
        queue.async { [self] in
            autoreleasepool {
                guard token == generation() else { request.finishCancelledRequest(); return }
                guard let instruction = request.videoCompositionInstruction as? FrameInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.main.trackID),
                      let destination = request.renderContext.newPixelBuffer() else {
                    request.finish(with: EditError.invalid("A video frame could not be rendered.")); return
                }
                let canvas = CGRect(origin: .zero, size: request.renderContext.size)
                let seconds = request.compositionTime.seconds
                var image = Self.oriented(CIImage(cvPixelBuffer: source), preferred: instruction.main.transform)
                let a = instruction.adjustments.interpolated(at: instruction.sourceIn + (seconds - instruction.timeRange.start.seconds) * instruction.adjustments.speed)
                if let framing = instruction.shortFraming {
                    image = Self.shortPanels(image, framing: framing, canvas: canvas, adjustments: a)
                } else {
                    image = Self.place(image, in: canvas, fill: a.fill, zoom: a.zoom, x: a.x, y: a.y, rotation: a.rotation, mirror: a.mirror)
                }
                image = image.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
                let elapsed = seconds - instruction.timeRange.start.seconds
                let remaining = instruction.timeRange.end.seconds - seconds
                let fade = min(a.fadeIn > 0 ? min(1, elapsed / a.fadeIn) : 1, a.fadeOut > 0 ? min(1, remaining / a.fadeOut) : 1)
                image = Self.opacity(image, max(0, fade)).composited(over: CIImage(color: .black).cropped(to: canvas))
                for layer in instruction.overlays {
                    guard let overlay = layer.overlay, seconds >= overlay.start, seconds < overlay.start + overlay.duration,
                          let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                    let overlayImage = Self.oriented(CIImage(cvPixelBuffer: frame), preferred: layer.transform)
                    let width = canvas.width * overlay.width
                    let height = width * overlayImage.extent.height / max(1, overlayImage.extent.width)
                    let rect = CGRect(x: canvas.width * overlay.x, y: canvas.height * (1 - overlay.y) - height, width: width, height: height)
                    let placed = Self.place(overlayImage, in: rect, fill: false)
                    image = Self.opacity(placed, overlay.opacity).composited(over: image)
                }
                if let cue = Self.activeCaption(instruction.captions, at: seconds),
                   let bitmap = captionImage(cue.text, style: instruction.captionStyle, canvas: canvas.size) {
                    let textImage = CIImage(cgImage: bitmap)
                    let transform = CGAffineTransform(translationX: (canvas.width - textImage.extent.width) / 2, y: canvas.height * instruction.captionStyle.bottom)
                    image = textImage.transformed(by: transform).composited(over: image)
                }
                if instruction.shortFraming != nil {
                    // Applied last: transforms, fades, overlays and captions cannot hide the mandatory branding.
                    let geometry = ShortGeometry(size: canvas.size)
                    image = shortBrand(size: geometry.brand.size).transformed(by: CGAffineTransform(translationX: 0, y: geometry.brand.minY)).composited(over: image)
                    if elapsed < min(3, instruction.timeRange.duration.seconds), !instruction.hook.isEmpty {
                        var style = CaptionStyle(); style.fontSize = 54; style.colorHex = "FFDF00"; style.background = true
                        if let bitmap = captionImage(instruction.hook, style: style, canvas: canvas.size) {
                            let hook = CIImage(cgImage: bitmap)
                            image = hook.transformed(by: CGAffineTransform(translationX: (canvas.width - hook.extent.width) / 2, y: geometry.gameplay.maxY - hook.extent.height - canvas.height * 0.012)).composited(over: image)
                        }
                    }
                }
                context.render(image.cropped(to: canvas), to: destination, bounds: canvas, colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: destination)
            }
        }
    }
    private static func activeCaption(_ captions: [ProjectedCaption], at time: Double) -> ProjectedCaption? {
        var low = 0, high = captions.count
        while low < high { let mid = (low + high) / 2; if captions[mid].start <= time { low = mid + 1 } else { high = mid } }
        guard low > 0, captions[low - 1].end > time else { return nil }
        return captions[low - 1]
    }
    private static func oriented(_ image: CIImage, preferred: CGAffineTransform) -> CIImage {
        // AVFoundation transforms use top-left coordinates; Core Image uses bottom-left.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)
        let transformed = image.transformed(by: flip.concatenating(preferred))
        let normalized = transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.minX, y: -transformed.extent.minY))
        return normalized.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: normalized.extent.height))
    }
    static func place(_ image: CIImage, in canvas: CGRect, fill: Bool, zoom: Double = 1, x: Double = 0, y: Double = 0, rotation: Double = 0, mirror: Bool = false) -> CIImage {
        let size = image.extent.size
        let fit = fill ? max(canvas.width / size.width, canvas.height / size.height) : min(canvas.width / size.width, canvas.height / size.height)
        var t = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
        t = t.concatenating(CGAffineTransform(scaleX: mirror ? -1 : 1, y: 1))
        t = t.concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
        t = t.concatenating(CGAffineTransform(scaleX: fit * zoom, y: fit * zoom))
        t = t.concatenating(CGAffineTransform(translationX: canvas.midX + x * canvas.width, y: canvas.midY + y * canvas.height))
        return image.transformed(by: t).cropped(to: canvas)
    }
    private static func opacity(_ image: CIImage, _ value: Double) -> CIImage {
        guard value < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: value)])
    }
    private func captionImage(_ original: String, style: CaptionStyle, canvas: CGSize) -> CGImage? {
        let text = style.uppercase ? original.uppercased() : original
        let key = "\(text)|\(style)|\(canvas)" as NSString
        if let cached = bitmapCache.object(forKey: key) { return cached.image }
        let scale = min(canvas.width, canvas.height) / 1080
        let font = NSFont.systemFont(ofSize: style.fontSize * scale, weight: .bold)
        let colorValue = UInt32(style.colorHex, radix: 16) ?? 0xffffff
        let color = NSColor(srgbRed: Double((colorValue >> 16) & 255) / 255, green: Double((colorValue >> 8) & 255) / 255, blue: Double(colorValue & 255) / 255, alpha: 1)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .strokeColor: NSColor.black, .strokeWidth: -3.0, .paragraphStyle: paragraph])
        let padding = 16 * scale
        let maxWidth = canvas.width * 0.88 - padding * 2
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: canvas.height * 0.7), nil)
        let width = Int(ceil(min(maxWidth, measured.width) + 2 * padding + 2)), height = Int(ceil(measured.height + 2 * padding + 4))
        guard width > 0, height > 0, let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style.background {
            cg.setFillColor(CGColor(gray: 0, alpha: 0.7))
            cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)); cg.fillPath()
        }
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: Double(width) - 2 * padding, height: Double(height) - 2 * padding), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), cg)
        guard let bitmap = cg.makeImage() else { return nil }
        bitmapCache.setObject(CaptionBitmap(bitmap), forKey: key, cost: width * height * 4)
        return bitmap
    }
    static func shortPanels(_ source: CIImage, framing: ShortFraming, canvas: CGRect, adjustments a: ClipAdjustments = ClipAdjustments()) -> CIImage {
        let geometry = ShortGeometry(size: canvas.size)
        func crop(_ region: ClipScanRegion) -> CIImage {
            let rect = CGRect(x: source.extent.minX + region.x * source.extent.width,
                              y: source.extent.minY + (1 - region.y - region.height) * source.extent.height,
                              width: region.width * source.extent.width, height: region.height * source.extent.height)
            return source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        let background = CIImage(color: .black).cropped(to: canvas)
        let gameplay = place(crop(framing.gameplay), in: geometry.gameplay, fill: !framing.containGameplay, zoom: a.zoom, x: a.x, y: a.y, rotation: a.rotation, mirror: a.mirror)
        let camera = place(crop(framing.camera), in: geometry.camera, fill: true)
        return camera.composited(over: gameplay.composited(over: background))
    }
    func shortBrand(size: CGSize) -> CIImage {
        let key = "mandatory-kick-brand-\(size)" as NSString
        if let cached = bitmapCache.object(forKey: key) { return CIImage(cgImage: cached.image) }
        let width = Int(size.width), height = Int(size.height)
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(CGRect(origin: .zero, size: size))
        let font = NSFont.systemFont(ofSize: size.height * 0.70, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Kick.com/your-channel", attributes: [.font: font, .foregroundColor: NSColor.white]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let logoSize = size.height * 0.74, gap = size.height * 0.25
        let left = (size.width - textWidth - gap - logoSize) / 2
        // Exact Kick mark path from reference-editor/packages/clipper/assets/short-brand-container.svg.
        let points: [(CGFloat, CGFloat)] = [(1.333,0),(9.333,0),(9.333,5.333),(12,5.333),(12,2.667),(14.667,2.667),(14.667,0),(22.667,0),(22.667,8),(20,8),(20,10.667),(17.333,10.667),(17.333,13.333),(20,13.333),(20,16),(22.667,16),(22.667,24),(14.667,24),(14.667,21.333),(12,21.333),(12,18.667),(9.333,18.667),(9.333,24),(1.333,24)]
        cg.saveGState(); cg.translateBy(x: left, y: (size.height + logoSize)/2); cg.scaleBy(x: logoSize/24, y: -logoSize/24)
        cg.setFillColor(CGColor(red: 83/255, green: 252/255, blue: 24/255, alpha: 1))
        cg.move(to: CGPoint(x: points[0].0, y: points[0].1)); for p in points.dropFirst() { cg.addLine(to: CGPoint(x: p.0, y: p.1)) }; cg.closePath(); cg.fillPath(); cg.restoreGState()
        cg.textPosition = CGPoint(x: left + logoSize + gap, y: (size.height - ascent - descent)/2 + descent); CTLineDraw(line, cg)
        guard let bitmap = cg.makeImage() else { return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)) }
        bitmapCache.setObject(CaptionBitmap(bitmap), forKey: key, cost: width * height * 4)
        return CIImage(cgImage: bitmap)
    }

}
