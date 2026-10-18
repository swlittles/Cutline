import SwiftUI
import CutlineCore

/// A platform's logo, from the same artwork as the badge on shorts.
struct PlatformLogo: View {
    let platform: ShortBranding.Platform
    var size: CGFloat = 14
    var body: some View {
        Path(BrandBadge.logo(platform)).applying(CGAffineTransform(scaleX: size / 24, y: size / 24))
            .fill(Color(cgColor: BrandBadge.color(platform)), style: FillStyle(eoFill: false))
            .frame(width: size, height: size)
    }
}

/// Kick and Twitch usernames, and which platform's badge shorts carry.
struct BrandingFields: View {
    @Binding var branding: ShortBranding
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(.kick, $branding.kick)
            row(.twitch, $branding.twitch)
            HStack {
                Text("Badge on shorts").font(.system(size: 12))
                Spacer()
                Picker("Badge on shorts", selection: $branding.badge) {
                    ForEach(ShortBranding.Platform.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("branding.badge")
            }
            if branding.displayText.isEmpty {
                Text("Add your \(branding.badge.label) username to show the \(branding.badge.label) badge.").font(.system(size: 11)).foregroundStyle(Studio.warning)
            }
        }
    }
    private func row(_ platform: ShortBranding.Platform, _ name: Binding<String>) -> some View {
        HStack(spacing: 8) {
            PlatformLogo(platform: platform)
            Text(platform.site).font(.system(size: 12, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 82, alignment: .leading)
            TextField("\(platform.label) username", text: name, prompt: Text("your \(platform.label) username")).labelsHidden()
                .textFieldStyle(.roundedBorder).onSubmit { name.wrappedValue = ShortBranding.username(name.wrappedValue) }
                .accessibilityIdentifier("branding.\(platform.rawValue)")
        }
    }
}

/// Size for the badge; its position is set by dragging it in the preview.
struct BadgeSizeControl: View {
    @Binding var placement: BadgePlacement
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Badge size").font(.system(size: 12))
                Image(systemName: "textformat.size.smaller").foregroundStyle(Studio.muted)
                Slider(value: $placement.size, in: BadgePlacement.sizes).accessibilityIdentifier("branding.size")
                Image(systemName: "textformat.size.larger").foregroundStyle(Studio.muted)
                Button("Reset") { placement = BadgePlacement() }.buttonStyle(.accentLink).disabled(placement == BadgePlacement()).accessibilityIdentifier("branding.reset")
            }
            Text("Drag the badge in the preview to move it.").font(.system(size: 11)).foregroundStyle(Studio.muted)
        }
    }
}

/// The channel badge drawn into a short preview: the same renderer as exports, at screen scale.
/// With a placement binding, dragging moves it.
struct PreviewBadge: View {
    let branding: ShortBranding
    let canvas: CGSize
    var placement: Binding<BadgePlacement>?
    @State private var origin: BadgePlacement?
    @Environment(\.displayScale) private var scale
    private static let cache = NSCache<NSString, NSImage>()
    var body: some View {
        let current = placement?.wrappedValue ?? branding.placement
        let height = canvas.height * BadgePlacement.standardHeight * current.size
        let image = Self.image(branding, height: height, maxWidth: canvas.width * 0.94, scale: scale)
        let size = image?.size ?? CGSize(width: max(60, canvas.width * 0.42 * current.size), height: max(12, height))
        let rect = current.rect(badge: size, canvas: canvas)
        Group {
            if let image {
                Image(nsImage: image).resizable().frame(width: size.width, height: size.height)
            } else {
                Text("Your \(branding.badge.label) username").font(.system(size: max(7, height * 0.42), weight: .semibold)).foregroundStyle(Studio.warning)
                    .frame(width: size.width, height: size.height)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: height * 0.26))
                    .overlay(RoundedRectangle(cornerRadius: height * 0.26).strokeBorder(Studio.warning, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            guard let placement else { return }
            let start = origin ?? current
            if origin == nil { origin = current }
            // Keep the centre where the whole badge stays visible.
            let halfX = min(0.5, size.width / 2 / canvas.width), halfY = min(0.5, size.height / 2 / canvas.height)
            placement.wrappedValue.x = min(1 - halfX, max(halfX, start.x + value.translation.width / canvas.width))
            placement.wrappedValue.y = min(1 - halfY, max(halfY, start.y + value.translation.height / canvas.height))
        }.onEnded { _ in origin = nil }, including: placement == nil ? .none : .all)
        .onHover { inside in if placement != nil { if inside { NSCursor.openHand.push() } else { NSCursor.pop() } } }
        .help(placement == nil ? "" : "Drag to move your channel badge")
        .accessibilityElement().accessibilityLabel("Channel badge \(branding.displayText)").accessibilityIdentifier("preview.badge")
    }
    static func image(_ branding: ShortBranding, height: CGFloat, maxWidth: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = (height * scale).rounded()
        let key = "\(branding.badge.rawValue)|\(branding.displayText)|\(pixels)|\((maxWidth * scale).rounded())" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let bitmap = BrandBadge.image(branding, height: pixels, maxWidth: maxWidth * scale) else { return nil }
        let image = NSImage(cgImage: bitmap, size: CGSize(width: CGFloat(bitmap.width) / scale, height: CGFloat(bitmap.height) / scale))
        cache.setObject(image, forKey: key)
        return image
    }
}
