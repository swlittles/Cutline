import SwiftUI
import CutlineCore

/// Step 4: a last look at the kept clips, optional captions, then one button that saves
/// every short into a folder.
struct ExportStepView: View {
    @EnvironmentObject var store: EditorStore
    @State private var brandingText = ""
    private var kept: [AutoClipCandidate] { store.moments.filter { store.decision($0.id) == .kept } }
    private var busy: Bool { store.isExportingClips || store.isTranscribingClips }
    var body: some View {
        VStack(spacing: 0) {
            if let output = store.clipOutput, !busy { done(output) } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            StepTitle(title: "Export \(kept.count) \(kept.count == 1 ? "short" : "shorts")", detail: "Each clip becomes its own vertical video, ready to post. Check the hooks one last time.")
                            ForEach(Array(kept.enumerated()), id: \.element.id) { index, candidate in clipCard(index, candidate) }
                        }.padding(32).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity).accessibilityIdentifier("export.scroll")
                    Rectangle().fill(Studio.line).frame(width: 1)
                    ScrollView { sidebar.padding(20) }.accessibilityIdentifier("export.sidebar").frame(width: 340).background(Studio.panel)
                }.frame(maxHeight: .infinity)
                StepFooter(back: .review, title: busy ? "Exporting…" : "Export \(kept.count) \(kept.count == 1 ? "short" : "shorts")",
                           enabled: !busy && !store.isScanningClips && store.exportProblems.isEmpty && !kept.isEmpty,
                           hint: store.exportProblems.first, identifier: "clips.export", action: store.exportKeptClips)
            }
        }.onAppear { brandingText = store.creatorProfile.username(for: store.creatorProfile.badge) }
    }
    private func done(_ output: URL) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Studio.success.opacity(0.14)).frame(width: 88, height: 88)
                Image(systemName: "checkmark").font(.system(size: 36, weight: .semibold)).foregroundStyle(Studio.success)
            }
            Text("Your shorts are ready").font(Studio.title(32))
            Text(store.clipMessage).font(.system(size: 13)).foregroundStyle(Studio.muted).accessibilityIdentifier("export.done")
            Text(output.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled)
            HStack(spacing: 10) {
                Button("Back to my clips") { store.clipOutput = nil; store.goTo(.review) }.buttonStyle(.secondaryLarge).accessibilityIdentifier("export.back")
                Button("Clip another stream", action: store.startClipping).buttonStyle(.secondaryLarge).accessibilityIdentifier("export.another")
                Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.primaryLarge).accessibilityIdentifier("clips.showOutput")
            }.padding(.top, 6)
            Text("Editable copies are in the “\(AutoClipBatch.projectsFolder)” folder if you want to change a clip later.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func clipCard(_ index: Int, _ candidate: AutoClipCandidate) -> some View {
        let shown = store.applied(candidate)
        let captions = store.review?.captions[candidate.id]
        return Card {
            HStack(alignment: .top, spacing: 16) {
                ClipThumbnail(at: shown.start + min(1.5, (shown.end - shown.start) / 2), hook: store.autoClipHook(candidate.id)).frame(width: 74)
                VStack(alignment: .leading, spacing: 10) { cardBody(index, candidate, shown: shown, captions: captions) }
            }
        }
    }
    @ViewBuilder private func cardBody(_ index: Int, _ candidate: AutoClipCandidate, shown: AutoClipCandidate, captions: [TranscriptSegment]?) -> some View {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Studio.accent)
                Text("\(clockTime(shown.start)) · \(Int((shown.end - shown.start).rounded())) sec").font(.system(size: 12)).foregroundStyle(Studio.muted)
                Spacer()
                Button("Edit…") { store.openMomentInEditor(candidate) }.buttonStyle(.accentLink).help("Open this clip in the editor. Your picks are kept.")
                Button { store.decide(candidate.id, .undecided) } label: { Image(systemName: "minus.circle") }.buttonStyle(.quiet).help("Don’t export this one")
                    .accessibilityIdentifier("export.remove.\(candidate.id)")
            }
            TextField("Hook text", text: Binding(get: { store.autoClipHook(candidate.id) }, set: { store.setHook(candidate.id, $0) }))
                .textFieldStyle(.roundedBorder).controlSize(.large).accessibilityIdentifier("export.hook.\(candidate.id)")
            if store.review?.captionsEnabled == true {
                if let captions {
                    DisclosureGroup(captions.isEmpty ? "No speech found" : "Captions (\(captions.count)) · click a line to fix it") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(captions) { segment in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(clockTime(segment.start)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 50, alignment: .leading)
                                    TextField("Caption", text: Binding(get: { segment.text }, set: { store.editClipCaption(candidate.id, segment: segment.id, text: $0) })).textFieldStyle(.plain).font(.system(size: 12))
                                }
                            }
                        }.padding(.top, 6)
                    }.font(.system(size: 12))
                } else {
                    Text("Captions are written when you export.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                }
            }
    }
    @ViewBuilder private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Ready to go") {
                check(store.brandingReady, store.brandingReady ? "\(store.creatorProfile.badge.label) badge: \(store.creatorProfile.displayText)" : "Add your \(store.creatorProfile.badge.label) username")
                if !store.brandingReady {
                    HStack {
                        PlatformLogo(platform: store.creatorProfile.badge)
                        TextField("\(store.creatorProfile.badge.label) username", text: $brandingText).textFieldStyle(.roundedBorder).accessibilityIdentifier("export.branding")
                        Button("Save") {
                            var profile = store.creatorProfile
                            if profile.badge == .kick { profile.kick = ShortBranding.username(brandingText) } else { profile.twitch = ShortBranding.username(brandingText) }
                            do { try store.saveCreatorProfile(profile) } catch { store.error = error.localizedDescription }
                        }.buttonStyle(.secondary)
                    }
                }
                check(store.clipMedia?.shortFraming?.confirmed == true, "Layout checked")
                let hooks = kept.filter { !store.autoClipHook($0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                check(hooks == kept.count, "Hooks \(hooks) of \(kept.count)")
            }
            Card(title: "Save to") {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(Studio.accent)
                    Text(store.exportFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 12)).lineLimit(1).truncationMode(.head).accessibilityIdentifier("export.folder")
                    Spacer()
                    Button("Change…", action: store.chooseExportFolder).buttonStyle(.accentLink).accessibilityIdentifier("export.changeFolder")
                }
                Text("A new folder named after your stream is created each time.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            }
            captionsCard
            Card {
                DisclosureGroup("Video quality · \(qualityLabel(store.project.options.resolution)), \(store.project.options.fps) fps") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Quality", selection: Binding(get: { store.project.options.resolution }, set: { v in store.commit { $0.options.resolution = v } })) {
                            Text("720p · smaller files").tag(720); Text("1080p · recommended").tag(1080); Text("4K · largest files").tag(2160)
                        }.accessibilityIdentifier("export.quality")
                        Picker("Frame rate", selection: Binding(get: { store.project.options.fps }, set: { v in store.commit { $0.options.fps = v } })) {
                            ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }.accessibilityIdentifier("export.fps")
                        Text("Sound: \(store.routes.export.map { "track \($0 + 1)" }.joined(separator: " + "))").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }.font(.system(size: 12)).padding(.top, 10)
                }.font(.system(size: 12))
            }
            if busy {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressLine(value: store.clipProgress, message: store.clipMessage).accessibilityIdentifier("clips.status")
                    Button("Cancel") { store.clipExportTask?.cancel(); store.clipCaptionTask?.cancel() }.buttonStyle(.secondary).accessibilityIdentifier("clips.cancel")
                }
            }
        }
    }
    private var captionsCard: some View {
        Card(title: "Captions") {
            switch store.captionEngine {
            case .unavailable:
                Text("Captions aren’t available on this Mac. They need macOS speech recognition (System Settings → Keyboard → Dictation).").font(.system(size: 11)).foregroundStyle(Studio.muted)
            default:
                Toggle("Add captions to these shorts", isOn: Binding(get: { store.review?.captionsEnabled == true }, set: { store.setClipCaptions($0) })).font(.system(size: 12)).accessibilityIdentifier("export.captions")
                if store.review?.captionsEnabled == true {
                    Text("Cutline writes captions from what you say, on this Mac. Fix any words before exporting.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    if store.captionEngine == .whisperNeedsModel {
                        Button(store.isDownloadingModel ? "Downloading speech model…" : "Download speech model (148 MB)", action: store.downloadSpeechModel).buttonStyle(.secondary).disabled(store.isDownloadingModel)
                    } else {
                        let pending = store.pendingCaptionClips.count
                        Button(pending == 0 ? "Captions ready" : "Preview captions now", action: store.transcribeKeptClips)
                            .buttonStyle(.secondary).disabled(pending == 0 || busy).accessibilityIdentifier("export.transcribe")
                    }
                }
            }
        }
    }
    private func qualityLabel(_ resolution: Int) -> String { resolution >= 2160 ? "4K" : "\(resolution)p" }
    private func check(_ ok: Bool, _ text: String) -> some View {
        Label { Text(text).foregroundStyle(ok ? Studio.text : Studio.warning) } icon: { Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? Studio.success : Studio.warning) }.font(.system(size: 12))
    }
}

/// A still of the finished short (layout, branding and hook) for the export list.
private struct ClipThumbnail: View {
    @EnvironmentObject var store: EditorStore
    let at: Double
    let hook: String
    @State private var image: NSImage?
    var body: some View {
        ShortLayoutPreview(image: image, framing: store.clipMedia?.shortFraming ?? ShortFraming(), branding: store.creatorProfile, hook: hook)
            .task(id: at) { if let media = store.clipMedia { image = try? await loadSourceFrame(media, at: at, maximum: CGSize(width: 640, height: 360)) } }
    }
}
