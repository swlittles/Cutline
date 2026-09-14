import SwiftUI
import AVFoundation
import CutlineCore

struct ShortFramingSheet: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) var dismiss
    @State private var mediaID: UUID?
    @State private var framing = ShortFraming()
    @State private var time = 0.0
    @State private var image: NSImage?
    @State private var error: String?
    var media: MediaItem? { store.project.media.first { $0.id == mediaID } ?? store.selectedMedia ?? store.clipMedia }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Short framing · 30 / 2 / 68").font(.headline)
            Picker("Recording", selection: Binding(get: { media?.id }, set: { mediaID = $0 })) {
                ForEach(store.project.media) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("short.source")
            if let image {
                let width = min(640.0, 320 * image.size.width / image.size.height)
                let height = width * image.size.height / image.size.width
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image).resizable().frame(width: width, height: height)
                    region(framing.gameplay, color: .green, title: "Gameplay", width: width, height: height)
                    region(framing.camera, color: .orange, title: "Facecam", width: width, height: height)
                }.clipped().frame(width: width, height: height).frame(width: 640, height: 320)
            } else { Text(error ?? "Loading source frame…").frame(width: 640, height: 320) }
            Slider(value: $time, in: 0...max(0.01, (media?.duration ?? 1) - 0.1)).accessibilityIdentifier("short.frameTime")
            Text("Source \(timecode(time)) · crop coordinates in percent from the top-left").font(.caption)
            fields("Facecam", region: $framing.camera)
            fields("Gameplay", region: $framing.gameplay)
            Toggle("Fit full gameplay region (for chess / HUD-heavy games)", isOn: $framing.containGameplay).accessibilityIdentifier("short.containGameplay")
            Text("Facecam fills the top panel. Gameplay fills the lower panel unless Fit is enabled. Check each recording and any scene changes; exclude its embedded facecam from the gameplay crop.").font(.caption).foregroundStyle(.secondary)
            Toggle("I checked these crops on this recording", isOn: $framing.confirmed).accessibilityIdentifier("short.confirmed")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply framing") { apply(); if error == nil { dismiss() } }.accessibilityIdentifier("short.applyFraming").keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 680)
        .onAppear { load() }.onChange(of: media?.id) { _, _ in load() }
        .task(id: "\(media?.id.uuidString ?? "")-\(time)") {
            guard let media else { return }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url)); generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 960, height: 540)
                let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)); try Task.checkCancellation()
                image = NSImage(cgImage: frame.image, size: CGSize(width: frame.image.width, height: frame.image.height)); error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func load() { framing = media?.shortFraming ?? ShortFraming(); time = min(store.selectedClip?.sourceIn ?? 0, max(0, (media?.duration ?? 1) - 0.1)); image = nil }
    private func apply() {
        do {
            try framing.validate()
            guard let id = media?.id else { return }
            store.commit { project in if let index = project.media.firstIndex(where: { $0.id == id }) { project.media[index].shortFraming = framing } }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func region(_ r: ClipScanRegion, color: Color, title: String, width: Double, height: Double) -> some View {
        Rectangle().stroke(color, lineWidth: 2).overlay(alignment: .topLeading) { Text(title).font(.caption).padding(2).background(color) }
            .frame(width: max(0, min(1, r.width)) * width, height: max(0, min(1, r.height)) * height)
            .offset(x: max(0, min(1, r.x)) * width, y: max(0, min(1, r.y)) * height)
    }
    private func fields(_ title: String, region: Binding<ClipScanRegion>) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            percent("X", region.x, title); percent("Y", region.y, title)
            percent("Width", region.width, title); percent("Height", region.height, title)
        }.font(.caption)
    }
    private func percent(_ label: String, _ value: Binding<Double>, _ region: String) -> some View {
        HStack { Text(label); TextField(label, value: Binding(get: { value.wrappedValue * 100 }, set: { value.wrappedValue = $0 / 100; framing.confirmed = false }), format: .number).textFieldStyle(.roundedBorder).frame(width: 65).accessibilityIdentifier("short.\(region).\(label)") }
    }
}
