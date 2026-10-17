import SwiftUI
import CutlineCore

/// Step 1: choose the recording. Finding moments starts as soon as one is chosen.
/// A remembered layout is offered up front so repeat streams skip straight to picking clips.
struct ImportStepView: View {
    @EnvironmentObject var store: EditorStore
    @State private var presetID: UUID?
    @State private var targeted = false
    private var videos: [MediaItem] { store.project.media }
    private var preset: ScenePreset? { store.scenePresets.first { $0.id == presetID } }
    private var skipsLayout: Bool { preset != nil && store.brandingReady }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    StepTitle(title: "Choose a stream recording", detail: "Any MP4, MOV or OBS MKV recording. Cutline never changes the original file.")
                    Button(action: store.chooseVODFromPanel) {
                        VStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Studio.accent.opacity(0.12)).frame(width: 64, height: 64)
                                if store.isImporting { ProgressView() } else { Image(systemName: "arrow.down.to.line").font(.system(size: 24, weight: .medium)).foregroundStyle(Studio.accent) }
                            }
                            Text(store.isImporting ? store.status : "Drop your recording here").font(.system(size: 16, weight: .semibold))
                            Text(store.isImporting ? "This only takes a moment." : "or click to choose a file").font(.system(size: 12)).foregroundStyle(Studio.muted)
                        }.frame(maxWidth: .infinity).frame(height: videos.isEmpty ? 280 : 170)
                            .background(targeted ? Studio.accent.opacity(0.08) : Studio.raised, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? Studio.accent : Studio.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(store.isImporting).accessibilityIdentifier("import.choose")
                        .dropDestination(for: URL.self) { urls, _ in store.importVOD(urls); return true } isTargeted: { targeted = $0 }
                    if !videos.isEmpty {
                        Card(title: videos.count == 1 ? "Your recording" : "Which recording?") {
                            ForEach(videos) { item in recordingRow(item) }
                        }
                    }
                    if store.clipMedia != nil && !store.scenePresets.isEmpty { layoutCard }
                }.frame(maxWidth: 860, alignment: .leading).padding(32).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("import.scroll")
            StepFooter(title: skipsLayout ? "Pick clips" : "Next: check the layout", enabled: store.clipMedia != nil && !store.isImporting,
                       hint: store.clipMedia == nil ? "Choose a recording to continue." : store.isScanningClips ? "Finding moments in the background…" : nil) {
                guard store.clipMedia != nil else { return }
                if let preset {
                    store.applyScenePreset(preset)
                    store.goTo(store.canEnter(.review) ? .review : .setup)
                } else { store.goTo(.setup) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in store.importVOD(urls); return true }
        .onAppear { presetID = store.clipMedia?.shortFraming?.confirmed == true ? nil : store.lastScenePreset?.id }
    }
    /// One remembered layout reads as a simple choice; several become a menu.
    private var layoutCard: some View {
        Card(title: "Layout") {
            if store.scenePresets.count == 1, let only = store.scenePresets.first {
                Toggle(isOn: Binding(get: { presetID == only.id }, set: { presetID = $0 ? only.id : nil })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use my saved layout “\(only.name)”").font(.system(size: 13, weight: .medium))
                        Text("Same facecam, gameplay and sound as last time. Skips the layout step.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }
                }.toggleStyle(.checkbox).accessibilityIdentifier("import.useLayout")
            } else {
                Text("Reuse the facecam, gameplay and sound setup from an earlier stream.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                Picker("Layout", selection: $presetID) {
                    Text("Set up this recording").tag(UUID?.none)
                    ForEach(store.scenePresets) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 360).accessibilityIdentifier("import.preset")
            }
        }
    }
    private func recordingRow(_ item: MediaItem) -> some View {
        let selected = store.clipMedia?.id == item.id
        return Button { store.chooseVOD(item.id) } label: {
            HStack(spacing: 14) {
                Group {
                    if let image = store.thumbnails[item.id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Studio.well).overlay(Image(systemName: "film").foregroundStyle(Studio.muted)) }
                }.frame(width: 120, height: 68).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(clockTime(item.duration)).font(.system(size: 11)).foregroundStyle(Studio.muted)
                    if selected && store.isScanningClips { Text(store.clipMessage).font(.system(size: 11)).foregroundStyle(Studio.accent).lineLimit(1) }
                    else if selected && store.clipReport != nil { Label("Moments found", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Studio.success) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(selected ? Studio.accent : Studio.muted)
            }.padding(10).background(selected ? Studio.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("import.recording.\(item.id)")
    }
}
