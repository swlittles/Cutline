import SwiftUI
import AVKit
import CutlineCore

/// The guided path from a stream recording to finished shorts, one step at a time.
struct ClipperView: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(spacing: 0) {
            ClipperHeader()
            Group {
                switch store.clipStep {
                case .importVOD: ImportStepView()
                case .setup: SetupStepView()
                case .review: ReviewStepView()
                case .export: ExportStepView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Studio.base)
            StatusBar(text: store.status, busy: store.isScanningClips || store.isExportingClips || store.isTranscribingClips)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("clipper")
    }
}

private struct ClipperHeader: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        AppHeader {
            Button(action: store.showHome) { Label("Home", systemImage: "house") }.buttonStyle(.quiet).help("Home").accessibilityIdentifier("clipper.home")
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(ClipStep.allCases) { step in
                    if step != .importVOD { Rectangle().fill(Studio.line).frame(width: 18, height: 1) }
                    StepChip(step: step)
                }
            }
            Spacer(minLength: 12)
        } trailing: {
            if store.isScanningClips {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding moments \(Int(store.clipProgress * 100))%").font(.system(size: 11)).foregroundStyle(Studio.muted)
                }.help(store.clipMessage).accessibilityIdentifier("clipper.scanning")
            }
            Button("Open editor", action: store.showEditor).buttonStyle(.quiet).help("Open the full timeline editor").accessibilityIdentifier("clipper.editor")
        }
    }
}

private struct StepChip: View {
    @EnvironmentObject var store: EditorStore
    let step: ClipStep
    var body: some View {
        let current = store.clipStep == step
        let done = step < store.clipStep
        let enabled = store.canEnter(step)
        Button { store.goTo(step) } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(current ? Studio.accent : done ? Studio.accent.opacity(0.16) : Studio.raised).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(current || done ? Color.clear : Studio.line))
                    if done && !current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Studio.accent) }
                    else { Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(current ? Studio.onAccent : Studio.muted) }
                }
                Text(step.title).font(.system(size: 12.5, weight: current ? .semibold : .regular)).foregroundStyle(current ? Studio.text : Studio.muted)
            }.padding(.horizontal, 4).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled && !current).opacity(enabled || current ? 1 : 0.5)
            .accessibilityIdentifier("step.\(step.rawValue)").accessibilityValue(current ? "Current" : done ? "Done" : "")
    }
}

/// Every step ends the same way: an optional way back and one primary action.
struct StepFooter<Leading: View>: View {
    var back: ClipStep?
    let title: String
    var enabled = true
    var hint: String?
    var identifier = "step.continue"
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @EnvironmentObject var store: EditorStore
    var body: some View {
        HStack(spacing: 14) {
            if let back { Button { store.goTo(back) } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.secondary).accessibilityIdentifier("step.back") }
            leading
            Spacer()
            if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(Studio.muted).lineLimit(2).multilineTextAlignment(.trailing).accessibilityIdentifier("step.hint") }
            Button(action: action) { HStack(spacing: 8) { Text(title); Image(systemName: "arrow.right") } }
                .buttonStyle(.primaryLarge).disabled(!enabled).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier(identifier)
        }.padding(.horizontal, 24).frame(height: 68).background(Studio.panel).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
}
extension StepFooter where Leading == EmptyView {
    init(back: ClipStep? = nil, title: String, enabled: Bool = true, hint: String? = nil, identifier: String = "step.continue", action: @escaping () -> Void) {
        self.init(back: back, title: title, enabled: enabled, hint: hint, identifier: identifier, action: action) { EmptyView() }
    }
}

struct StepTitle: View {
    let title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Studio.title(28)).tracking(-0.4)
            Text(detail).font(.system(size: 13)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A player with native inline controls, for scrubbing a source recording.
struct ScrubbingPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

func loadSourceFrame(_ media: MediaItem, at time: Double, maximum: CGSize = CGSize(width: 1280, height: 720)) async throws -> NSImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
    generator.appliesPreferredTrackTransform = true; generator.maximumSize = maximum
    let result = try await generator.image(at: CMTime(seconds: max(0, min(time, media.duration - 0.1)), preferredTimescale: 600))
    return NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height))
}

// MARK: - Region editing

struct RegionBox: Identifiable {
    let id: String
    let color: Color
    var region: Binding<ClipScanRegion>
}

/// Drag a box to move it; drag its corner handles to resize. Coordinates stay normalized.
struct RegionEditor: View {
    let image: NSImage?
    let boxes: [RegionBox]
    @State private var origin: [String: ClipScanRegion] = [:]
    var body: some View {
        GeometryReader { geometry in
            let ratio = image.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9
            let width = min(geometry.size.width, geometry.size.height * ratio)
            let size = CGSize(width: width, height: width / ratio)
            ZStack(alignment: .topLeading) {
                if let image { Image(nsImage: image).resizable().frame(width: size.width, height: size.height) }
                else { Rectangle().fill(Studio.well).overlay(ProgressView()) }
                ForEach(boxes) { box in boxView(box, size: size) }
            }.frame(width: size.width, height: size.height).clipped()
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
    private func boxView(_ box: RegionBox, size: CGSize) -> some View {
        let r = box.region.wrappedValue
        return Rectangle().fill(box.color.opacity(0.12)).overlay(Rectangle().stroke(box.color, lineWidth: 2))
            .overlay(alignment: .top) { Text(box.id).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(box.color, in: RoundedRectangle(cornerRadius: 4)) }
            .overlay(alignment: .topLeading) { handle(box.color).offset(x: -6, y: -6).gesture(drag(box, size: size, mode: .topLeading)) }
            .overlay(alignment: .bottomTrailing) { handle(box.color).offset(x: 6, y: 6).gesture(drag(box, size: size, mode: .bottomTrailing)) }
            .frame(width: max(0, r.width) * size.width, height: max(0, r.height) * size.height)
            .contentShape(Rectangle())
            .gesture(drag(box, size: size, mode: .move))
            .offset(x: r.x * size.width, y: r.y * size.height)
            .accessibilityElement().accessibilityLabel("\(box.id) region").accessibilityIdentifier("region.\(box.id)")
    }
    private func handle(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2)).shadow(color: .black.opacity(0.3), radius: 2)
    }
    private enum Mode { case move, topLeading, bottomTrailing }
    private func drag(_ box: RegionBox, size: CGSize, mode: Mode) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            let start = origin[box.id] ?? box.region.wrappedValue
            if origin[box.id] == nil { origin[box.id] = start }
            let dx = value.translation.width / max(1, size.width), dy = value.translation.height / max(1, size.height)
            var r = start
            let minimum = 0.05
            switch mode {
            case .move:
                r.x = min(max(0, start.x + dx), 1 - start.width); r.y = min(max(0, start.y + dy), 1 - start.height)
            case .topLeading:
                r.x = min(max(0, start.x + dx), start.x + start.width - minimum); r.width = start.x + start.width - r.x
                r.y = min(max(0, start.y + dy), start.y + start.height - minimum); r.height = start.y + start.height - r.y
            case .bottomTrailing:
                r.width = min(max(minimum, start.width + dx), 1 - start.x); r.height = min(max(minimum, start.height + dy), 1 - start.y)
            }
            box.region.wrappedValue = r
        }.onEnded { _ in origin[box.id] = nil }
    }
}

/// A still-frame mock of the final short: facecam, branding strip, gameplay and hook.
struct ShortLayoutPreview: View {
    let image: NSImage?
    let framing: ShortFraming
    let branding: ShortBranding
    var hook: String?
    /// When set, the channel badge can be dragged into place.
    var placement: Binding<BadgePlacement>?
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = width * 16 / 9
            VStack(spacing: 0) {
                panel(framing.camera, fill: true).frame(width: width, height: height * 0.30).clipped()
                Color.black.frame(width: width, height: height * 0.02)
                panel(framing.gameplay, fill: !framing.containGameplay).frame(width: width, height: height * 0.68).clipped().background(Color.black)
            }
            // As in exports, the hook draws over the badge.
            .overlay { PreviewBadge(branding: branding, canvas: CGSize(width: width, height: height), placement: placement) }
            .overlay(alignment: .top) {
                if let hook, !hook.isEmpty {
                    Text(hook).font(.system(size: max(8, height * 0.028), weight: .heavy)).multilineTextAlignment(.center).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.top, height * 0.34).padding(.horizontal, 10).allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height)
        }.aspectRatio(9 / 16, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line).allowsHitTesting(false)).shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
    @ViewBuilder private func panel(_ region: ClipScanRegion, fill: Bool) -> some View {
        if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), region.valid,
           let crop = cg.cropping(to: CGRect(x: region.x * Double(cg.width), y: region.y * Double(cg.height), width: region.width * Double(cg.width), height: region.height * Double(cg.height)).integral) {
            Image(nsImage: NSImage(cgImage: crop, size: CGSize(width: crop.width, height: crop.height))).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
        } else { Rectangle().fill(Studio.well) }
    }
}

// MARK: - Activity overview

/// Loudness and motion across the whole recording, with moments laid on top.
struct MomentHeatStrip: View {
    @EnvironmentObject var store: EditorStore
    var height: CGFloat = 84
    var onSeek: ((Double) -> Void)?
    var body: some View {
        let duration = max(0.1, store.clipMedia?.duration ?? 1)
        let audio = store.clipSettings.audioEnabled ? store.clipAnalysis?.audioTracks?[store.clipSettings.audioTrack] ?? [] : []
        let motion = store.clipAnalysis?.motionSamples ?? []
        let marks = store.moments.map { (candidate: store.applied($0), decision: store.decision($0.id)) }
        let focused = store.focusedMoment
        VStack(spacing: 4) {
            Canvas { context, size in
                let buckets = max(1, Int(size.width / 2))
                func bucket(_ time: Double) -> Int { min(buckets - 1, max(0, Int(time / duration * Double(buckets)))) }
                var loud = Array(repeating: -100.0, count: buckets), moving = Array(repeating: 0.0, count: buckets)
                for sample in audio { let b = bucket(sample.time); loud[b] = max(loud[b], sample.db) }
                for sample in motion where !sample.sceneCut { let b = bucket(sample.time); moving[b] = max(moving[b], sample.change) }
                let step = size.width / Double(buckets)
                for index in 0..<buckets {
                    let level = max(0, min(1, (loud[index] + 60) / 60))
                    if level > 0 { context.fill(Path(CGRect(x: Double(index) * step, y: size.height * (1 - level), width: max(1, step - 0.5), height: size.height * level)), with: .color(Studio.accent.opacity(0.35))) }
                    let move = CGFloat(max(0, min(1, moving[index] / 0.25)))
                    if move > 0 { context.fill(Path(CGRect(x: CGFloat(index) * step, y: size.height - 6 * move - 1, width: max(1, step - 0.5), height: 6 * move + 1)), with: .color(Studio.series.opacity(0.8))) }
                }
                for mark in marks {
                    let x = mark.candidate.start / duration * size.width, w = max(3, (mark.candidate.end - mark.candidate.start) / duration * size.width)
                    let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                    let color: Color = mark.decision == .kept ? Studio.success : mark.decision == .skipped ? Studio.muted.opacity(0.5) : Studio.text.opacity(0.6)
                    context.fill(Path(rect), with: .color(color.opacity(mark.decision == .skipped ? 0.25 : 0.3)))
                    context.stroke(Path(rect), with: .color(color), lineWidth: mark.candidate.id == focused ? 2.5 : 1)
                }
                if store.isScanningClips { context.fill(Path(CGRect(x: size.width * store.clipProgress, y: 0, width: 1.5, height: size.height)), with: .color(Studio.accent)) }
            }
            .frame(height: height).background(Studio.well).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { GeometryReader { geometry in
                Color.clear.contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { location in
                    let time = location.x / max(1, geometry.size.width) * duration
                    if let hit = marks.first(where: { time >= $0.candidate.start - 1 && time <= $0.candidate.end + 1 }) { store.focus(hit.candidate.id) }
                    else { onSeek?(time) }
                }
            } }
            .help("The whole recording. Taller bars are louder; boxes are moments. Click a box to watch it.")
            .accessibilityElement().accessibilityLabel("Activity across the recording").accessibilityIdentifier("heat.strip")
            HStack {
                Text("0:00"); Spacer(); Text(clockTime(duration / 2)); Spacer(); Text(clockTime(duration))
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted)
        }
    }
}

/// Loudness of one track across the recording, to tell mic, game and mix apart at a glance.
struct TrackSparkline: View {
    let samples: [ClipAudioSample]?
    let duration: Double
    var body: some View {
        Canvas { context, size in
            guard let samples, !samples.isEmpty else { return }
            let buckets = max(1, Int(size.width / 2))
            var loud = Array(repeating: -100.0, count: buckets)
            for sample in samples { let b = min(buckets - 1, max(0, Int(sample.time / max(0.1, duration) * Double(buckets)))); loud[b] = max(loud[b], sample.db) }
            let step = size.width / Double(buckets)
            for (index, db) in loud.enumerated() {
                let level = max(0, min(1, (db + 60) / 60))
                context.fill(Path(CGRect(x: Double(index) * step, y: size.height * (1 - level), width: max(1, step - 0.5), height: max(0.5, size.height * level))), with: .color(Studio.accent.opacity(0.75)))
            }
        }
        .overlay { if samples == nil { Text("Measuring…").font(.system(size: 9)).foregroundStyle(Studio.muted) } else if samples?.isEmpty == true { Text("Silent").font(.system(size: 9)).foregroundStyle(Studio.muted) } }
        .background(Studio.well).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
