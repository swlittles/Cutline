import SwiftUI
import CutlineCore

/// The editor's sound effects: the library on top, the ones on this timeline below.
struct SoundsPanel: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Sound effects", systemImage: "speaker.wave.2").font(.system(size: 14, weight: .semibold))
                Text("Click + to add a sound at the playhead (\(clockTime(store.playhead))). Sounds play on the Music lane.")
                    .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                if store.sounds.isEmpty {
                    Text("No sounds yet. Import audio files, or a folder with subfolders such as impact and whoosh.")
                        .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                SoundLibraryList { sound in
                    Button { store.addSoundAtPlayhead(sound) } label: { Image(systemName: "plus") }.buttonStyle(.quiet)
                        .disabled(store.project.clips.isEmpty).help("Add at the playhead").accessibilityIdentifier("sounds.add.\(sound.id)")
                }
                HStack {
                    Button("Import sounds…") { store.chooseSoundFiles(category: "other") }.buttonStyle(.secondary)
                    Button("Import a folder…", action: store.chooseSoundPack).buttonStyle(.secondary)
                }.font(.system(size: 11))
                let placed = store.timelineSounds
                if !placed.isEmpty {
                    Divider()
                    SectionLabel("On this timeline")
                    ForEach(placed) { sound in
                        HStack {
                            Button(sound.name) { store.seek(sound.start) }.buttonStyle(.plain).font(.system(size: 12))
                            Spacer()
                            Text(clockTime(sound.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.muted)
                            Button { store.removeTimelineSound(sound.id) } label: { Image(systemName: "trash") }.buttonStyle(.quiet).help("Remove")
                        }
                    }
                    Text("Move or change the volume of a sound in Layers (advanced editing tools).").font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
            }.padding(16)
        }.accessibilityIdentifier("sounds.scroll").onAppear(perform: store.refreshSounds)
    }
}

/// Every sound in the library by category, each with a play button and a caller-supplied action.
struct SoundLibraryList<Action: View>: View {
    @EnvironmentObject var store: EditorStore
    @ViewBuilder let action: (SoundEffect) -> Action
    var body: some View {
        let categories = SoundLibrary.categories + Set(store.sounds.map(\.category)).subtracting(SoundLibrary.categories).sorted()
        ForEach(categories, id: \.self) { category in
            let sounds = store.sounds.filter { $0.category == category }
            if !sounds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(SoundLibrary.title(category))
                    ForEach(sounds) { sound in
                        HStack(spacing: 8) {
                            Button { store.previewSound(sound) } label: { Image(systemName: "play.circle") }.buttonStyle(.plain).foregroundStyle(Studio.accent).help("Listen")
                            Text(sound.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1fs", sound.duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                            action(sound)
                        }
                    }
                }
            }
        }
    }
}
