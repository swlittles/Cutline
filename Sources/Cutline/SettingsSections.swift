import SwiftUI
import CutlineCore

/// General (appearance, channel, agents, updates), AI and Sounds.
struct SettingsView: View {
    @ObservedObject var updates: UpdateService
    @EnvironmentObject var store: EditorStore
    var body: some View {
        TabView(selection: $store.settingsTab) {
            UpdatesSettingsView(updates: updates).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            Form { Section("AI provider") { AISettingsView() } }.formStyle(.grouped).frame(width: 560)
                .tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
            Form { Section("Sound effects") { SoundsSettingsView() } }.formStyle(.grouped).frame(width: 560, height: 520)
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }.tag("sounds")
        }
    }
}

/// Opens Settings on one tab.
struct SettingsButton: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    let title: String
    var tab = "ai"
    var body: some View {
        Button(title) { store.settingsTab = tab; openSettings() }
    }
}

/// Settings → AI: which provider to use, its API key, and a model for each AI step.
struct AISettingsView: View {
    @EnvironmentObject var store: EditorStore
    @State private var keys: [AIProvider: String] = [:]
    @State private var saved: Set<AIProvider> = []
    var body: some View {
        Picker("Send AI requests to", selection: $store.aiProvider) {
            ForEach(AIProvider.allCases) { Text($0 == .claude ? "Claude API (Anthropic)" : $0.name).tag($0) }
        }.accessibilityIdentifier("settings.aiProvider")
        ForEach(AIProvider.allCases) { provider in keyRow(provider) }
        let provider = store.aiProvider
        LabeledContent("Picking moments") { modelField($store.clipPickModel, id: "settings.pickModel") }
        LabeledContent("Titles and hooks") { modelField($store.clipCopyModel, id: "settings.copyModel") }
        LabeledContent("Looking at frames") { modelField($store.clipVisionModel, id: "settings.visionModel") }
        LabeledContent("Editing assistant") { modelField($store.aiModel, id: "settings.assistantModel") }
        Text("\(provider.name) models, such as \(provider.modelExamples). Each must support structured output; Looking at frames also needs images.\(provider == .claude ? " Claude thinks before answering, which costs output tokens; claude-sonnet-5-5 and claude-haiku-5-5 cost less than claude-opus-5-5." : "")")
            .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
        Toggle("Let AI pick moments in Clip a stream", isOn: $store.aiFindsMoments)
        Toggle("Write titles and hooks for each pick", isOn: $store.aiPolishesCopy).disabled(!store.aiFindsMoments)
        Toggle("Look at still frames (sends small images)", isOn: $store.aiLooksAtFrames).disabled(!store.aiFindsMoments)
        Text("Image and video generation in the AI panel always uses OpenRouter. Keys are kept in your Keychain, never in project files.")
            .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            .onAppear { saved = Set(AIProvider.allCases.filter { AIKeychain.read($0) != nil }) }
    }
    @ViewBuilder private func keyRow(_ provider: AIProvider) -> some View {
        LabeledContent(provider.keyLabel) {
            HStack {
                if saved.contains(provider) {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(Studio.success)
                    Button("Remove") {
                        do { try store.removeAIKey(for: provider); saved.remove(provider) } catch { store.error = error.localizedDescription }
                    }.accessibilityIdentifier("settings.removeKey.\(provider.rawValue)")
                } else {
                    SecureField("Paste key", text: Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 170).accessibilityIdentifier("settings.key.\(provider.rawValue)")
                    Button("Save") {
                        do { try store.saveAIKey(keys[provider] ?? "", for: provider); keys[provider] = nil; saved.insert(provider) }
                        catch { store.error = error.localizedDescription }
                    }.disabled((keys[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty).accessibilityIdentifier("settings.saveKey.\(provider.rawValue)")
                    Link("Get a key", destination: provider.keysURL).font(.system(size: 11))
                }
            }
        }
    }
    private func modelField(_ value: Binding<String>, id: String) -> some View {
        TextField("Model ID", text: value).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).frame(width: 230).accessibilityIdentifier(id)
    }
}

/// Settings → Sounds: the sound effects Cutline keeps for clips.
struct SoundsSettingsView: View {
    @EnvironmentObject var store: EditorStore
    @State private var category = "impact"
    var body: some View {
        Text(store.sounds.isEmpty
             ? "Keep sound effects here to add them to clips: in Pick clips, or from the editor's Sounds tab. Cutline doesn't include any sounds; import your own."
             : "\(store.sounds.count) \(store.sounds.count == 1 ? "sound" : "sounds"). Add them to clips in Pick clips or the editor's Sounds tab.")
            .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
        SoundLibraryList { sound in
            Button { store.removeSound(sound) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Studio.muted).help("Remove from the library")
        }
        HStack {
            Picker("Category", selection: $category) { ForEach(SoundLibrary.categories, id: \.self) { Text(SoundLibrary.title($0)).tag($0) } }.labelsHidden().fixedSize()
            Button("Import sounds…") { store.chooseSoundFiles(category: category) }.accessibilityIdentifier("settings.importSounds")
            Spacer()
            Button("Import a folder…", action: store.chooseSoundPack).accessibilityIdentifier("settings.importPack")
        }
        Button("Show in Finder", action: store.showSoundsFolder).buttonStyle(.link)
            .onAppear(perform: store.refreshSounds)
    }
}
