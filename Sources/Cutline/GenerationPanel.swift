import SwiftUI
import CutlineCore

struct GenerationPanel: View {
    @EnvironmentObject var store: EditorStore
    @State private var kind: GenerationKind = .image
    @State private var models: [GenerationModel] = []
    @State private var modelID = ""
    @State private var ratio = ""
    @State private var resolution = ""
    @State private var duration = 4
    @State private var prompt = ""
    @State private var loading = false
    private var model: GenerationModel? { models.first { $0.id == modelID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Generate media", systemImage: "photo.badge.plus").font(.system(size: 14, weight: .semibold))
            Text("Create artwork, intro shots, or background footage from a prompt.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            Picker("Type", selection: $kind) { Text("Image").tag(GenerationKind.image); Text("Video").tag(GenerationKind.video) }.pickerStyle(.segmented).labelsHidden()
                .onChange(of: kind) { _, _ in models = []; modelID = ""; loadModels() }
                .disabled(store.isGenerating || loading)
            Button(loading ? "Loading models…" : "Load available models", action: loadModels).disabled(loading)
            if !models.isEmpty {
                Picker("Model", selection: $modelID) { ForEach(models) { Text($0.name).tag($0.id) } }.labelsHidden().onChange(of: modelID) { _, _ in resetOptions() }
                if let model {
                    if !model.ratios.isEmpty { Picker("Shape", selection: $ratio) { ForEach(model.ratios, id: \.self) { Text($0).tag($0) } } }
                    if !model.resolutions.isEmpty { Picker("Resolution", selection: $resolution) { ForEach(model.resolutions, id: \.self) { Text($0).tag($0) } } }
                    if kind == .video { Picker("Duration", selection: $duration) { ForEach(model.supported_durations ?? [], id: \.self) { Text("\($0) seconds").tag($0) } } }
                    Link("View model and pricing", destination: URL(string: "https://openrouter.ai/\(model.id)")!)
                }
                TextEditor(text: $prompt).accessibilityIdentifier("generation.prompt").scrollContentBackground(.hidden).padding(8).frame(height: 105).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
                Text("Sends this prompt to OpenRouter and its provider. Uses your OpenRouter credits. Generated assets are saved locally; nothing from your timeline is uploaded.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                Button("Generate \(kind.rawValue)") {
                    if let model { store.generateMedia(kind: kind, model: model, prompt: prompt, ratio: ratio, resolution: resolution, duration: duration) }
                }.buttonStyle(.borderedProminent).disabled(store.isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model == nil)
            }
            if store.isGenerating {
                ProgressView()
                Text(store.generationMessage).foregroundStyle(Studio.muted)
                Button("Stop waiting") { store.generationTask?.cancel() }
                Text("A submitted video job may continue and use credits. Resume it below instead of submitting again.").font(.system(size: 10)).foregroundStyle(Studio.muted)
            }
            if !store.generations.isEmpty {
                Divider(); Text("Your generated assets").font(.system(size: 12, weight: .semibold))
                ForEach(store.generations) { record in
                    VStack(alignment: .leading, spacing: 7) {
                        if record.kind == .image, let url = record.assetURL { GeneratedAssetPreview(url: url) }
                        Text(record.prompt).lineLimit(3)
                        Text("\(record.kind.rawValue.capitalized) · \(record.status)").foregroundStyle(Studio.muted)
                        if let cost = record.cost { Text(String(format: "Provider-reported cost: $%.4f", cost)).foregroundStyle(Studio.muted) }
                        HStack {
                            if record.assetURL != nil {
                                Button("Add to library") { store.importGenerated(record) }.disabled(store.isImporting)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.assetURL!]) }
                            } else if record.kind == .video, record.remoteID != nil, !["failed", "expired", "cancelled"].contains(record.status) {
                                Button("Resume job") { store.resumeGeneration(record) }.disabled(store.isGenerating)
                            }
                        }
                        if let id = record.remoteID { Text(id).font(.system(size: 9, design: .monospaced)).textSelection(.enabled).foregroundStyle(Studio.muted) }
                        if record.status == "starting" { Text("Submission was interrupted. Check OpenRouter activity before generating again.").foregroundStyle(Studio.muted) }
                    }.padding(10).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.font(.system(size: 11)).onAppear { store.generations = GenerationRecord.saved() }
    }
    private func resetOptions() {
        guard let model else { return }
        ratio = model.ratios.contains("16:9") ? "16:9" : model.ratios.first ?? ""
        resolution = model.resolutions.first ?? ""; duration = model.supported_durations?.first ?? 4
    }
    private func loadModels() {
        guard !loading else { return }; loading = true
        let requestedKind = kind
        Task {
            defer { loading = false }
            do {
                models = try await MediaGeneration.catalog(requestedKind)
                let preferred = requestedKind == .image ? "google/gemini-2.5-flash-image" : "google/veo-3.1"
                modelID = models.first { $0.id == preferred }?.id ?? models.first?.id ?? ""; resetOptions()
            } catch { store.error = error.localizedDescription }
        }
    }
}

extension EditorStore {
    func generateMedia(kind: GenerationKind, model: GenerationModel, prompt: String, ratio: String, resolution: String, duration: Int) {
        guard !isGenerating else { return }
        guard let key = OpenRouterKeychain.read() else { error = "Connect OpenRouter above first."; return }
        do {
            if kind == .image { _ = try LocalTools.require("ffmpeg") }
            let request = try MediaGeneration.request(kind: kind, model: model, prompt: prompt, ratio: ratio, resolution: resolution, duration: duration, apiKey: key)
            let record = GenerationRecord(kind: kind, model: model.id, prompt: prompt)
            try record.save(); generations = GenerationRecord.saved(); isGenerating = true; generationMessage = "Generating \(kind.rawValue)…"
            generationTask = Task {
                do {
                    if kind == .image { _ = try await MediaGeneration.image(request: request, record: record) }
                    else {
                        let submitted = try await MediaGeneration.submitVideo(request: request, record: record)
                        generations = GenerationRecord.saved()
                        _ = try await MediaGeneration.pollVideo(submitted, apiKey: key) { [weak self] state in Task { @MainActor in self?.generationMessage = "Video · \(state)" } }
                    }
                    status = "Generated media is ready. Add it to the library from the AI panel."
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                generations = GenerationRecord.saved(); isGenerating = false
            }
        } catch { self.error = error.localizedDescription }
    }
    func resumeGeneration(_ record: GenerationRecord) {
        guard !isGenerating else { return }
        guard let key = OpenRouterKeychain.read() else { error = "Connect OpenRouter above first."; return }
        isGenerating = true; generationMessage = "Resuming video job…"
        generationTask = Task {
            do { _ = try await MediaGeneration.pollVideo(record, apiKey: key) { [weak self] state in Task { @MainActor in self?.generationMessage = "Video · \(state)" } }; status = "Generated video is ready." }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            generations = GenerationRecord.saved(); isGenerating = false
        }
    }
    func importGenerated(_ record: GenerationRecord) {
        guard let url = record.assetURL, !isImporting else { return }
        if record.kind == .video { importURLs([url]); return }
        isImporting = true
        Task {
            do { let video = try await StillImageClip.make(from: url, directory: record.directory); isImporting = false; importURLs([video]) }
            catch { isImporting = false; self.error = error.localizedDescription }
        }
    }
}

private struct GeneratedAssetPreview: View {
    let url: URL
    @State private var preview: NSImage?
    var body: some View {
        Group { if let preview { Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 130) } }
            .task(id: url) { preview = NSImage(contentsOf: url) }
    }
}
