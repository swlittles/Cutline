import SwiftUI
import CutlineCore

struct LayersPanel: View {
    @EnvironmentObject var store: EditorStore
    @State private var mediaID: UUID?
    @State private var voiceText = ""
    @State private var makingVoice = false
    @State private var voiceTask: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Layers & highlights", systemImage: "square.3.layers.3d").font(.system(size: 14, weight: .semibold))
                Text("Add a facecam, background music, or voiceover. Layers use absolute timeline positions.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Picker("Overlay source", selection: $mediaID) {
                    Text("Choose recording").tag(Optional<UUID>.none)
                    ForEach(store.project.media) { Text($0.name).tag(Optional($0.id)) }
                }.font(.system(size: 11)).accessibilityIdentifier("overlay.source")
                Button("Add video overlay at playhead") { if let media = store.project.media.first(where: { $0.id == mediaID }) { store.addOverlay(media) } }.disabled(mediaID == nil || store.project.clips.isEmpty)
                ForEach(store.project.overlays ?? []) { overlay in OverlayEditor(overlay: overlay) }
                Divider()
                Button(action: store.addAudio) { Label("Add music / audio…", systemImage: "music.note") }.disabled(store.project.clips.isEmpty)
                ForEach(store.project.music ?? []) { audio in AudioLayerEditor(audio: audio) }
                DisclosureGroup("Local text to speech") {
                    VStack(alignment: .leading, spacing: 9) {
                        TextField("Write your voiceover", text: $voiceText, axis: .vertical).accessibilityIdentifier("voiceover.text").lineLimit(3...8).textFieldStyle(.roundedBorder)
                        Text("Uses your Mac’s default speech voice. Audio is generated locally and added at the playhead.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                        Button(makingVoice ? "Generating…" : "Generate voiceover") { generateVoiceover() }.disabled(makingVoice || voiceText.isEmpty || store.project.clips.isEmpty)
                        if makingVoice { Button("Cancel") { voiceTask?.cancel() } }
                    }.padding(.top, 8)
                }.font(.system(size: 11))
                Divider()
                HStack { Text("Highlights").font(.system(size: 12, weight: .medium)); Spacer(); Button("Mark here", action: store.addMarker).disabled(store.project.clips.isEmpty) }.font(.system(size: 10))
                ForEach(store.project.markers ?? []) { marker in
                    if let clip = store.project.clips.first(where: { $0.id == marker.clipID }), marker.sourceTime >= clip.sourceIn, marker.sourceTime < clip.sourceOut {
                        let time = store.project.start(of: clip.id) + (marker.sourceTime - clip.sourceIn) / clip.speed
                        HStack {
                            Button { store.seek(time) } label: { Label(marker.label + " · " + timecode(time), systemImage: "bookmark.fill").lineLimit(1) }.buttonStyle(.plain).foregroundStyle(Studio.mint)
                            Spacer()
                            Button { store.commit { $0.markers?.removeAll { $0.id == marker.id } } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.font(.system(size: 11)).padding(9).background(Studio.raised, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }.padding(16)
        }.accessibilityIdentifier("layers.scroll")
    }
    private func generateVoiceover() {
        let text = voiceText, epoch = store.projectEpoch
        makingVoice = true
        voiceTask = Task {
            let id = UUID().uuidString
            let input = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-voice-\(id).txt")
            let output = LocalTools.support.appendingPathComponent("Voiceovers/\(id).aiff")
            defer { try? FileManager.default.removeItem(at: input); makingVoice = false }
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: input, atomically: true, encoding: .utf8)
                _ = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/say"), ["-o", output.path, "-f", input.path])
                guard store.projectEpoch == epoch else { return }
                store.insertAudio(output)
            } catch { try? FileManager.default.removeItem(at: output); if !Task.isCancelled { store.error = error.localizedDescription } }
        }
    }
}

private struct OverlayEditor: View {
    @EnvironmentObject var store: EditorStore
    let overlay: OverlayClip
    @State private var draft: OverlayClip
    init(overlay: OverlayClip) { self.overlay = overlay; _draft = State(initialValue: overlay) }
    var body: some View {
        DisclosureGroup(store.project.media.first { $0.id == overlay.mediaID }?.name ?? "Overlay") {
            VStack(spacing: 10) {
                number("Timeline start", $draft.start); number("Source in", $draft.sourceIn); number("Duration", $draft.duration)
                Text("Horizontal position"); Slider(value: $draft.x, in: 0...0.95)
                Text("From top"); Slider(value: $draft.y, in: 0...0.95)
                Text("Width"); Slider(value: $draft.width, in: 0.05...1)
                Text("Opacity"); Slider(value: $draft.opacity, in: 0...1).accessibilityIdentifier("overlay.opacity")
                HStack {
                    Button("Apply") {
                        var next = store.project
                        guard let index = next.overlays?.firstIndex(where: { $0.id == overlay.id }) else { return }
                        next.overlays?[index] = draft
                        do { try next.validate(); store.commit { $0 = next } } catch { store.error = error.localizedDescription }
                    }
                    Button("Remove") { store.commit { $0.overlays?.removeAll { $0.id == overlay.id } } }
                }
            }.padding(.top, 10)
        }.font(.system(size: 11)).padding(10).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
            .onChange(of: overlay) { _, value in draft = value }
    }
    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder) }
    }
}

private struct AudioLayerEditor: View {
    @EnvironmentObject var store: EditorStore
    let audio: AudioClip
    @State private var draft: AudioClip
    init(audio: AudioClip) { self.audio = audio; _draft = State(initialValue: audio) }
    var body: some View {
        DisclosureGroup(audio.url.deletingPathExtension().lastPathComponent) {
            VStack(spacing: 10) {
                number("Timeline start", $draft.start); number("Source in", $draft.sourceIn); number("Duration", $draft.duration)
                Text("Volume · \(Int(draft.volume * 100))%"); Slider(value: $draft.volume, in: 0...2)
                number("Fade in", $draft.fadeIn); number("Fade out", $draft.fadeOut)
                HStack {
                    Button("Apply") {
                        var next = store.project
                        guard let index = next.music?.firstIndex(where: { $0.id == audio.id }) else { return }
                        next.music?[index] = draft
                        do { try next.validate(); store.commit { $0 = next } } catch { store.error = error.localizedDescription }
                    }
                    Button("Remove") { store.commit { $0.music?.removeAll { $0.id == audio.id } } }
                }
            }.padding(.top, 10)
        }.font(.system(size: 11)).padding(10).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
            .onChange(of: audio) { _, value in draft = value }
    }
    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number.precision(.fractionLength(2))).frame(width: 70).textFieldStyle(.roundedBorder) }
    }
}
