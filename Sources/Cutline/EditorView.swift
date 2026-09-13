import SwiftUI
import AVKit
import CutlineCore
import UniformTypeIdentifiers

enum Studio {
    static let base = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let panel = Color(red: 0.085, green: 0.098, blue: 0.11)
    static let raised = Color(red: 0.12, green: 0.135, blue: 0.15)
    static let mint = Color(red: 0.62, green: 0.95, blue: 0.75)
    static let muted = Color(red: 0.53, green: 0.59, blue: 0.62)
    static let line = Color.white.opacity(0.075)
}

struct EditorView: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Studio.line).frame(height: 1)
            HStack(spacing: 0) {
                library.frame(width: 320)
                Rectangle().fill(Studio.line).frame(width: 1)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Studio.line).frame(width: 1)
                InspectorView().frame(width: 260)
            }.frame(maxHeight: .infinity)
            TimelineView().frame(height: 340)
            HStack(spacing: 8) {
                Circle().fill(store.isExporting || store.isBuilding ? .orange : Studio.mint).frame(width: 5, height: 5)
                Text(store.status).lineLimit(1).accessibilityIdentifier("editor.status")
                Spacer()
                Text("LOCAL FIRST").tracking(1.5)
                Text("•").foregroundStyle(Studio.muted)
                Text("\(AppEnvironment.current.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
            }.font(.system(size: 10)).foregroundStyle(Studio.muted).padding(.horizontal, 18).frame(height: 29)
        }
        .disclosureGroupStyle(StudioDisclosureStyle())
        .background(Studio.base).tint(Studio.mint).frame(minWidth: 1120, minHeight: 760)
        .alert("Couldn’t complete that action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "scissors").font(.system(size: 18, weight: .bold)).foregroundStyle(Studio.mint)
                Text("cutline").font(.system(size: 22, weight: .bold, design: .rounded)).tracking(-0.8)
                Text("STUDIO").font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(Studio.muted).padding(.top, 5)
            }.padding(.leading, 76)
            Spacer()
            Text(store.project.name).accessibilityIdentifier("project.name").font(.system(size: 12, weight: .medium))
            if store.dirty { Circle().fill(Studio.muted).frame(width: 5, height: 5).help("Unsaved changes") }
            Spacer()
            Button { store.save() } label: { Image(systemName: "square.and.arrow.down").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Save project · ⌘S").accessibilityIdentifier("project.save")
            if store.isExporting { Button("Cancel") { store.exportTask?.cancel() }.font(.system(size: 11)) }
            Button(action: store.exportVideo) {
                HStack(spacing: 7) {
                    if store.isExporting { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.right") }
                    Text(store.isExporting ? "\(Int(store.exportProgress * 100))%" : "Export")
                }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Studio.base)
                    .padding(.horizontal, 16).frame(height: 33).background(Studio.mint, in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityIdentifier("project.export").buttonStyle(.plain).disabled(!store.canExport).opacity(store.canExport || store.isExporting ? 1 : 0.45)
        }.padding(.trailing, 18).frame(height: 64).background(Studio.panel)
    }
    private var library: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $store.workspace) {
                ForEach(["Media", "Captions", "AI", "Layers"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            switch store.workspace {
            case "Captions": CaptionPanel()
            case "AI": AIPanel()
            case "Layers": LayersPanel()
            default: mediaLibrary
            }
        }.background(Studio.panel)
    }
    private var mediaLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Label("Media", systemImage: "square.stack").font(.system(size: 13, weight: .semibold)); Spacer(); Text("\(store.project.media.count)").foregroundStyle(Studio.muted) }
                .padding(18)
            Button(action: store.importMedia) {
                Label(store.isImporting ? "Importing…" : "Import recordings", systemImage: "plus").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 36)
                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Studio.line))
            }.accessibilityIdentifier("media.import").buttonStyle(.plain).disabled(store.isImporting).padding(.horizontal, 16)
            HStack { Text("PROJECT MEDIA").tracking(1.2); Spacer(); Text("⌘I") }.font(.system(size: 9, weight: .medium)).foregroundStyle(Studio.muted).padding(.horizontal, 18).padding(.top, 25).padding(.bottom, 12)
            if store.project.media.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 29, weight: .ultraLight)).foregroundStyle(Studio.muted)
                    Text("Drop your recordings here").font(.system(size: 12, weight: .medium))
                    Text("Gameplay, facecam, a great moment.\nBring it all into your library.").font(.system(size: 11)).foregroundStyle(Studio.muted).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity).frame(height: 200).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Studio.line, style: StrokeStyle(lineWidth: 1, dash: [4]))).padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.project.media) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    thumbnail(item.id).frame(height: 111).clipped().contentShape(Rectangle()).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(timecode(item.duration)).font(.system(size: 9, design: .monospaced)).padding(4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(6)
                                }
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(item.url.pathExtension.uppercased() + "  •  SOURCE").font(.system(size: 8)).tracking(0.7).foregroundStyle(Studio.muted)
                                    }
                                    Spacer()
                                    Button { store.add(item) } label: { Image(systemName: "plus.circle.fill").font(.system(size: 19)).foregroundStyle(Studio.mint) }.buttonStyle(.plain).help("Add to timeline").accessibilityIdentifier("media.add.\(item.id)")
                                }
                            }.contentShape(Rectangle()).onTapGesture(count: 2) { store.add(item) }
                            .accessibilityElement(children: .contain).accessibilityIdentifier("media.item.\(item.id)")
                            .contextMenu {
                                Button("Add to timeline") { store.add(item) }
                                Button("Add as facecam / overlay") { store.addOverlay(item) }.disabled(store.project.clips.isEmpty)
                                Button("Transcribe recording") { store.transcriptionMediaID = item.id; store.workspace = "Captions" }
                                Button("Relink source…") { store.relink(item) }
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.accessibilityIdentifier("media.scroll")
            }
            Spacer(minLength: 0)
            Label("Original files stay untouched", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(Studio.muted).padding(18)
        }.background(Studio.panel)
        .dropDestination(for: URL.self) { urls, _ in store.importURLs(urls); return true }
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PLAYER").tracking(1.3)
                Spacer()
                Text(store.project.format.label).padding(.horizontal, 8).padding(.vertical, 4).background(Studio.raised, in: RoundedRectangle(cornerRadius: 4))
                Text("FIT").padding(.leading, 8)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(Studio.muted).padding(18)
            GeometryReader { geometry in
                ZStack {
                    if store.project.clips.isEmpty {
                        VStack(spacing: 19) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 21).fill(Studio.mint.opacity(0.07)).frame(width: 76, height: 76).rotationEffect(.degrees(-8))
                                Image(systemName: "play.rectangle").font(.system(size: 32, weight: .light)).foregroundStyle(Studio.mint)
                            }
                            VStack(spacing: 9) {
                                Text("Make the moment.").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.7)
                                Text("From a full stream to the clip worth sharing.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                            }
                            HStack(spacing: 20) {
                                miniStep("01", "Import"); miniStep("02", "Cut"); miniStep("03", "Share")
                            }.padding(.top, 9)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NativePlayer(player: store.player)
                            .aspectRatio(store.project.format.size.width / store.project.format.size.height, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if store.isBuilding { ProgressView("Preparing preview…").padding(18).background(Studio.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 8)) }
                }.frame(width: geometry.size.width, height: geometry.size.height).background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 9))
            }.padding(.horizontal, 22).padding(.bottom, 16)
            HStack(spacing: 18) {
                Text(timecode(store.playhead)).accessibilityIdentifier("player.time").foregroundStyle(Studio.mint)
                Text("/ " + timecode(store.project.duration)).accessibilityIdentifier("project.duration").foregroundStyle(Studio.muted)
                Spacer()
                Button { store.seek(store.playhead - 5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds · ←")
                Button(action: store.togglePlayback) { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15)).frame(width: 36, height: 32).background(Studio.raised, in: RoundedRectangle(cornerRadius: 6)) }.help("Play / pause · Space").accessibilityIdentifier("player.play")
                Button { store.seek(store.playhead + 5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds · →")
                Spacer()
                Text("\(store.project.options.fps) FPS").font(.system(size: 9)).foregroundStyle(Studio.muted)
            }.font(.system(size: 11, design: .monospaced)).buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 18)
        }
    }
    private func miniStep(_ number: String, _ label: String) -> some View {
        HStack(spacing: 6) { Text(number).foregroundStyle(Studio.mint.opacity(0.7)); Text(label).foregroundStyle(Studio.muted) }.font(.system(size: 10, weight: .medium))
    }
    @ViewBuilder private func thumbnail(_ id: UUID) -> some View {
        if let image = store.thumbnails[id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        else { Rectangle().fill(Studio.raised).overlay(Image(systemName: "film").foregroundStyle(Studio.muted)) }
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect
        // Live Text's VisionKit overlay can take first responder while a new
        // paused frame is analyzed, stealing keyboard input from editor fields.
        view.allowsVideoFrameAnalysis = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}


/// Make the whole section heading a keyboard-accessible toggle, not just its chevron.
struct StudioDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
