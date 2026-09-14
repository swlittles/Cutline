import SwiftUI
import AVKit
import CutlineCore

struct AutoClipPanel: View {
    @EnvironmentObject var store: EditorStore
    @State private var preview: AutoClipCandidate?
    @State private var showRegions = false
    @State private var showFraming = false
    var busy: Bool { store.isScanningClips || store.isExportingClips }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Automatic clips", systemImage: "scissors").font(.headline)
                Text("Find activity using audio levels and frame changes. Runs on this Mac; no account, transcript, or cloud service.").foregroundStyle(Studio.muted)
                if store.project.media.isEmpty {
                    Text("Import a recording in Media to get started.").accessibilityIdentifier("clips.empty")
                } else {
                    configuration.disabled(busy)
                    Button(action: store.scanAutoClips) { Label("Find clips", systemImage: "waveform.path").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("clips.scan").disabled(busy)
                }
                if busy {
                    ProgressView(value: store.clipProgress)
                    Button("Cancel scan or export") { store.clipTask?.cancel(); store.clipExportTask?.cancel() }.accessibilityIdentifier("clips.cancel")
                }
                Text(store.clipMessage).accessibilityIdentifier("clips.status").foregroundStyle(Studio.muted)
                if let report = store.clipReport {
                    if !store.clipSourceUnchanged { Text("The source changed. Scan it again before using these clips.").foregroundStyle(.orange) }
                    if report.settings != store.clipSettings || report.media.id != store.clipMedia?.id { Text("Results use the previous scan settings and recording. Find clips again to apply changes.").foregroundStyle(.orange) }
                    if !report.candidates.isEmpty {
                        HStack {
                            Button("Select all") { store.selectedAutoClips = Set(report.candidates.map(\.id)) }.accessibilityIdentifier("clips.selectAll")
                            Button("Clear") { store.selectedAutoClips = [] }.accessibilityIdentifier("clips.clear")
                        }.disabled(busy)
                        Text("\(store.selectedAutoClips.count) selected · source timecodes").accessibilityIdentifier("clips.selection")
                        Button("Export selected clips…", action: store.exportAutoClips).accessibilityIdentifier("clips.export")
                            .disabled(busy || store.selectedAutoClips.isEmpty || !store.clipSourceUnchanged)
                        Text("Creates separate 9:16 mobile shorts: 30% facecam, 2% black Kick strip, 68% gameplay. Every clip needs a hook and checked source crops. Timeline effects are not included.").foregroundStyle(Studio.muted)
                        ForEach(report.candidates) { candidate in candidateCard(candidate).disabled(busy || !store.clipSourceUnchanged) }
                    }
                    DisclosureGroup("Scan details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(report.sampledFrames) frames · \(report.audioSamples.count) audio windows · \(report.ocrReads) OCR reads")
                            ForEach(report.warnings, id: \.self) { Text($0).foregroundStyle(Studio.muted) }
                        }.padding(.top, 8)
                    }
                }
                if let output = store.clipOutput {
                    Button("Show exported clips") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.accessibilityIdentifier("clips.showOutput")
                }
            }.font(.system(size: 11)).padding(16)
        }.accessibilityIdentifier("clips.scroll")
            .onChange(of: store.clipMedia?.id) { _, _ in store.clipSettings.hudCalibrated = false }
            .sheet(item: $preview) { candidate in
                if let report = store.clipReport { ClipPreviewSheet(project: try? store.preparedAutoClip(candidate, report: report), candidate: candidate) }
            }
            .sheet(isPresented: $showFraming) { ShortFramingSheet().environmentObject(store) }
            .sheet(isPresented: $showRegions) { if let media = store.clipMedia { ClipRegionSheet(media: media).environmentObject(store) } }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Recording", selection: Binding(get: { store.clipMedia?.id }, set: { store.clipMediaID = $0 })) {
                ForEach(store.project.media) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("clips.source")
            Picker("Game", selection: Binding(get: { store.clipSettings.game }, set: { store.selectClipGame($0) })) {
                ForEach(ClipGame.allCases) { Text($0.label).tag($0) }
            }.accessibilityIdentifier("clips.game")
            Toggle("Audio bursts", isOn: $store.clipSettings.audioEnabled).accessibilityIdentifier("clips.audio")
            if store.clipSettings.audioEnabled {
                Picker("Audio track", selection: $store.clipSettings.audioTrack) {
                    ForEach(0..<max(1, store.clipMedia?.audioTrackCount ?? 1), id: \.self) { Text("Track \($0 + 1)").tag($0) }
                }.accessibilityIdentifier("clips.track")
                Text("Choose your isolated microphone track for reactions, or game audio for combat activity.").foregroundStyle(Studio.muted)
            }
            Picker("Export audio", selection: $store.clipSettings.outputAudioTrack) {
                ForEach(0..<max(1, store.clipMedia?.audioTrackCount ?? 1), id: \.self) { Text("Track \($0 + 1)").tag($0) }
            }.accessibilityIdentifier("clips.outputTrack")
            Text("Export your audience mix (usually Track 1), separately from the track used to detect activity.").foregroundStyle(Studio.muted)
            Toggle("Sustained frame changes", isOn: $store.clipSettings.visionEnabled).accessibilityIdentifier("clips.vision")
            if store.clipSettings.audioEnabled && store.clipSettings.visionEnabled {
                Toggle("Require audio and motion together", isOn: $store.clipSettings.requireBoth).accessibilityIdentifier("clips.both")
            }
            DisclosureGroup("Sensitivity & timing") {
                VStack(spacing: 9) {
                    number("Audio rise (dB)", value: $store.clipSettings.audioRiseDB, id: "clips.rise")
                    number("Audio floor (dBFS)", value: $store.clipSettings.audioFloorDB, id: "clips.floor")
                    number("Frame change (0–1)", value: $store.clipSettings.motionThreshold, id: "clips.motion")
                    number("Samples / second", value: $store.clipSettings.sampleFPS, id: "clips.fps")
                    number("Setup seconds", value: $store.clipSettings.lead, id: "clips.lead")
                    number("Payoff seconds", value: $store.clipSettings.tail, id: "clips.tail")
                    number("Encounter gap", value: $store.clipSettings.encounterGap, id: "clips.gap")
                    number("Maximum seconds", value: $store.clipSettings.maxDuration, id: "clips.maximum")
                    Stepper("Up to \(store.clipSettings.maxClips) clips", value: $store.clipSettings.maxClips, in: 1...100)
                }.padding(.top, 8)
            }
            DisclosureGroup("Game HUD OCR (optional)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Local macOS text recognition uses a trained OCR model. Enable only if local OCR fits your workflow. No OpenRouter or transcription is involved.").foregroundStyle(Studio.muted)
                    Toggle("Read elimination feed", isOn: $store.clipSettings.useOCR).accessibilityIdentifier("clips.ocr")
                    TextField("Player aliases, comma separated", text: $store.clipSettings.aliases).textFieldStyle(.roundedBorder).accessibilityIdentifier("clips.aliases")
                    Stepper("Minimum HUD matches: \(store.clipSettings.minimumKills)", value: $store.clipSettings.minimumKills, in: 1...10)
                    if !store.clipSettings.game.hasFeedPreset { Text("This game has no verified feed preset. Set the region using a visible elimination feed; Tarkov may have no suitable feed.").foregroundStyle(Studio.muted) }
                    Toggle("I checked the HUD region on this recording", isOn: $store.clipSettings.hudCalibrated).accessibilityIdentifier("clips.calibrated")
                }.padding(.top, 8)
            }
            Button("Short framing…") { showFraming = true }.accessibilityIdentifier("clips.shortFraming")
            Button("Preview / calibrate regions…") { showRegions = true }.accessibilityIdentifier("clips.regions")
        }
    }
    private func candidateCard(_ candidate: AutoClipCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(candidate.title, isOn: Binding(get: { store.selectedAutoClips.contains(candidate.id) }, set: { selected in if selected { store.selectedAutoClips.insert(candidate.id) } else { store.selectedAutoClips.remove(candidate.id) } })).accessibilityIdentifier("clips.select.\(candidate.id)")
            Text("\(timecode(candidate.start)) – \(timecode(candidate.end)) · score \(Int(candidate.score))").monospacedDigit().foregroundStyle(Studio.mint)
            TextField("Required on-screen hook", text: Binding(get: { store.autoClipHook(candidate.id) }, set: { text in
                store.commit { project in if project.autoClipHooks == nil { project.autoClipHooks = [:] }; project.autoClipHooks?[candidate.id] = text }
            })).textFieldStyle(.roundedBorder).accessibilityIdentifier("clips.hook.\(candidate.id)")
            HStack {
                Button("Preview") { preview = candidate }.accessibilityIdentifier("clips.preview.\(candidate.id)")
                Button("Add to timeline") { store.addAutoClip(candidate) }.accessibilityIdentifier("clips.add.\(candidate.id)")
            }
            DisclosureGroup("Why this clip?") {
                ForEach(Array(candidate.evidence.enumerated()), id: \.offset) { _, event in
                    Text("\(timecode(event.time)) · \(event.detail)").textSelection(.enabled).padding(.top, 4)
                }
            }
        }.padding(10).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
    }
    private func number(_ label: String, value: Binding<Double>, id: String) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 70).accessibilityIdentifier(id) }
    }
}

struct ClipPreviewSheet: View {
    let project: EditProject?
    let candidate: AutoClipCandidate
    @Environment(\.dismiss) var dismiss
    @State private var player = AVPlayer()
    @State private var error: String?
    var body: some View {
        VStack(spacing: 12) {
            Text(candidate.title).font(.headline)
            NativePlayer(player: player).frame(width: 304, height: 540)
            Text("Mobile Short · 9:16 · Kick.com/your-channel").font(.caption)
            if let error { Text(error).foregroundStyle(.orange).frame(maxWidth: 400) }
            HStack {
                Button("Play clip") { player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in player.play() } }.accessibilityIdentifier("clips.previewPlay").disabled(player.currentItem == nil)
                Button("Pause") { player.pause() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).task {
            guard let project else { error = "The clip could not be prepared."; return }
            do {
                let render = try await CompositionEngine.build(project); try Task.checkCancellation()
                player.replaceCurrentItem(with: render.playerItem())
                do { try project.validateForExport() } catch { self.error = error.localizedDescription }
            } catch { self.error = error.localizedDescription }
        }.onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
}

struct ClipRegionSheet: View {
    let media: MediaItem
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var time = 0.0
    @State private var image: NSImage?
    @State private var loadError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calibrate on a visible game HUD").font(.headline)
            if let image {
                let ratio = image.size.height / image.size.width
                let previewWidth = min(760, 400 / max(0.01, ratio))
                HStack {
                    Spacer(minLength: 0)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: previewWidth, height: previewWidth * ratio)
                        region(store.clipSettings.hud, color: .orange, label: "HUD", width: previewWidth, height: previewWidth * ratio)
                        region(store.clipSettings.motionRegion, color: .green, label: "Motion", width: previewWidth, height: previewWidth * ratio)
                    }.clipped().frame(width: previewWidth, height: previewWidth * ratio)
                    Spacer(minLength: 0)
                }.frame(width: 760, height: 400)
            } else { ProgressView().frame(width: 760, height: 300) }
            if let loadError { Text(loadError).foregroundStyle(.red) }
            Slider(value: $time, in: 0...max(0.01, media.duration - 0.1)).accessibilityIdentifier("clips.regionTime")
            Text("Source \(timecode(time)) · coordinates in percent from the top-left").font(.caption)
            regionFields("HUD", region: $store.clipSettings.hud)
            regionFields("Motion", region: $store.clipSettings.motionRegion)
            Text("Exclude facecam, chat, and animated overlays from Motion. Place HUD around the elimination feed.").font(.caption)
            HStack {
                Toggle("HUD checked", isOn: $store.clipSettings.hudCalibrated)
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).task(id: time) {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 960, height: 540)
                let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)); try Task.checkCancellation()
                image = NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height)); loadError = nil
            } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }
    private func region(_ r: ClipScanRegion, color: Color, label: String, width: Double, height: Double) -> some View {
        Rectangle().stroke(color, lineWidth: 2).overlay(alignment: .topLeading) { Text(label).font(.caption).padding(3).background(color) }
            .frame(width: max(0, min(1, r.width)) * width, height: max(0, min(1, r.height)) * height)
            .offset(x: max(0, min(1, r.x)) * width, y: max(0, min(1, r.y)) * height)
    }
    private func regionFields(_ title: String, region: Binding<ClipScanRegion>) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            percent("X", value: region.x); percent("Y", value: region.y)
            percent("Width", value: region.width); percent("Height", value: region.height)
        }
    }
    private func percent(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); TextField(title, value: Binding(get: { value.wrappedValue * 100 }, set: { value.wrappedValue = $0 / 100 }), format: .number).textFieldStyle(.roundedBorder).frame(width: 65) }
    }
}
