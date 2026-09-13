import SwiftUI
import CutlineCore

struct TimelineView: View {
    @EnvironmentObject var store: EditorStore
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Timeline").font(.system(size: 12, weight: .semibold))
                Rectangle().fill(Studio.line).frame(width: 1, height: 17)
                tool("scissors", "Split at playhead · ⌘B", store.split).disabled(store.project.clips.isEmpty)
                tool("plus.square.on.square", "Duplicate clip · ⌘D", store.duplicate).disabled(store.selectedClip == nil)
                tool("trash", "Delete clip", store.deleteSelected).disabled(store.selectedClip == nil)
                Rectangle().fill(Studio.line).frame(width: 1, height: 17)
                tool("arrow.uturn.backward", "Undo · ⌘Z", store.undo).disabled(store.undoStack.isEmpty)
                tool("arrow.uturn.forward", "Redo · ⇧⌘Z", store.redo).disabled(store.redoStack.isEmpty)
                Spacer()
                Text("\(store.project.clips.count) clips").accessibilityIdentifier("timeline.count").font(.system(size: 10)).foregroundStyle(Studio.muted)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Studio.muted)
                Slider(value: $zoom, in: 1...20).frame(width: 100).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Studio.muted)
                Button("Fit") { zoom = 1 }.font(.system(size: 10)).buttonStyle(.plain)
            }.padding(.horizontal, 18).frame(height: 46)
            Rectangle().fill(Studio.line).frame(height: 1)
            GeometryReader { geometry in
                let total = store.project.clips.isEmpty ? 30 : max(store.project.duration, 1)
                let width = max(100, geometry.size.width - 120) * zoom
                let scale = width / total
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TRACKS").font(.system(size: 8)).tracking(1.2).foregroundStyle(Studio.muted).frame(height: 32)
                        Label("Video", systemImage: "film").font(.system(size: 11, weight: .medium)).frame(height: 69)
                        Label("Clip audio", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 49)
                        Label("Captions", systemImage: "captions.bubble").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34)
                        Label("Overlays", systemImage: "square.on.square").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34)
                        Label("Music", systemImage: "music.note").font(.system(size: 10)).foregroundStyle(Studio.muted).frame(height: 34)
                        Spacer()
                    }.padding(.leading, 18).frame(width: 120, alignment: .leading)
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ruler(width: width, total: total)
                                    .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { store.seek($0.location.x / scale) })
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.white.opacity(0.015))
                                    if store.project.clips.isEmpty {
                                        HStack(spacing: 9) {
                                            Image(systemName: "plus.rectangle.on.rectangle")
                                            Text("Add a recording from your media library to start editing")
                                        }.font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.leading, 30)
                                    }
                                    HStack(spacing: 0) {
                                        ForEach(store.project.clips) { clip in clipBlock(clip, width: max(1, clip.duration * scale)) }
                                    }
                                }.frame(height: 69)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Studio.mint.opacity(0.018))
                                    HStack(spacing: 0) {
                                        ForEach(store.project.clips) { clip in
                                            HStack(spacing: 5) {
                                                Image(systemName: clip.volume == 0 ? "speaker.slash" : "waveform")
                                                if clip.duration * scale > 90 { Text(clip.volume == 0 ? "Muted" : "Source audio") }
                                            }.font(.system(size: 9)).foregroundStyle(Studio.mint.opacity(clip.volume == 0 ? 0.25 : 0.65))
                                                .frame(width: max(1, clip.duration * scale - 2), height: 30)
                                                .background(Studio.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 4)).clipped().padding(.trailing, 2)
                                        }
                                    }
                                }.frame(height: 49)
                                ZStack(alignment: .leading) {
                                    Color.clear
                                    ForEach(store.visibleCaptions) { cue in
                                        Text(cue.text).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 4)
                                            .frame(width: max(1, (cue.end - cue.start) * scale), height: 24)
                                            .background(Color.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 4)).clipped()
                                            .offset(x: cue.start * scale).onTapGesture { store.seek(cue.start); store.workspace = "Captions" }
                                    }
                                }.frame(height: 34)
                                ZStack(alignment: .leading) {
                                    Color.clear
                                    ForEach(store.project.overlays ?? []) { overlay in
                                        Text("Overlay").font(.system(size: 9)).lineLimit(1).frame(width: max(1, min(overlay.duration, max(0, store.project.duration - overlay.start)) * scale), height: 24)
                                            .background(Color.purple.opacity(0.25), in: RoundedRectangle(cornerRadius: 4)).clipped().offset(x: overlay.start * scale)
                                            .onTapGesture { store.workspace = "Layers" }
                                    }
                                }.frame(height: 34)
                                ZStack(alignment: .leading) {
                                    Color.clear
                                    ForEach(store.project.music ?? []) { audio in
                                        Text(audio.url.deletingPathExtension().lastPathComponent).font(.system(size: 9)).lineLimit(1).frame(width: max(1, min(audio.duration, max(0, store.project.duration - audio.start)) * scale), height: 24)
                                            .background(Color.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 4)).clipped().offset(x: audio.start * scale)
                                            .onTapGesture { store.workspace = "Layers" }
                                    }
                                }.frame(height: 34)
                                Spacer(minLength: 8)
                            }
                            Rectangle().fill(Studio.mint).frame(width: 1, height: 264).offset(x: store.playhead * scale).allowsHitTesting(false)
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(Studio.mint).offset(x: store.playhead * scale - 4, y: 0).allowsHitTesting(false)
                        }.frame(width: width, height: 282)
                    }
                }
            }
        }.background(Studio.panel).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
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
            RoundedRectangle(cornerRadius: 5).fill(Studio.raised)
            if let image = store.thumbnails[clip.mediaID] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: width, height: 59).clipped().opacity(0.45)
            }
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .top)
            if width > 35 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(media?.name ?? "Missing media").font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text(timecode(clip.duration)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                }.padding(.horizontal, 10)
            }
        }.frame(width: max(1, width - 2), height: 59).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(store.selectedClipID == clip.id ? Studio.mint : .white.opacity(0.12), lineWidth: store.selectedClipID == clip.id ? 2 : 1))
            .overlay(alignment: .leading) {
                if store.selectedClipID == clip.id {
                    Rectangle().fill(Studio.mint).frame(width: 6).contentShape(Rectangle())
                        .help("Drag to trim the start")
                        .highPriorityGesture(DragGesture(minimumDistance: 3).onEnded { value in
                            store.updateClip(clip.id, sourceIn: clip.sourceIn + value.translation.width / max(1, width) * clip.duration * clip.speed)
                        })
                }
            }
            .overlay(alignment: .trailing) {
                if store.selectedClipID == clip.id {
                    Rectangle().fill(Studio.mint).frame(width: 6).contentShape(Rectangle())
                        .help("Drag to trim the end")
                        .highPriorityGesture(DragGesture(minimumDistance: 3).onEnded { value in
                            store.updateClip(clip.id, sourceOut: clip.sourceOut + value.translation.width / max(1, width) * clip.duration * clip.speed)
                        })
                }
            }
            .padding(.trailing, 2).contentShape(Rectangle()).onTapGesture { store.select(clip) }.accessibilityElement(children: .combine).accessibilityIdentifier("clip.\(clip.id)")
            .draggable(clip.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                store.moveClip(id, before: clip.id); return true
            }
            .contextMenu {
                Button("Select") { store.select(clip) }
                Button("Duplicate") { store.selectedClipID = clip.id; store.duplicate() }
                Button("Remove") { store.selectedClipID = clip.id; store.deleteSelected() }
            }
    }
}
