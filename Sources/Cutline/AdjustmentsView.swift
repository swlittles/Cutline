import SwiftUI
import AVFoundation
import CutlineCore

struct AdjustmentsView: View {
    @EnvironmentObject var store: EditorStore
    let clip: TimelineClip
    let media: MediaItem
    @State private var draft = ClipAdjustments()
    @State private var trackCount = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup("Transform & crop") {
                VStack(spacing: 10) {
                    Toggle("Fill canvas (crop edges)", isOn: $draft.fill)
                    Toggle("Mirror", isOn: $draft.mirror)
                    adjustment("Zoom", value: $draft.zoom, range: 0.25...4)
                    adjustment("Horizontal", value: $draft.x, range: -1...1)
                    adjustment("Vertical", value: $draft.y, range: -1...1)
                    adjustment("Rotation", value: $draft.rotation, range: -180...180)
                    applyButton
                    Toggle("Smooth keyframe easing", isOn: Binding(get: { draft.smoothKeyframes ?? false }, set: { draft.smoothKeyframes = $0 }))
                    Button("Add keyframe at playhead") {
                        let offset = store.playhead - store.project.start(of: clip.id)
                        guard offset >= 0, offset <= clip.duration else { store.error = "Move the playhead inside this clip first."; return }
                        let time = clip.sourceIn + offset * clip.speed
                        if draft.keyframes == nil { draft.keyframes = [] }
                        draft.keyframes?.removeAll { abs($0.sourceTime - time) < 0.001 }
                        draft.keyframes?.append(TransformKeyframe(sourceTime: time, zoom: draft.zoom, x: draft.x, y: draft.y, rotation: draft.rotation))
                        apply()
                    }
                    ForEach(draft.keyframes ?? []) { frame in
                        HStack {
                            Button { store.seek(store.project.start(of: clip.id) + (frame.sourceTime - clip.sourceIn) / clip.speed) } label: { Label(timecode(frame.sourceTime), systemImage: "diamond.fill") }
                            Spacer()
                            Button { draft.keyframes?.removeAll { $0.id == frame.id }; apply() } label: { Image(systemName: "xmark") }
                        }.buttonStyle(.plain)
                    }
                }.padding(.top, 10)
            }
            DisclosureGroup("Speed & fades") {
                VStack(spacing: 10) {
                    Picker("Speed", selection: $draft.speed) { ForEach([0.25,0.5,0.75,1,1.25,1.5,2,4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.accessibilityIdentifier("adjust.speed")
                    adjustment("Fade in", value: $draft.fadeIn, range: 0...min(5, clip.duration / 2))
                    adjustment("Fade out", value: $draft.fadeOut, range: 0...min(5, clip.duration / 2))
                    applyButton
                }.padding(.top, 10)
            }
            DisclosureGroup("Color adjustments") {
                VStack(spacing: 10) {
                    adjustment("Brightness", value: $draft.brightness, range: -1...1)
                    adjustment("Contrast", value: $draft.contrast, range: 0...3)
                    adjustment("Saturation", value: $draft.saturation, range: 0...3)
                    HStack {
                        Button("B&W") { draft.saturation = 0; apply() }
                        Button("Vivid") { draft.saturation = 1.25; draft.contrast = 1.1; apply() }
                        Button("Reset") { draft.brightness = 0; draft.contrast = 1; draft.saturation = 1; apply() }
                    }
                    applyButton
                }.padding(.top, 10)
            }
            DisclosureGroup("Source audio tracks (\(trackCount))") {
                VStack(spacing: 10) {
                    Text("OBS often stores a full mix and separate microphone/game tracks. Mute the tracks you don’t need.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                    ForEach(0..<trackCount, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text("Audio \(index + 1) · \(Int((draft.audioGains[String(index)] ?? 1) * 100))%")
                            Slider(value: Binding(get: { draft.audioGains[String(index)] ?? 1 }, set: { draft.audioGains[String(index)] = $0 }), in: 0...2).accessibilityIdentifier("audio.gain.\(index)")
                        }
                    }
                    applyButton
                }.padding(.top, 10)
            }
        }.font(.system(size: 11))
            .onAppear { draft = clip.adjustments ?? ClipAdjustments() }
            .onChange(of: clip.adjustments) { _, value in draft = value ?? ClipAdjustments() }
            .task(id: media.id) { trackCount = (try? await AVURLAsset(url: media.url).loadTracks(withMediaType: .audio).count) ?? 0 }
    }
    private var applyButton: some View { Button("Apply adjustments", action: apply).frame(maxWidth: .infinity) }
    private func apply() { store.updateAdjustments(clip.id) { $0 = draft } }
    private func adjustment(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(name); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(Studio.muted).monospacedDigit() }
            Slider(value: value, in: range).accessibilityIdentifier("adjust.\(name)")
        }
    }
}
