import SwiftUI
import AVKit
import CutlineCore

/// Scrub the recording and flag a play you remember. Marked moments always appear in the list.
struct AddMomentSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a moment you remember").font(Studio.title(22))
            Text("Scrub to the play, then add it. Clicking the activity strip jumps there.").font(.system(size: 12)).foregroundStyle(Studio.muted)
            MomentHeatStrip(height: 40, onSeek: { time in player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) })
            ScrubbingPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit).frame(width: 720).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("find.player")
            if let marks = store.review?.moments, !marks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Added by you")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(marks, id: \.self) { time in
                                HStack(spacing: 6) {
                                    Button(clockTime(time)) { player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }.buttonStyle(.plain).font(.system(size: 11, design: .monospaced))
                                    Button { store.removeMoment(time) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Studio.muted).help("Remove")
                                }.padding(.horizontal, 10).frame(height: 26).background(Studio.raised, in: Capsule()).overlay(Capsule().stroke(Studio.line))
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Done") { dismiss() }.buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    let time = player.currentTime().seconds
                    store.addMoment(at: time.isFinite ? time : 0)
                } label: { Label("Add this moment", systemImage: "flag.fill") }.buttonStyle(.primary).accessibilityIdentifier("find.mark")
            }
        }.padding(24).frame(width: 768).background(Studio.base)
        .task(id: store.clipMedia?.url) {
            guard let media = store.clipMedia else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: media.url))
            if let moment = store.focusedCandidate { await player.seek(to: CMTime(seconds: moment.start, preferredTimescale: 600)) }
        }
        .onDisappear { player.pause() }
    }
}

/// Everything about how moments are detected, out of the way of the main path.
struct DetectionSettingsSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var showRegions = false
    @State private var showAdvanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How Cutline finds moments").font(Studio.title(22))
            Text("The defaults work for most streams. Changes update the list right away.").font(.system(size: 12)).foregroundStyle(Studio.muted)
            Card(title: "Look for") {
                Toggle("Loud reactions (track \(store.clipSettings.audioTrack + 1))", isOn: $store.clipSettings.audioEnabled)
                    .disabled((store.clipMedia?.audioTrackCount ?? 0) == 0).accessibilityIdentifier("clips.audio")
                Toggle("Busy gameplay on screen", isOn: $store.clipSettings.visionEnabled).accessibilityIdentifier("clips.vision")
                if store.clipSettings.audioEnabled && store.clipSettings.visionEnabled {
                    Toggle("Only when both happen together", isOn: $store.clipSettings.requireBoth).accessibilityIdentifier("clips.both")
                }
                Text("To use a different sound track, go back to Layout → Sound.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            }.font(.system(size: 12))
            Button { withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() } } label: {
                Label(showAdvanced ? "Hide advanced settings" : "Show advanced settings", systemImage: showAdvanced ? "chevron.down" : "chevron.right")
            }.buttonStyle(.accentLink).accessibilityIdentifier("detection.advanced")
            if showAdvanced { ScrollView { AdvancedScanSettings(showRegions: $showRegions) }.frame(maxHeight: 340) }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction).accessibilityIdentifier("detection.done") }
        }.padding(24).frame(width: 520).background(Studio.base)
        .sheet(isPresented: $showRegions) { if let media = store.clipMedia { RegionCalibrationSheet(media: media).environmentObject(store) } }
    }
}

/// The detailed thresholds stay available for people who want them.
private struct AdvancedScanSettings: View {
    @EnvironmentObject var store: EditorStore
    @Binding var showRegions: Bool
    var body: some View {
        Card {
                VStack(alignment: .leading, spacing: 9) {
                    number("Audio rise (dB)", value: $store.clipSettings.audioRiseDB, id: "clips.rise")
                    number("Audio floor (dBFS)", value: $store.clipSettings.audioFloorDB, id: "clips.floor")
                    number("Frame change (0–1)", value: $store.clipSettings.motionThreshold, id: "clips.motion")
                    number("Samples / second", value: $store.clipSettings.sampleFPS, id: "clips.fps")
                    number("Seconds before", value: $store.clipSettings.lead, id: "clips.lead")
                    number("Seconds after", value: $store.clipSettings.tail, id: "clips.tail")
                    number("Join moments closer than (s)", value: $store.clipSettings.encounterGap, id: "clips.gap")
                    number("Longest clip (s)", value: $store.clipSettings.maxDuration, id: "clips.maximum")
                    Stepper("Up to \(store.clipSettings.maxClips) moments", value: $store.clipSettings.maxClips, in: 1...100)
                    Button("Motion and HUD areas…") { showRegions = true }.buttonStyle(.secondary).accessibilityIdentifier("clips.regions")
                    Text("Changing the sample rate or areas checks the video again. Other settings apply instantly.").foregroundStyle(Studio.muted)
                    Divider()
                    SectionLabel("Game HUD text (optional)")
                    Text("Reads the elimination feed with macOS text recognition, on this Mac. Enter your exact on-screen name and check the HUD area first.").foregroundStyle(Studio.muted)
                    Toggle("Read elimination feed", isOn: $store.clipSettings.useOCR).accessibilityIdentifier("clips.ocr")
                    TextField("Player names, comma separated", text: $store.clipSettings.aliases).textFieldStyle(.roundedBorder).accessibilityIdentifier("clips.aliases")
                    Stepper("Minimum HUD matches: \(store.clipSettings.minimumKills)", value: $store.clipSettings.minimumKills, in: 1...10)
                    if !store.clipSettings.game.hasFeedPreset { Text("This game has no verified feed preset. Set the HUD area on a visible elimination feed; Tarkov may have no suitable feed.").foregroundStyle(Studio.muted) }
                    Toggle("I checked the HUD area on this recording", isOn: $store.clipSettings.hudCalibrated).accessibilityIdentifier("clips.calibrated")
                    Text(store.clipMessage).foregroundStyle(Studio.muted).accessibilityIdentifier("detection.status")
                }.font(.system(size: 11))
        }
    }
    private func number(_ label: String, value: Binding<Double>, id: String) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 70).accessibilityIdentifier(id) }
    }
}

struct RegionCalibrationSheet: View {
    let media: MediaItem
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var time = 0.0
    @State private var image: NSImage?
    @State private var loadError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Motion and HUD areas").font(Studio.title(20))
            Text("Keep facecam, chat and animated overlays out of the Motion box. Put the HUD box around the elimination feed.").font(.system(size: 12)).foregroundStyle(Studio.muted)
            RegionEditor(image: image, boxes: [
                RegionBox(id: "Motion", color: Studio.series, region: $store.clipSettings.motionRegion),
                RegionBox(id: "HUD", color: Studio.accent, region: $store.clipSettings.hud)
                // HUD usually sits inside the motion area, so it draws last to stay draggable.
            ]).frame(width: 760, height: 428)
            if let loadError { Text(loadError).foregroundStyle(Studio.danger) }
            Slider(value: $time, in: 0...max(0.01, media.duration - 0.1)).accessibilityIdentifier("clips.regionTime")
            Text("Source \(clockTime(time))").font(.system(size: 11)).foregroundStyle(Studio.muted)
            HStack {
                Toggle("HUD checked on this recording", isOn: $store.clipSettings.hudCalibrated)
                Spacer(); Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.cancelAction)
            }
        }.padding(24).background(Studio.base).task(id: time) {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                image = try await loadSourceFrame(media, at: time, maximum: CGSize(width: 960, height: 540)); loadError = nil
            } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
    }
}
