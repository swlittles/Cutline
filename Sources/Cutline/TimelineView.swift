import SwiftUI
import CutlineCore

struct TimelineView: View {
    @EnvironmentObject var store: EditorStore
    @AppStorage("editor-advanced") private var advanced = false
    @State private var zoom = 1.0
    @FocusState private var hasKeyboardFocus: Bool
    private var showCaptions: Bool { advanced || !store.visibleCaptions.isEmpty }
    private var showOverlays: Bool { advanced || !(store.project.overlays ?? []).isEmpty }
    private var showMusic: Bool { advanced || !(store.project.music ?? []).isEmpty }
    private var rowsHeight: CGFloat { 32 + 69 + 49 + (showCaptions ? 34 : 0) + (showOverlays ? 34 : 0) + (showMusic ? 34 : 0) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Timeline").font(.system(size: 12, weight: .semibold))
                Rectangle().fill(Studio.line).frame(width: 1, height: 17)
                tool("scissors", "Split at playhead · ⌘B", store.split).disabled(store.project.clips.isEmpty)
                tool("plus.square.on.square", "Duplicate clip · ⌘D", store.duplicate).disabled(store.selectedClip == nil)
                tool("trash", "Remove clip · Delete", store.deleteSelected).disabled(store.selectedClip == nil)
                Rectangle().fill(Studio.line).frame(width: 1, height: 17)
                tool("arrow.uturn.backward", "Undo · ⌘Z", store.undo).disabled(store.undoStack.isEmpty)
                tool("arrow.uturn.forward", "Redo · ⇧⌘Z", store.redo).disabled(store.redoStack.isEmpty)
                Spacer()
                Text("\(store.project.clips.count) clips").accessibilityIdentifier("timeline.count").font(.system(size: 10)).foregroundStyle(Studio.muted)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Studio.muted)
                Slider(value: $zoom, in: 1...20).frame(width: 100).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Studio.muted)
                Button("Fit") { zoom = 1 }.buttonStyle(.quiet).font(.system(size: 10))
            }.padding(.horizontal, 18).frame(height: 44)
            Rectangle().fill(Studio.line).frame(height: 1)
            GeometryReader { geometry in
                let total = store.project.clips.isEmpty ? 30 : max(store.project.duration, 1)
                let width = max(100, geometry.size.width - 120) * zoom
                HStack(spacing: 0) {
                    trackLabels.padding(.leading, 18).frame(width: 120, alignment: .leading)
                    ScrollView(.horizontal) { lanes(width: width, scale: width / total, total: total) }
                }
            }
        }
        // Delete belongs to the focused timeline. A global menu key equivalent can
        // steal it from SwiftUI text fields before their native editor receives it.
        .focusable().focused($hasKeyboardFocus)
        .onDeleteCommand { store.deleteFromKeyboard() }
        .background(Studio.panel).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
    private var trackLabels: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Tracks").frame(height: 32)
            Label("Video", systemImage: "film").font(.system(size: 11, weight: .medium)).frame(height: 69)
            Label("Sound", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 49)
            if showCaptions { Label("Captions", systemImage: "captions.bubble").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34) }
            if showOverlays { Label("Overlays", systemImage: "square.on.square").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34) }
            if showMusic { Label("Music", systemImage: "music.note").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34) }
            Spacer()
        }
    }
    private func lanes(width: CGFloat, scale: Double, total: Double) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler(width: width, total: total)
                    .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { store.seek($0.location.x / scale) })
                videoLane(scale: scale).frame(height: 69)
                soundLane(scale: scale).frame(height: 49)
                if showCaptions { CaptionLane(scale: scale).frame(height: 34) }
                if showOverlays { OverlayLane(scale: scale).frame(height: 34) }
                if showMusic { MusicLane(scale: scale).frame(height: 34) }
                Spacer(minLength: 8)
            }
            Rectangle().fill(Studio.accent).frame(width: 1.5, height: rowsHeight).offset(x: store.playhead * scale).allowsHitTesting(false)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(Studio.accent).offset(x: store.playhead * scale - 5, y: 0).allowsHitTesting(false)
        }.frame(width: width, height: rowsHeight + 18)
    }
    private func videoLane(scale: Double) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Studio.text.opacity(0.02))
            if store.project.clips.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Click Add on a video to put it here")
                }.font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.leading, 30)
            }
            HStack(spacing: 0) {
                ForEach(store.project.clips) { clip in clipBlock(clip, width: max(1, clip.duration * scale)) }
            }
        }
    }
    private func soundLane(scale: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(store.project.clips) { clip in
                let width = clip.duration * scale
                HStack(spacing: 5) {
                    Image(systemName: clip.volume == 0 ? "speaker.slash" : "waveform")
                    if width > 90 { Text(clip.volume == 0 ? "Muted" : "Sound") }
                }.font(.system(size: 9)).foregroundStyle(Studio.accent.opacity(clip.volume == 0 ? 0.35 : 0.85))
                    .frame(width: max(1, width - 2), height: 30)
                    .background(Studio.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5)).clipped().padding(.trailing, 2)
            }
            Spacer(minLength: 0)
        }
    }
    private func tool(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).frame(width: 18, height: 24) }.buttonStyle(.plain).help(help).accessibilityIdentifier("timeline.\(icon)")
    }
    private func ruler(width: CGFloat, total: Double) -> some View {
        let divisions = max(8, Int(8 * zoom))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(0..<divisions, id: \.self) { index in
                VStack(alignment: .leading, spacing: 5) {
                    Text(timecode(total * Double(index) / Double(divisions))).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted)
                    Rectangle().fill(Studio.line).frame(width: 1, height: 6)
                }.offset(x: width * Double(index) / Double(divisions) + 4, y: 7)
            }
        }.frame(height: 32)
    }
    private func clipBlock(_ clip: TimelineClip, width: CGFloat) -> some View {
        let media = store.project.media.first { $0.id == clip.mediaID }
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7).fill(Studio.raised)
            if let image = store.thumbnails[clip.mediaID] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: width, height: 59).clipped().opacity(0.6)
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .top)
            if width > 35 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(media?.name ?? "Missing video").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text(timecode(clip.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                }.padding(.horizontal, 10)
            }
        }.frame(width: max(1, width - 2), height: 59).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(store.selectedClipID == clip.id ? Studio.accent : Studio.line, lineWidth: store.selectedClipID == clip.id ? 2 : 1))
            .overlay(alignment: .leading) {
                if store.selectedClipID == clip.id {
                    RoundedRectangle(cornerRadius: 3).fill(Studio.accent).frame(width: 7).contentShape(Rectangle())
                        .help("Drag to trim the start")
                        .highPriorityGesture(DragGesture(minimumDistance: 3).onEnded { value in
                            store.updateClip(clip.id, sourceIn: clip.sourceIn + value.translation.width / max(1, width) * clip.duration * clip.speed)
                        })
                }
            }
            .overlay(alignment: .trailing) {
                if store.selectedClipID == clip.id {
                    RoundedRectangle(cornerRadius: 3).fill(Studio.accent).frame(width: 7).contentShape(Rectangle())
                        .help("Drag to trim the end")
                        .highPriorityGesture(DragGesture(minimumDistance: 3).onEnded { value in
                            store.updateClip(clip.id, sourceOut: clip.sourceOut + value.translation.width / max(1, width) * clip.duration * clip.speed)
                        })
                }
            }
            .padding(.trailing, 2).contentShape(Rectangle()).onTapGesture { hasKeyboardFocus = true; store.select(clip) }.accessibilityElement(children: .combine).accessibilityIdentifier("clip.\(clip.id)")
            .draggable(clip.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                store.moveClip(id, before: clip.id); return true
            }
            .contextMenu {
                Button("Select") { hasKeyboardFocus = true; store.select(clip) }
                Button("Duplicate") { store.selectedClipID = clip.id; store.duplicate() }
                Button("Remove") { store.selectedClipID = clip.id; store.deleteSelected() }
            }
    }
}

private struct CaptionLane: View {
    @EnvironmentObject var store: EditorStore
    let scale: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(store.visibleCaptions) { cue in CaptionChip(cue: cue, scale: scale) }
        }
    }
}

private struct CaptionChip: View {
    @EnvironmentObject var store: EditorStore
    let cue: ProjectedCaption
    let scale: Double
    var body: some View {
        let width: CGFloat = max(1, (cue.end - cue.start) * scale)
        Text(cue.text).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 4)
            .frame(width: width, height: 24)
            .background(Studio.warning.opacity(0.22), in: RoundedRectangle(cornerRadius: 5)).clipped()
            .offset(x: cue.start * scale)
            .onTapGesture { store.seek(cue.start); store.workspace = "Captions" }
    }
}

private struct OverlayLane: View {
    @EnvironmentObject var store: EditorStore
    let scale: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(store.project.overlays ?? []) { overlay in
                let length: Double = min(overlay.duration, max(0, store.project.duration - overlay.start))
                Text("Overlay").font(.system(size: 9)).lineLimit(1).frame(width: max(1, length * scale), height: 24)
                    .background(Studio.series.opacity(0.25), in: RoundedRectangle(cornerRadius: 5)).clipped().offset(x: overlay.start * scale)
                    .onTapGesture { store.workspace = "Layers" }
            }
        }
    }
}

private struct MusicLane: View {
    @EnvironmentObject var store: EditorStore
    let scale: Double
    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(store.project.music ?? []) { audio in
                let length: Double = min(audio.duration, max(0, store.project.duration - audio.start))
                Text(audio.url.deletingPathExtension().lastPathComponent).font(.system(size: 9)).lineLimit(1).frame(width: max(1, length * scale), height: 24)
                    .background(Studio.success.opacity(0.22), in: RoundedRectangle(cornerRadius: 5)).clipped().offset(x: audio.start * scale)
                    .onTapGesture { store.workspace = "Layers" }
            }
        }
    }
}
