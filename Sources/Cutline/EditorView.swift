import SwiftUI
import AVKit
import CutlineCore
import UniformTypeIdentifiers

/// The timeline editor. Simple mode shows what most edits need (trim, split, captions, hook,
/// export); Advanced adds layers, AI, color and transform tools.
struct EditorView: View {
    @EnvironmentObject var store: EditorStore
    @AppStorage("editor-advanced") private var advanced = false
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                library.frame(width: 300)
                Rectangle().fill(Studio.line).frame(width: 1)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Studio.line).frame(width: 1)
                InspectorView().frame(width: 280)
            }.frame(maxHeight: .infinity)
            TimelineView().frame(height: advanced ? 320 : 250)
            StatusBar(text: store.status, busy: store.isExporting || store.isBuilding,
                      trailing: "\(AppEnvironment.current.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
        }.background(Studio.base)
    }
    private var header: some View {
        AppHeader {
            Button(action: store.showHome) { Label("Home", systemImage: "house") }.buttonStyle(.quiet).accessibilityIdentifier("editor.home")
            if store.parkedSession != nil {
                Button(action: store.returnToClips) { Label("Back to my clips", systemImage: "chevron.left") }.buttonStyle(.secondary).accessibilityIdentifier("editor.backToClips")
            } else {
                Button { store.project.clipReview != nil ? store.continueClipping() : store.startClipping() } label: { Label("Clip a stream", systemImage: "scissors") }
                    .buttonStyle(.quiet).accessibilityIdentifier("editor.clipper")
            }
            Spacer()
            HStack(spacing: 6) {
                Text(store.project.name).accessibilityIdentifier("project.name").font(.system(size: 13, weight: .medium)).lineLimit(1)
                if store.dirty { Circle().fill(Studio.accent).frame(width: 6, height: 6).help("Unsaved changes") }
            }
            Spacer()
        } trailing: {
            Picker("Tools", selection: $advanced) { Text("Simple").tag(false); Text("Advanced").tag(true) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150).help("Advanced adds layers, AI, color and transform tools").accessibilityIdentifier("editor.mode")
            Button { store.save() } label: { Text("Save") }.buttonStyle(.secondary).help("Save project · ⌘S").accessibilityIdentifier("project.save")
            if store.isExporting { Button("Cancel") { store.exportTask?.cancel() }.buttonStyle(.quiet) }
            Button(action: store.exportVideo) {
                HStack(spacing: 7) {
                    if store.isExporting { ProgressView().controlSize(.small).tint(Studio.onAccent) } else { Image(systemName: "square.and.arrow.up") }
                    Text(store.isExporting ? "\(Int(store.exportProgress * 100))%" : "Export")
                }
            }.buttonStyle(.primary).accessibilityIdentifier("project.export").disabled(!store.canExport)
                .help(store.exportBlocker ?? "Export an MP4 · ⌘E")
        }
    }
    private var library: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $store.workspace) {
                ForEach(advanced ? ["Media", "Captions", "Layers", "AI"] : ["Media", "Captions"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            switch advanced ? store.workspace : (store.workspace == "Captions" ? "Captions" : "Media") {
            case "Captions": CaptionPanel()
            case "AI": AIPanel()
            case "Layers": LayersPanel()
            default: mediaLibrary
            }
        }.background(Studio.panel)
    }
    private var mediaLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: store.importMedia) {
                Label(store.isImporting ? "Importing…" : "Import videos", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.primary).accessibilityIdentifier("media.import").disabled(store.isImporting).padding(.horizontal, 14).padding(.top, 4)
            HStack { SectionLabel("Your videos"); Spacer(); Text("\(store.project.media.count)").font(.system(size: 11)).foregroundStyle(Studio.muted) }
                .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)
            if store.project.media.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 24)).foregroundStyle(Studio.accent)
                    Text("Drop videos here").font(.system(size: 13, weight: .medium))
                    Text("MP4, MOV, MKV or images").font(.system(size: 11)).foregroundStyle(Studio.muted)
                }.frame(maxWidth: .infinity).frame(height: 180).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))).padding(14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.project.media) { item in mediaRow(item) }
                    }.padding(.horizontal, 14).padding(.bottom, 14)
                }.accessibilityIdentifier("media.scroll")
            }
            Spacer(minLength: 0)
            Label("Your original files are never changed", systemImage: "lock.shield").font(.system(size: 10.5)).foregroundStyle(Studio.muted).padding(16)
        }.background(Studio.panel)
        .dropDestination(for: URL.self) { urls, _ in store.importURLs(urls); return true }
    }
    private func mediaRow(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail(item.id).frame(height: 132).clipped().contentShape(Rectangle()).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(timecode(item.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(6)
            }
            HStack {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button { store.add(item) } label: { Label("Add", systemImage: "plus") }.buttonStyle(.secondary).controlSize(.small).help("Add to the end of the timeline").accessibilityIdentifier("media.add.\(item.id)")
            }
        }.padding(8).background(Studio.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
        .contentShape(Rectangle()).onTapGesture(count: 2) { store.add(item) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("media.item.\(item.id)")
        .contextMenu {
            Button("Add to timeline") { store.add(item) }
            Button("Find moments for shorts") { store.clipRecording(item) }
            Button("Make captions") { store.transcriptionMediaID = item.id; store.workspace = "Captions" }
            Divider()
            Button("Add as facecam / overlay") { store.addOverlay(item) }.disabled(store.project.clips.isEmpty)
            Button("Relink source…") { store.relink(item) }
        }
    }
    private var preview: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack {
                    if store.project.clips.isEmpty { emptyPreview } else {
                        NativePlayer(player: store.player)
                            .aspectRatio(store.project.outputFormat.size.width / store.project.outputFormat.size.height, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if store.isBuilding { ProgressView("Preparing preview…").padding(18).background(Studio.raised, in: RoundedRectangle(cornerRadius: 10)) }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .background(store.project.clips.isEmpty ? Studio.base : Color.black).clipShape(RoundedRectangle(cornerRadius: 12))
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
            HStack(spacing: 18) {
                Text(timecode(store.playhead)).accessibilityIdentifier("player.time").foregroundStyle(Studio.text)
                Text("/ " + timecode(store.project.duration)).accessibilityIdentifier("project.duration").foregroundStyle(Studio.muted)
                Spacer()
                Button { store.seek(store.playhead - 5) } label: { Image(systemName: "gobackward.5") }.help("Back 5 seconds · ←")
                Button(action: store.togglePlayback) {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15)).foregroundStyle(Studio.onAccent).frame(width: 40, height: 34).background(Studio.accent, in: RoundedRectangle(cornerRadius: 9))
                }.help("Play / pause · Space").accessibilityIdentifier("player.play")
                Button { store.seek(store.playhead + 5) } label: { Image(systemName: "goforward.5") }.help("Forward 5 seconds · →")
                Spacer()
                Text("\(store.project.outputFormat.label) · \(store.project.options.fps) fps").font(.system(size: 10)).foregroundStyle(Studio.muted)
            }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Studio.text).buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 16)
        }
    }
    private var emptyPreview: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Studio.accent.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: store.project.media.isEmpty ? "film" : "plus.rectangle.on.rectangle").font(.system(size: 28)).foregroundStyle(Studio.accent)
            }
            Text(store.project.media.isEmpty ? "Start with a video" : "Put a video on the timeline").font(Studio.title(26))
            Text(store.project.media.isEmpty ? "Import a recording, then trim, split and caption it." : "Click Add on any of your videos on the left.").font(.system(size: 13)).foregroundStyle(Studio.muted)
            if store.project.media.isEmpty {
                Button { store.importMedia() } label: { Label("Import a video", systemImage: "plus") }.buttonStyle(.primaryLarge).accessibilityIdentifier("preview.import")
            } else if let first = store.project.media.first, store.project.media.count == 1 {
                Button { store.add(first) } label: { Label("Add \(first.name)", systemImage: "plus") }.buttonStyle(.primaryLarge)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func thumbnail(_ id: UUID) -> some View {
        if let image = store.thumbnails[id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        else { Rectangle().fill(Studio.well).overlay(Image(systemName: "film").foregroundStyle(Studio.muted)) }
    }
}

extension EditorStore {
    /// Why Export is unavailable, in plain words. Nil when it's ready.
    var exportBlocker: String? {
        if project.clips.isEmpty { return "Add a video to the timeline first." }
        if project.workflow == nil { return "Choose a format (Short or YouTube) on the right." }
        do { try validateExport(project) } catch { return error.localizedDescription }
        return nil
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
            Button { withAnimation(.easeOut(duration: 0.15)) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.muted).frame(width: 10).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
