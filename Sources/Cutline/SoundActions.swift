import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CutlineCore

// MARK: - Sound effects
/// The sound library lives in Application Support. Sounds go on the editor's timeline at the
/// playhead, or on a moment in Pick clips at the preview's current time.
extension EditorStore {
    func refreshSounds() {
        Task { sounds = await SoundLibrary.sounds() }
    }
    func chooseSoundFiles(category: String) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]; panel.message = "Choose sound effects to keep in Cutline."
        guard panel.runModal() == .OK else { return }
        do { let added = try SoundLibrary.add(panel.urls, category: category); refreshSounds(); status = "Added \(added) \(added == 1 ? "sound" : "sounds")." }
        catch { self.error = error.localizedDescription }
    }
    func chooseSoundPack() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a folder of sounds. Subfolders such as impact or whoosh become categories."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let added = try SoundLibrary.importPack(url); refreshSounds(); status = "Imported \(added) \(added == 1 ? "sound" : "sounds")." }
        catch { self.error = error.localizedDescription }
    }
    func removeSound(_ sound: SoundEffect) {
        do { try SoundLibrary.remove(sound); refreshSounds() } catch { self.error = error.localizedDescription }
    }
    func showSoundsFolder() {
        let folder = SoundLibrary.folder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    func previewSound(_ sound: SoundEffect) {
        soundPlayer.replaceCurrentItem(with: AVPlayerItem(url: sound.url)); soundPlayer.play()
    }

    /// Adds a sound to the editor's timeline at the playhead. It shows on the Music lane and can be moved in Layers.
    func addSoundAtPlayhead(_ sound: SoundEffect) {
        guard !project.clips.isEmpty else { error = "Add a clip to the timeline first."; return }
        let start = min(max(0, playhead), max(0, project.duration - 0.1))
        commit { $0.music = ($0.music ?? []) + [AudioClip(sound: sound, start: start)] }
        status = "Added \(sound.name) at \(clockTime(start))."
    }
    /// Sound effects on the editor's timeline that came from the library.
    var timelineSounds: [AudioClip] { (project.music ?? []).filter { $0.label != nil } }
    func removeTimelineSound(_ id: UUID) { commit { $0.music?.removeAll { $0.id == id } } }

    /// Sounds added to one moment, in seconds from the start of its short.
    func momentSounds(_ id: String) -> [AudioClip] { project.autoClipSounds?[id] ?? [] }
    /// Adds a sound to the focused moment where its preview is paused or playing now.
    func addSoundToMoment(_ sound: SoundEffect) {
        guard let candidate = focusedCandidate else { return }
        let length = applied(candidate).end - applied(candidate).start
        let now = reviewPlayer.currentTime().seconds
        let start = min(max(0, now.isFinite ? now : 0), max(0, length - 0.1))
        commit {
            if $0.autoClipSounds == nil { $0.autoClipSounds = [:] }
            $0.autoClipSounds?[candidate.id, default: []].append(AudioClip(sound: sound, start: start))
        }
        status = "Added \(sound.name) at \(clockTime(start)) in this short."
    }
    func removeMomentSound(_ id: String, sound: UUID) {
        commit {
            $0.autoClipSounds?[id]?.removeAll { $0.id == sound }
            if $0.autoClipSounds?[id]?.isEmpty == true { $0.autoClipSounds?[id] = nil }
        }
    }
}

/// "Add sound" with the library grouped by category.
struct SoundMenu: View {
    @EnvironmentObject var store: EditorStore
    var title = "Add sound"
    let add: (SoundEffect) -> Void
    var body: some View {
        Menu {
            if store.sounds.isEmpty {
                Text("Your sound library is empty")
            }
            ForEach(SoundLibrary.categories + Set(store.sounds.map(\.category)).subtracting(SoundLibrary.categories).sorted(), id: \.self) { category in
                let sounds = store.sounds.filter { $0.category == category }
                if !sounds.isEmpty {
                    Section(SoundLibrary.title(category)) {
                        ForEach(sounds) { sound in Button(sound.name) { add(sound) } }
                    }
                }
            }
            Divider()
            SettingsButton(title: store.sounds.isEmpty ? "Import sounds in Settings…" : "Manage sounds…", tab: "sounds")
        } label: { Label(title, systemImage: "speaker.wave.2") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("sounds.add")
            .onAppear { if store.sounds.isEmpty { store.refreshSounds() } }
    }
}
