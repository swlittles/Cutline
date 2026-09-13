import SwiftUI
import AVFoundation
import CutlineCore

struct CaptionPanel: View {
    @EnvironmentObject var store: EditorStore
    @State private var search = ""
    @State private var trackCount = 1
    @State private var showSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Auto captions", systemImage: "captions.bubble").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("ON DEVICE").font(.system(size: 8, weight: .bold)).foregroundStyle(Studio.mint)
                }
                Text("Turn your commentary into editable captions. Your audio stays on this Mac.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Picker("Recording", selection: Binding(get: { store.transcriptionMedia?.id }, set: { store.transcriptionMediaID = $0 })) {
                    ForEach(store.project.media) { Text($0.name).tag(Optional($0.id)) }
                }.font(.system(size: 11))
                Picker("Speech track", selection: $store.transcriptionAudioTrack) {
                    ForEach(0..<max(1, trackCount), id: \.self) { Text("Audio \($0 + 1)").tag($0) }
                }.font(.system(size: 11)).accessibilityIdentifier("captions.audio-track")
                Text("Choose your microphone track for OBS recordings with separate audio.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                DisclosureGroup("Speech model & language", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Model", selection: $store.speechModel) { ForEach(WhisperModel.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                        if store.speechModel.installed { Label("Model ready for offline use", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Studio.mint) }
                        else {
                            Button(store.isDownloadingModel ? "Downloading & verifying…" : "Download model", action: store.downloadSpeechModel).disabled(store.isDownloadingModel)
                        }
                        if store.isDownloadingModel { ProgressView(); Button("Cancel download") { store.downloadTask?.cancel() } }
                        Picker("Language", selection: $store.transcriptionLanguage) {
                            Text("Detect automatically").tag("auto"); Text("English").tag("en"); Text("Spanish").tag("es"); Text("French").tag("fr"); Text("German").tag("de"); Text("Portuguese").tag("pt"); Text("Japanese").tag("ja"); Text("Korean").tag("ko"); Text("Chinese").tag("zh")
                        }.disabled(store.speechModel != .base)
                        TextField("Game names, players, specialist words", text: $store.transcriptionVocabulary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                        if LocalTools.executable("whisper-cli") == nil || LocalTools.executable("ffmpeg") == nil { Text("Install local engines with scripts/setup-local-ai.sh.").foregroundStyle(.orange) }
                    }.font(.system(size: 10)).padding(.top, 8)
                }.font(.system(size: 11))
                if !store.speechModel.installed && !showSetup { Button("Download speech model", action: store.downloadSpeechModel).disabled(store.isDownloadingModel) }
                Button(action: store.transcribe) {
                    Label(store.isTranscribing ? "Transcribing…" : "Generate captions", systemImage: "waveform.badge.mic").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.accessibilityIdentifier("captions.generate").buttonStyle(.borderedProminent).disabled(store.transcriptionMedia == nil || !store.speechModel.installed || store.isTranscribing || trackCount == 0)
                if store.isTranscribing {
                    ProgressView(value: store.transcriptionProgress)
                    Text(store.transcriptionMessage).font(.system(size: 10)).foregroundStyle(Studio.muted)
                    Button("Cancel transcription") { store.transcriptionTask?.cancel() }.font(.system(size: 10))
                }
                Divider()
                SpeechGapEditor()
                CaptionStyleEditor()
                HStack {
                    Button("Import…", action: store.importSubtitles)
                    Menu("Export") { Button("SubRip (.srt)") { store.exportSubtitles(vtt: false) }; Button("WebVTT (.vtt)") { store.exportSubtitles(vtt: true) } }.disabled(store.visibleCaptions.isEmpty).accessibilityIdentifier("captions.export")
                    Spacer()
                    Button(action: store.addCaption) { Image(systemName: "plus") }.help("Add caption at playhead")
                }.font(.system(size: 10))
                TextField("Search the transcript", text: $search).textFieldStyle(.roundedBorder)
                let captions = store.visibleCaptions.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
                Text("\(captions.count) CAPTIONS").accessibilityIdentifier("captions.count").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(Studio.muted)
                LazyVStack(spacing: 10) {
                    ForEach(captions) { cue in CaptionEditorRow(cue: cue) }
                }
                if captions.isEmpty { Text("Generate captions, import an SRT/VTT file, or add a caption at the playhead.").font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.vertical, 20) }
            }.padding(16)
        }
        .accessibilityIdentifier("captions.scroll")
        .task(id: store.transcriptionMedia?.id) {
            guard let media = store.transcriptionMedia else { trackCount = 0; return }
            trackCount = (try? await AVURLAsset(url: media.url).loadTracks(withMediaType: .audio).count) ?? 0
            store.transcriptionAudioTrack = min(store.transcriptionAudioTrack, max(0, trackCount - 1))
        }
    }
}

private struct CaptionStyleEditor: View {
    @EnvironmentObject var store: EditorStore
    @State private var fontSize = 52.0
    @State private var bottom = 0.12
    private var style: CaptionStyle { store.project.captionTrack?.style ?? CaptionStyle() }
    var body: some View {
        DisclosureGroup("Caption appearance") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Burn captions into video", isOn: Binding(get: { store.project.options.burnCaptions }, set: { value in store.commit { $0.options.burnCaptions = value } }))
                Text("Font size · \(Int(fontSize))")
                Slider(value: $fontSize, in: 16...100, onEditingChanged: { if !$0 { change { $0.fontSize = fontSize } } })
                Text("Position · \(Int(bottom * 100))% from bottom")
                Slider(value: $bottom, in: 0.03...0.8, onEditingChanged: { if !$0 { change { $0.bottom = bottom } } })
                Toggle("Uppercase", isOn: Binding(get: { style.uppercase }, set: { v in change { $0.uppercase = v } }))
                Toggle("Background box", isOn: Binding(get: { style.background }, set: { v in change { $0.background = v } }))
                HStack {
                    ForEach(["FFFFFF", "A0F2BE", "FFE45C", "FF8BB8"], id: \.self) { hex in
                        Button { change { $0.colorHex = hex } } label: { Circle().fill(color(hex)).frame(width: 20, height: 20).overlay(Circle().stroke(style.colorHex == hex ? Color.white : .clear, lineWidth: 2).padding(-3)) }.buttonStyle(.plain).accessibilityIdentifier("caption.color.\(hex)")
                    }
                }
            }.font(.system(size: 11)).padding(.top, 10)
        }.font(.system(size: 11))
        .onAppear { fontSize = style.fontSize; bottom = style.bottom }
        .onChange(of: style) { _, value in fontSize = value.fontSize; bottom = value.bottom }
    }
    private func change(_ update: (inout CaptionStyle) -> Void) {
        var next = style; update(&next)
        store.commit { if $0.captionTrack == nil { $0.captionTrack = CaptionTrack() }; $0.captionTrack?.style = next }
    }
    private func color(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0xffffff
        return Color(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct CaptionEditorRow: View {
    @EnvironmentObject var store: EditorStore
    let cue: ProjectedCaption
    @State private var text = ""
    @State private var start = 0.0
    @State private var end = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { store.seek(cue.start) } label: { Text(timecode(cue.start)).monospacedDigit() }.buttonStyle(.plain).foregroundStyle(Studio.mint)
                Spacer()
                Button { store.commit { $0.captionTrack?.cues.removeAll { $0.id == cue.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityIdentifier("caption.delete.\(cue.id)").foregroundStyle(Studio.muted)
            }.font(.system(size: 10))
            TextField("Caption", text: $text, axis: .vertical).accessibilityIdentifier("caption.text.\(cue.id)").textFieldStyle(.plain).lineLimit(1...5).font(.system(size: 12))
            HStack(spacing: 6) {
                TextField("Start", value: $start, format: .number.precision(.fractionLength(2))).frame(maxWidth: .infinity)
                Text("→")
                TextField("End", value: $end, format: .number.precision(.fractionLength(2))).frame(maxWidth: .infinity)
                Button("Apply") { store.editCaption(cue.id, text: text, start: start, end: end) }.accessibilityIdentifier("caption.apply.\(cue.id)").disabled(text == cue.text && start == cue.start && end == cue.end)
            }.textFieldStyle(.roundedBorder).font(.system(size: 9))
            Button("Cut this range from video") { store.cutRanges([TimelineRange(start: cue.start, end: cue.end)]) }.font(.system(size: 9)).foregroundStyle(Studio.muted)
        }.padding(11).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
            .onAppear { sync() }.onChange(of: cue) { _, _ in sync() }
    }
    private func sync() { text = cue.text; start = cue.start; end = cue.end }
}

private struct SpeechGapEditor: View {
    @EnvironmentObject var store: EditorStore
    @State private var minimum = 1.0
    @State private var gaps: [TimelineRange] = []
    @State private var selected = Set<String>()
    @State private var snapshot: EditProject?
    var body: some View {
        DisclosureGroup("Edit video through the transcript") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review pauses between captions, then ripple-cut the selected ranges from every track. Uncaptioned gameplay can still be important.").foregroundStyle(Studio.muted)
                Stepper("Minimum gap: \(String(format: "%.1f", minimum))s", value: $minimum, in: 0.5...10, step: 0.5)
                Button("Find gaps") { gaps = store.project.speechGaps(minimum: minimum); selected = Set(gaps.map(\.id)); snapshot = store.project }
                ForEach(gaps) { gap in
                    HStack {
                        Toggle("\(timecode(gap.start)) – \(timecode(gap.end))", isOn: Binding(get: { selected.contains(gap.id) }, set: { if $0 { selected.insert(gap.id) } else { selected.remove(gap.id) } }))
                        Button("Preview") { store.seek(gap.start); if !store.isPlaying { store.togglePlayback() } }
                    }
                }
                if snapshot != nil {
                    Text("\(selected.count) gaps · \(String(format: "%.1f", gaps.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.duration })) seconds selected").foregroundStyle(Studio.muted)
                    Button("Cut selected gaps") {
                        guard snapshot == store.project else { store.error = "The timeline changed. Find gaps again before cutting."; return }
                        store.cutRanges(gaps.filter { selected.contains($0.id) }); gaps = []; selected = []; snapshot = nil
                    }.disabled(selected.isEmpty)
                }
            }.font(.system(size: 10)).padding(.top, 10)
        }.font(.system(size: 11))
    }
}
