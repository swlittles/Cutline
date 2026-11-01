import SwiftUI
import AppKit
import CutlineCore

/// Claude-inspired palette: warm ivory and slate surfaces with a terracotta accent.
/// Every color resolves per appearance, so light and dark stay in step.
enum Studio {
    static let base = dynamic(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let panel = dynamic(light: 0xF3F1EA, dark: 0x262624)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x30302E)
    static let well = dynamic(light: 0xEAE7DD, dark: 0x191918)
    static let line = dynamic(light: 0xE2DFD4, dark: 0x3A3935)
    static let text = dynamic(light: 0x1A1915, dark: 0xF5F4EE)
    static let muted = dynamic(light: 0x6E6C64, dark: 0xA3A198)
    static let accent = dynamic(light: 0xC6613F, dark: 0xD97757)
    static let onAccent = Color.white
    static let success = dynamic(light: 0x2F7D4F, dark: 0x74C493)
    static let warning = dynamic(light: 0xA15C00, dark: 0xE9B45A)
    static let danger = dynamic(light: 0xB3392F, dark: 0xF0857B)
    /// Secondary data series (motion in activity strips).
    static let series = dynamic(light: 0x5B6BC0, dark: 0x9AA5F0)

    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .medium, design: .serif) }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

/// System, light or dark. Applied to NSApp so sheets, panels and menus follow too.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var label: String { ["System", "Light", "Dark"][Self.allCases.firstIndex(of: self)!] }
    var icon: String { ["circle.lefthalf.filled", "sun.max", "moon"][Self.allCases.firstIndex(of: self)!] }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
    static var current: AppearanceMode { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
    static func apply(_ mode: AppearanceMode) { NSApp.appearance = mode.appearance }
}

struct AppearanceMenu: View {
    @AppStorage(AppearanceMode.key) private var mode = AppearanceMode.system.rawValue
    var body: some View {
        let current = AppearanceMode(rawValue: mode) ?? .system
        Menu {
            Picker("Appearance", selection: $mode) {
                ForEach(AppearanceMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
            }.pickerStyle(.inline)
        } label: { Image(systemName: current.icon).font(.system(size: 13)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Studio.muted).help("Appearance").accessibilityIdentifier("appearance.menu")
            .onChange(of: mode) { _, value in AppearanceMode.apply(AppearanceMode(rawValue: value) ?? .system) }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12.5, weight: .semibold)).foregroundStyle(Studio.onAccent)
            .padding(.horizontal, large ? 20 : 14).frame(minHeight: large ? 40 : 32)
            .background(Studio.accent.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? 1 : 0.4).contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 12.5, weight: .medium)).foregroundStyle(Studio.text)
            .padding(.horizontal, large ? 18 : 12).frame(minHeight: large ? 40 : 30)
            .background(configuration.isPressed ? Studio.well : Studio.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.line))
            .opacity(enabled ? 1 : 0.45).contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Text-only actions: links, header items, secondary navigation.
struct QuietButtonStyle: ButtonStyle {
    var color: Color = Studio.muted
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(color).opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.4).contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryLarge: SecondaryButtonStyle { SecondaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    static var accentLink: QuietButtonStyle { QuietButtonStyle(color: Studio.accent) }
}

// MARK: - Shared building blocks

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Studio.muted) }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { SectionLabel(title) }
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
    }
}

struct StudioBrand: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scissors").font(.system(size: 15, weight: .semibold)).foregroundStyle(Studio.accent)
            Text("Cutline").font(.system(size: 19, weight: .medium, design: .serif)).foregroundStyle(Studio.text)
            // Local builds say so on every screen, so they're never mistaken for the release app.
            if AppEnvironment.current.isDevelopment {
                Text("DEV").font(.system(size: 10, weight: .bold)).foregroundStyle(Studio.panel)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(Studio.warning, in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Development build")
            }
        }.accessibilityElement(children: .combine).accessibilityIdentifier(AppEnvironment.current.isDevelopment ? "brand.development" : "brand")
    }
}

/// One header for every screen: brand on the left (clear of the window buttons), content, then actions.
struct AppHeader<Center: View, Trailing: View>: View {
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            StudioBrand().padding(.leading, 22)
            center
            HStack(spacing: 14) { trailing; AppearanceMenu() }
        }.padding(.trailing, 18).frame(height: 50).background(Studio.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
}

/// Bottom status line shared by the clipper and editor.
struct StatusBar: View {
    let text: String
    var busy = false
    var trailing: String? = AppEnvironment.currentVersionLabel
    /// Transcript text, and maybe still frames, go to OpenRouter when AI picks moments.
    var sharesTranscript = false
    var sharesFrames = false
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(busy ? Studio.warning : Studio.success).frame(width: 6, height: 6)
            Text(text).lineLimit(1).accessibilityIdentifier("editor.status")
            Spacer()
            if sharesFrames { Label("Transcript and still frames go to OpenRouter; audio stays on this Mac", systemImage: "network").labelStyle(.titleAndIcon) }
            else if sharesTranscript { Label("Transcript text goes to OpenRouter; video and audio stay on this Mac", systemImage: "network").labelStyle(.titleAndIcon) }
            else { Label("Everything stays on this Mac", systemImage: "lock").labelStyle(.titleAndIcon) }
            if let trailing { Text("·"); Text(trailing) }
        }.font(.system(size: 10.5)).foregroundStyle(Studio.muted).padding(.horizontal, 18).frame(height: 28).background(Studio.panel)
            .overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
}

/// A thin labelled progress line for long jobs.
struct ProgressLine: View {
    let value: Double
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message).font(.system(size: 12)).foregroundStyle(Studio.text).lineLimit(1)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Studio.well)
                    Capsule().fill(Studio.accent).frame(width: max(4, geometry.size.width * max(0, min(1, value))))
                }
            }.frame(height: 5)
        }
    }
}
