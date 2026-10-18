import SwiftUI
import CutlineCore

struct InspectorView: View {
    @EnvironmentObject var store: EditorStore
    @AppStorage("editor-advanced") private var advanced = false
    @State private var showFraming = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Format")
                    Picker("Format", selection: Binding(get: { store.project.workflow }, set: { value in if let value { store.commit { $0.selectWorkflow(value) } } })) {
                        Text("Short · 9:16").tag(Optional(OutputWorkflow.mobileShort))
                        Text("YouTube · 16:9").tag(Optional(OutputWorkflow.youtubeVideo))
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("workflow.picker")
                    if store.project.workflow == nil {
                        Text("Choose a format before you export.").font(.system(size: 11)).foregroundStyle(Studio.warning)
                    }
                }
                if store.project.workflow == .mobileShort {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Hook")
                        TextField("Big text for the first 3 seconds", text: Binding(get: { store.project.shortHook ?? "" }, set: { text in store.commit { $0.shortHook = text } }))
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("short.hook")
                        Text("Shown at the top of every clip. Up to 80 characters.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        Button { showFraming = true } label: { Label("Facecam layout…", systemImage: "rectangle.split.1x2").lineLimit(1) }
                            .buttonStyle(.secondary).help("Where the facecam and gameplay sit in the short").accessibilityIdentifier("short.framing").disabled(store.project.media.isEmpty)
                        HStack(spacing: 6) {
                            if store.brandingReady { PlatformLogo(platform: store.creatorProfile.badge, size: 11) }
                            Text(store.brandingReady ? store.creatorProfile.displayText : "Add your channel username").font(.system(size: 11))
                                .foregroundStyle(store.brandingReady ? Studio.muted : Studio.warning).lineLimit(1)
                            Spacer()
                            SettingsLink { Text(store.brandingReady ? "Change" : "Add") }.buttonStyle(.accentLink)
                        }
                    }
                }
                if advanced {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Quality")
                        HStack {
                            Picker("Quality", selection: Binding(get: { store.project.options.resolution }, set: { v in store.commit { $0.options.resolution = v } })) {
                                Text("720p").tag(720); Text("1080p").tag(1080); Text("4K").tag(2160)
                            }.labelsHidden().accessibilityIdentifier("export.quality")
                            Picker("FPS", selection: Binding(get: { store.project.options.fps }, set: { v in store.commit { $0.options.fps = v } })) {
                                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                            }.labelsHidden().accessibilityIdentifier("export.fps")
                        }.font(.system(size: 11))
                        Text("\(Int(store.project.options.size(for: store.project.outputFormat).width)) × \(Int(store.project.options.size(for: store.project.outputFormat).height))").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    }
                }
                Rectangle().fill(Studio.line).frame(height: 1)
                if let clip = store.selectedClip, let media = store.selectedMedia {
                    ClipInspector(clip: clip, media: media).id(clip.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "hand.tap").font(.system(size: 24, weight: .light)).foregroundStyle(Studio.accent)
                        Text("Click a clip on the timeline").font(.system(size: 13, weight: .medium)).foregroundStyle(Studio.text)
                        Text("to trim it, change its sound, or remove it.").font(.system(size: 11)).multilineTextAlignment(.center)
                    }.foregroundStyle(Studio.muted).frame(maxWidth: .infinity).padding(.vertical, 28)
                }
                Spacer(minLength: 0)
            }.padding(18).font(.system(size: 12))
        }.accessibilityIdentifier("inspector.scroll").background(Studio.panel)
        .sheet(isPresented: $showFraming) { ShortFramingSheet().environmentObject(store) }
    }
}

struct ClipInspector: View {
    @EnvironmentObject var store: EditorStore
    @AppStorage("editor-advanced") private var advanced = false
    let clip: TimelineClip
    let media: MediaItem
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var volume = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Selected clip")
                Spacer()
                Text(timecode(clip.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted)
            }
            Text(media.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
            if store.project.workflow == .mobileShort {
                TextField("Different hook for this clip (optional)", text: Binding(get: { clip.shortHook ?? "" }, set: { text in
                    store.commit { project in
                        if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index].shortHook = text.isEmpty ? nil : text }
                    }
                })).textFieldStyle(.roundedBorder).accessibilityIdentifier("short.clipHook")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Trim").font(.system(size: 12, weight: .semibold))
                Text("Move the playhead to where the clip should start or end, then click:").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { store.trimToPlayhead(start: true) } label: { Label("Start here", systemImage: "arrow.right.to.line") }.frame(maxWidth: .infinity)
                    Button { store.trimToPlayhead(start: false) } label: { Label("End here", systemImage: "arrow.left.to.line") }.frame(maxWidth: .infinity)
                }.buttonStyle(.secondary).controlSize(.small)
                Text("Or press ⌘B to split at the playhead.").font(.system(size: 10.5)).foregroundStyle(Studio.muted)
                if advanced {
                    numericField("In", value: $start) { store.updateClip(clip.id, sourceIn: start) }
                    numericField("Out", value: $end) { store.updateClip(clip.id, sourceOut: end) }
                    Text("Seconds in the original recording. Press Return to apply.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
            }
            Rectangle().fill(Studio.line).frame(height: 1)
            HStack {
                Text("Volume").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(volume * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(Studio.muted)
                Button { store.updateClip(clip.id, volume: clip.volume == 0 ? 1 : 0) } label: { Image(systemName: clip.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.plain).foregroundStyle(Studio.accent).help("Mute / unmute clip").accessibilityIdentifier("clip.mute")
            }
            Slider(value: $volume, in: 0...2, onEditingChanged: { editing in if !editing { store.updateClip(clip.id, volume: volume) } })
            if advanced {
                Rectangle().fill(Studio.line).frame(height: 1)
                AdjustmentsView(clip: clip, media: media)
            }
            Rectangle().fill(Studio.line).frame(height: 1)
            HStack(spacing: 6) {
                Button { store.moveSelected(-1) } label: { Image(systemName: "arrow.left") }.help("Move clip earlier")
                Button { store.moveSelected(1) } label: { Image(systemName: "arrow.right") }.help("Move clip later")
                Spacer()
                Button(action: store.duplicate) { Image(systemName: "plus.square.on.square") }.help("Duplicate clip · ⌘D")
                Button(action: store.deleteSelected) { Label("Remove clip", systemImage: "trash") }.help("Remove clip · Delete")
            }.buttonStyle(.secondary).controlSize(.small)
        }
        .onAppear { sync() }.onChange(of: clip) { _, _ in sync() }
    }
    private func sync() { start = clip.sourceIn; end = clip.sourceOut; volume = clip.volume }
    private func numericField(_ label: String, value: Binding<Double>, apply: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(Studio.muted).frame(width: 28, alignment: .leading)
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).accessibilityIdentifier("trim.\(label)").onSubmit(apply)
            Text("s").foregroundStyle(Studio.muted)
        }.font(.system(size: 11, design: .monospaced))
    }
}
