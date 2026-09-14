import SwiftUI
import CutlineCore

struct InspectorView: View {
    @EnvironmentObject var store: EditorStore
    @State private var showFraming = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Inspector").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    caption("OUTPUT WORKFLOW")
                    ForEach(OutputWorkflow.allCases) { workflow in
                        Button { store.commit { $0.selectWorkflow(workflow) } } label: {
                            HStack {
                                Image(systemName: store.project.workflow == workflow ? "checkmark.circle.fill" : "circle")
                                Text(workflow.label)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.accessibilityIdentifier("workflow.\(workflow.rawValue)")
                    }
                    if store.project.workflow == nil {
                        Text("Older project: choose an output workflow before export.").foregroundStyle(.orange)
                    }
                    if store.project.workflow == .mobileShort {
                        Text("30% facecam · 2% black branding strip · 68% gameplay. Branding is always included. Set your branding in Settings.").foregroundStyle(Studio.muted)
                        TextField("Required on-screen hook", text: Binding(get: { store.project.shortHook ?? "" }, set: { text in store.commit { $0.shortHook = text } }))
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("short.hook")
                        Text("Shown for the first 3 seconds of each clip. Up to 80 characters. Override individual clips below.").font(.caption).foregroundStyle(Studio.muted)
                        Button("Short framing…") { showFraming = true }.accessibilityIdentifier("short.framing").disabled(store.project.media.isEmpty)
                    }
                    Text("\(Int(store.project.options.size(for: store.project.outputFormat).width)) × \(Int(store.project.options.size(for: store.project.outputFormat).height)) · \(store.project.options.fps) fps").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    HStack {
                        Picker("Quality", selection: Binding(get: { store.project.options.resolution }, set: { v in store.commit { $0.options.resolution = v } })) {
                            Text("720p").tag(720); Text("1080p").tag(1080); Text("4K").tag(2160)
                        }.accessibilityIdentifier("export.quality")
                        Picker("FPS", selection: Binding(get: { store.project.options.fps }, set: { v in store.commit { $0.options.fps = v } })) {
                            ForEach([24,25,30,50,60], id: \.self) { Text("\($0)").tag($0) }
                        }.accessibilityIdentifier("export.fps")
                    }.font(.system(size: 10))
                }
                Rectangle().fill(Studio.line).frame(height: 1)
                if let clip = store.selectedClip, let media = store.selectedMedia {
                    ClipInspector(clip: clip, media: media).id(clip.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 25, weight: .light))
                        Text("A little fine-tuning.").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        Text("Select a timeline clip to adjust\nits trim and audio.").font(.system(size: 11)).multilineTextAlignment(.center).lineSpacing(4)
                    }.foregroundStyle(Studio.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
                }
                Spacer(minLength: 0)
            }.padding(18)
        }.accessibilityIdentifier("inspector.scroll").background(Studio.panel)
        .sheet(isPresented: $showFraming) { ShortFramingSheet().environmentObject(store) }
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Studio.muted) }
}

struct ClipInspector: View {
    @EnvironmentObject var store: EditorStore
    let clip: TimelineClip
    let media: MediaItem
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var volume = 1.0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SELECTED CLIP").font(.system(size: 9)).tracking(1.2).foregroundStyle(Studio.muted)
            if store.project.workflow == .mobileShort {
                TextField("Hook override (optional)", text: Binding(get: { clip.shortHook ?? "" }, set: { text in
                    store.commit { project in
                        if let index = project.clips.firstIndex(where: { $0.id == clip.id }) { project.clips[index].shortHook = text.isEmpty ? nil : text }
                    }
                })).textFieldStyle(.roundedBorder).accessibilityIdentifier("short.clipHook")
            }
            Text(media.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
            valueRow("Timeline duration", timecode(clip.duration))
            Divider().overlay(Studio.line)
            Text("Trim source").font(.system(size: 12, weight: .medium))
            numericField("In", value: $start) { store.updateClip(clip.id, sourceIn: start) }
            numericField("Out", value: $end) { store.updateClip(clip.id, sourceOut: end) }
            Text("Times are in seconds within the original recording. Press Return to apply.").font(.system(size: 10)).foregroundStyle(Studio.muted).lineSpacing(3)
            HStack {
                Button("Set in here") { store.trimToPlayhead(start: true) }
                Button("Set out here") { store.trimToPlayhead(start: false) }
            }.font(.system(size: 10)).controlSize(.small)
            Divider().overlay(Studio.line)
            valueRow("Clip audio", "\(Int(volume * 100))%")
            Slider(value: $volume, in: 0...2, onEditingChanged: { editing in if !editing { store.updateClip(clip.id, volume: volume) } })
            HStack {
                Text("Source audio master").font(.system(size: 10)).foregroundStyle(Studio.muted)
                Spacer()
                Button { store.updateClip(clip.id, volume: clip.volume == 0 ? 1 : 0) } label: { Image(systemName: clip.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.plain).help("Mute / unmute clip").accessibilityIdentifier("clip.mute")
            }
            Divider().overlay(Studio.line)
            AdjustmentsView(clip: clip, media: media)
            Divider().overlay(Studio.line)
            HStack {
                Button { store.moveSelected(-1) } label: { Image(systemName: "arrow.left") }.help("Move clip earlier")
                Button { store.moveSelected(1) } label: { Image(systemName: "arrow.right") }.help("Move clip later")
                Spacer()
                Button(action: store.duplicate) { Image(systemName: "plus.square.on.square") }.help("Duplicate clip · ⌘D")
                Button(action: store.deleteSelected) { Image(systemName: "trash") }.help("Remove clip · Delete")
            }.buttonStyle(.borderless)
        }
        .onAppear { sync() }.onChange(of: clip) { _, _ in sync() }
    }
    private func sync() { start = clip.sourceIn; end = clip.sourceOut; volume = clip.volume }
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Studio.muted); Spacer(); Text(value).monospacedDigit() }.font(.system(size: 11))
    }
    private func numericField(_ label: String, value: Binding<Double>, apply: @escaping () -> Void) -> some View {
        HStack {
            Text(label).foregroundStyle(Studio.muted).frame(width: 28, alignment: .leading)
            TextField(label, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).accessibilityIdentifier("trim.\(label)").onSubmit(apply)
            Text("s").foregroundStyle(Studio.muted)
        }.font(.system(size: 11, design: .monospaced))
    }
}
