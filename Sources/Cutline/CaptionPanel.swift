import SwiftUI
import AVFoundation
import CutlineCore

struct CaptionPanel: View {
    @EnvironmentObject var store: EditorStore
    @AppStorage("editor-advanced") private var advanced = false
    @State private var search = ""
    @State private var trackCount = 1
    @State private var showSetup = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Captions", systemImage: "captions.bubble").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("ON THIS MAC").font(.system(size: 8, weight: .bold)).tracking(0.8).foregroundStyle(Studio.accent)
                }
                Text("Turn what you say into captions you can edit. Your audio never leaves this Mac.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                if store.project.media.count > 1 {
                    Picker("Video", selection: Binding(get: { store.transcriptionMedia?.id }, set: { store.transcriptionMediaID = $0 })) {
                        ForEach(store.project.media) { Text($0.name).tag(Optional($0.id)) }
                    }.font(.system(size: 11))
                }
                if trackCount > 1 {
                    Picker("Your voice is on", selection: $store.transcriptionAudioTrack) {
                        ForEach(0..<max(1, trackCount), id: \.self) { Text("Track \($0 + 1)").tag($0) }
                    }.font(.system(size: 11)).accessibilityIdentifier("captions.audio-track")
                    Text("OBS recordings can have separate tracks. Pick the one with your microphone.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
                if store.captionEngine == .whisper || store.captionEngine == .whisperNeedsModel || advanced {
                    DisclosureGroup("Speech model & language", isExpanded: $showSetup) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Model", selection: $store.speechModel) { ForEach(WhisperModel.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                            if store.speechModel.installed { Label("Model ready for offline use", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(Studio.success) }
                            else {
                                Button(store.isDownloadingModel ? "Downloading & verifying…" : "Download model", action: store.downloadSpeechModel).buttonStyle(.secondary).disabled(store.isDownloadingModel)
                            }
                            if store.isDownloadingModel { ProgressView(); Button("Cancel download") { store.downloadTask?.cancel() }.buttonStyle(.quiet) }
                            Picker("Language", selection: $store.transcriptionLanguage) {
                                Text("Detect automatically").tag("auto"); Text("English").tag("en"); Text("Spanish").tag("es"); Text("French").tag("fr"); Text("German").tag("de"); Text("Portuguese").tag("pt"); Text("Japanese").tag("ja"); Text("Korean").tag("ko")
                            }.disabled(store.speechModel != .base)
                            TextField("Game names, players, specialist words", text: $store.transcriptionVocabulary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                            if store.captionEngine == .apple { Text("Without a downloaded model, Cutline uses macOS speech recognition.").foregroundStyle(Studio.muted) }
                        }.font(.system(size: 10)).padding(.top, 8)
                    }.font(.system(size: 11))
                }
                if store.captionEngine == .unavailable {
                    Text("Captions need macOS speech recognition. Turn on Dictation in System Settings → Keyboard, then come back.").font(.system(size: 11)).foregroundStyle(Studio.warning)
                }
                if store.captionEngine == .whisperNeedsModel && !showSetup {
                    Button("Download speech model (148 MB)", action: store.downloadSpeechModel).buttonStyle(.secondary).disabled(store.isDownloadingModel)
                }
                Button(action: store.transcribe) {
                    Label(store.isTranscribing ? "Making captions…" : "Make captions", systemImage: "waveform.badge.mic").frame(maxWidth: .infinity)
                }.accessibilityIdentifier("captions.generate").buttonStyle(.primary).disabled(store.transcriptionMedia == nil || !store.captionEngineReady || store.isTranscribing || trackCount == 0)
                if store.isTranscribing {
                    ProgressView(value: store.transcriptionProgress)
                    Text(store.transcriptionMessage).font(.system(size: 10)).foregroundStyle(Studio.muted)
                    Button("Cancel captions") { store.transcriptionTask?.cancel() }.buttonStyle(.quiet)
                }
                Divider()
                if advanced { SpeechGapEditor() }
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
                if captions.isEmpty { Text("Make captions above, import an SRT/VTT file, or add one at the playhead with +.").font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.vertical, 20) }
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
                        Button { change { $0.colorHex = hex } } label: { Circle().fill(color(hex)).frame(width: 20, height: 20).overlay(Circle().stroke(Studio.line)).overlay(Circle().stroke(style.colorHex == hex ? Studio.accent : .clear, lineWidth: 2).padding(-3)) }.buttonStyle(.plain).accessibilityIdentifier("caption.color.\(hex)")
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
    @AppStorage("editor-advanced") private var advanced = false
    let cue: ProjectedCaption
    @State private var text = ""
    @State private var start = 0.0
    @State private var end = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { store.seek(cue.start) } label: { Text(timecode(cue.start)).monospacedDigit() }.buttonStyle(.plain).foregroundStyle(Studio.accent)
                Spacer()
                Button { store.commit { $0.captionTrack?.cues.removeAll { $0.id == cue.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).accessibilityIdentifier("caption.delete.\(cue.id)").foregroundStyle(Studio.muted)
            }.font(.system(size: 10))
            TextField("Caption", text: $text, axis: .vertical).accessibilityIdentifier("caption.text.\(cue.id)").textFieldStyle(.plain).lineLimit(1...5).font(.system(size: 12))
                .onSubmit { store.editCaption(cue.id, text: text, start: start, end: end) }
            HStack(spacing: 6) {
                if advanced {
                    TextField("Start", value: $start, format: .number.precision(.fractionLength(2))).frame(maxWidth: .infinity)
                    Text("→")
                    TextField("End", value: $end, format: .number.precision(.fractionLength(2))).frame(maxWidth: .infinity)
                } else { Spacer() }
                if advanced || text != cue.text {
                    Button("Apply") { store.editCaption(cue.id, text: text, start: start, end: end) }.buttonStyle(.secondary).controlSize(.small).accessibilityIdentifier("caption.apply.\(cue.id)").disabled(text == cue.text && start == cue.start && end == cue.end)
                }
            }.textFieldStyle(.roundedBorder).font(.system(size: 9))
            if advanced { Button("Cut this part from the video") { store.cutRanges([TimelineRange(start: cue.start, end: cue.end)]) }.buttonStyle(.quiet).font(.system(size: 10)) }
        }.padding(11).background(Studio.raised, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Studio.line))
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
