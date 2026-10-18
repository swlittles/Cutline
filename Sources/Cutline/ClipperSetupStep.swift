import SwiftUI
import CutlineCore

/// Step 2: where the facecam and gameplay are, checked on the real recording. Sound and game
/// have sensible defaults and stay folded away. The layout is remembered for the next stream.
struct SetupStepView: View {
    @EnvironmentObject var store: EditorStore
    @State private var framing = ShortFraming()
    @State private var roles: [AudioRole] = []
    @State private var rolesTouched = false
    @State private var game = ClipGame.generic
    @State private var branding = ShortBranding()
    @State private var editBranding = false
    @State private var remember = true
    @State private var presetName = ""
    @State private var showSound = false
    @State private var time = 0.0
    @State private var image: NSImage?
    @State private var frameError: String?
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        StepTitle(title: "Check the layout", detail: "Drag the boxes so your facecam and the gameplay look right in the preview. Drag a corner to resize. You only do this once per layout.")
                        RegionEditor(image: image, boxes: [
                            // The smaller facecam box draws last so it stays on top and draggable.
                            RegionBox(id: "Gameplay", color: Studio.series, region: $framing.gameplay),
                            RegionBox(id: "Facecam", color: Studio.accent, region: $framing.camera)
                        ]).frame(height: 360).background(Studio.well, in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .contain).accessibilityIdentifier("setup.frame")
                        HStack(spacing: 10) {
                            Text("Try another moment").font(.system(size: 12)).foregroundStyle(Studio.muted)
                            Slider(value: $time, in: 0...max(0.01, (store.clipMedia?.duration ?? 1) - 0.1)).accessibilityIdentifier("setup.frameTime")
                            Text(clockTime(time)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 64, alignment: .trailing)
                        }
                        if let frameError { Text(frameError).font(.system(size: 12)).foregroundStyle(Studio.danger) }
                        Toggle("Show the whole game area (adds black bars). Good for games with a lot on screen.", isOn: $framing.containGameplay)
                            .font(.system(size: 12)).accessibilityIdentifier("setup.containGameplay")
                        soundCard
                        Card(title: "Game · optional") {
                            HStack {
                                Picker("Game", selection: $game) { ForEach(ClipGame.allCases) { Text($0.label).tag($0) } }
                                    .labelsHidden().fixedSize().accessibilityIdentifier("setup.game")
                                Spacer()
                            }
                            Text("Helps Cutline decide how much to show before and after each moment.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        SectionLabel("Preview")
                        ShortLayoutPreview(image: image, framing: framing, branding: branding, hook: "Your hook appears here", placement: $branding.placement).frame(width: 270)
                        brandingCard
                        Card {
                            Toggle("Remember this layout for next time", isOn: $remember).font(.system(size: 12)).accessibilityIdentifier("setup.savePreset")
                            if remember {
                                TextField("Layout name", text: $presetName).textFieldStyle(.roundedBorder).accessibilityIdentifier("setup.presetName")
                                Text("Next stream, Cutline skips this step.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                            }
                        }
                    }.frame(width: 300)
                }.padding(32).frame(maxWidth: 1180).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("setup.scroll")
            StepFooter(back: .importVOD, title: "Looks good – pick clips", enabled: store.clipMedia != nil && blocker == nil, hint: blocker, identifier: "setup.continue") {
                let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
                store.completeSetup(framing: framing, roles: roles, game: game, branding: branding == store.creatorProfile ? nil : branding, presetName: remember ? (name.isEmpty ? "My layout" : name) : nil)
            }
        }
        .onAppear(perform: load)
        .onChange(of: store.clipMedia?.id) { _, _ in load() }
        .onChange(of: store.trackNames[store.clipMedia?.id ?? UUID()]?.count) { _, _ in if !rolesTouched && store.clipMedia?.audioRoles == nil { roles = store.audioRoles } }
        .onDisappear { store.stopAudition() }
        .task(id: "\(store.clipMedia?.id.uuidString ?? "")-\(time)") {
            guard let media = store.clipMedia else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                image = try await loadSourceFrame(media, at: time); frameError = nil
            } catch { if !Task.isCancelled { frameError = error.localizedDescription } }
        }
    }
    private var blocker: String? {
        if !framing.camera.valid || !framing.gameplay.valid { return "Keep both boxes inside the picture." }
        if branding.displayText.isEmpty { return "Add your \(branding.badge.label) username for the channel badge." }
        if let problem = (try? branding.validate()) == nil ? "Check your username: letters, numbers, dots, dashes and underscores." : nil { return problem }
        return nil
    }
    private var trackCount: Int { store.clipMedia?.audioTrackCount ?? 0 }
    private var soundSummary: String {
        if trackCount == 0 { return "This recording has no sound. Cutline will look for busy gameplay instead." }
        if trackCount == 1 { return "One sound track, used for everything." }
        let routes = AudioRoutes(roles)
        return "Your shorts play \(routes.export.map { "track \($0 + 1)" }.joined(separator: " + ")). Moments are found from track \(routes.detect + 1)."
    }
    private var soundCard: some View {
        Card(title: "Sound") {
            HStack(alignment: .firstTextBaseline) {
                Text(soundSummary).font(.system(size: 12)).accessibilityIdentifier("setup.soundSummary")
                Spacer()
                if trackCount > 1 {
                    Button(showSound ? "Done" : "Change") { withAnimation(.easeOut(duration: 0.15)) { showSound.toggle() } }.buttonStyle(.accentLink).accessibilityIdentifier("setup.changeSound")
                }
            }
            if showSound && trackCount > 1 {
                Text("OBS can record several tracks. Tell Cutline what each one holds. Press play to listen.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                ForEach(0..<trackCount, id: \.self) { index in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track \(index + 1)").font(.system(size: 12, weight: .medium))
                            if let name = store.trackNames[store.clipMedia?.id ?? UUID()]?[safe: index] ?? nil { Text(name).font(.system(size: 10)).foregroundStyle(Studio.muted).lineLimit(1) }
                        }.frame(width: 70, alignment: .leading)
                        Button { store.auditionTrack(index) } label: { Image(systemName: store.auditioningTrack == index ? "stop.fill" : "play.fill").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).foregroundStyle(Studio.accent).help("Listen to 8 seconds of this track").accessibilityIdentifier("setup.listen.\(index)")
                        TrackSparkline(samples: store.clipAnalysis?.audioTracks.map { $0[index] ?? [] }, duration: store.clipMedia?.duration ?? 1).frame(minWidth: 40, maxWidth: .infinity).frame(height: 26)
                        Picker("Holds", selection: Binding(get: { roles[safe: index] ?? .ignore }, set: { value in
                            while roles.count <= index { roles.append(.ignore) }
                            roles[index] = value; rolesTouched = true
                        })) { ForEach(AudioRole.allCases) { Text($0.plainLabel).tag($0) } }
                            .labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("setup.role.\(index)")
                    }
                }
                let routes = AudioRoutes(roles)
                Text("Moments are detected from Track \(routes.detect + 1). Clips play \(routes.export.map { "Track \($0 + 1)" }.joined(separator: " + ")). Captions listen to Track \(routes.speech + 1).")
                    .font(.system(size: 11)).foregroundStyle(Studio.accent).accessibilityIdentifier("setup.routes")
            }
        }
    }
    private var brandingCard: some View {
        Card(title: "Your channel badge") {
            if store.brandingReady && !editBranding {
                HStack(spacing: 8) {
                    PlatformLogo(platform: branding.badge)
                    Text(branding.displayText).font(.system(size: 13, weight: .medium)).lineLimit(1).accessibilityIdentifier("setup.badgeSummary")
                    Spacer()
                    Button("Change") { editBranding = true }.buttonStyle(.accentLink).accessibilityIdentifier("setup.changeBadge")
                }
            } else {
                BrandingFields(branding: $branding)
            }
            BadgeSizeControl(placement: $branding.placement)
        }
    }
    private func load() {
        guard let media = store.clipMedia else { return }
        framing = media.shortFraming ?? store.lastScenePreset?.framing ?? ShortFraming()
        roles = store.audioRoles; rolesTouched = media.audioRoles != nil
        game = store.clipSettings.game
        branding = store.creatorProfile; editBranding = false
        presetName = store.lastScenePreset?.name ?? "My layout"
        time = min(media.duration - 0.1, max(0, media.duration * 0.2)); image = nil
    }
}

extension AudioRole {
    /// Plain words for the sound picker.
    var plainLabel: String {
        switch self { case .mix: return "Everything"; case .mic: return "My voice"; case .game: return "Game"; case .ignore: return "Not used" }
    }
}
