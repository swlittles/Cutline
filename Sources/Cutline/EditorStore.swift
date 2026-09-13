import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CutlineCore

@MainActor
final class EditorStore: ObservableObject {
    @Published var visibleCaptions: [ProjectedCaption] = []
    @Published var aiSectionCount = 0
    @Published var workspace = "Media"
    @Published var clipSettings = AutoClipSettings()
    @Published var clipMediaID: UUID? { didSet { if clipMediaID != oldValue { clipSettings.hudCalibrated = false } } }
    @Published var clipReport: AutoClipReport?
    @Published var selectedAutoClips = Set<String>()
    @Published var isScanningClips = false
    @Published var isExportingClips = false
    @Published var clipProgress = 0.0
    @Published var clipMessage = "Choose a recording to find clips locally."
    @Published var clipOutput: URL?
    var clipTask: Task<Void, Never>?
    var clipExportTask: Task<Void, Never>?
    var clipJobID = UUID()
    var clipProfiles: [String: AutoClipSettings] = [:]
    @Published var project = EditProject()
    @Published var isTranscribing = false
    @Published var transcriptionProgress = 0.0
    @Published var transcriptionMessage = "Ready for local transcription"
    @Published var transcriptionMediaID: UUID?
    @Published var transcriptionAudioTrack = 0
    @Published var transcriptionLanguage = "auto"
    @Published var transcriptionVocabulary = ""
    @Published var speechModel: WhisperModel = .base
    @Published var isDownloadingModel = false
    @Published var isThinking = false
    @Published var aiProgress = ""
    @Published var aiProposal: AIEditProposal?
    @Published var aiModel = UserDefaults.standard.string(forKey: "openrouter-model") ?? EditingAssistant.defaultModel
    @Published var aiPrompt = "Find the best gaming highlights for short clips. Include the setup and reaction, and suggest engaging titles."
    @Published var isGenerating = false
    @Published var generationMessage = ""
    @Published var generations: [GenerationRecord] = []
    var generationTask: Task<Void, Never>?
    @Published var exportProgress = 0.0
    var transcriptionTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var assistantTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var autosaveTask: Task<Void, Never>?
    var aiSnapshot: EditProject?
    var projectEpoch = UUID()
    @Published var selectedClipID: UUID?
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var playhead = 0.0
    @Published var isPlaying = false
    @Published var isBuilding = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var error: String?
    @Published var status = "Your next highlight starts here."
    @Published var projectURL: URL?
    @Published var savedProject = EditProject()
    @Published var undoStack: [EditProject] = []
    @Published var redoStack: [EditProject] = []
    let player = AVPlayer()
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var revision = UUID()
    private var render: RenderComposition?
    var dirty: Bool { project != savedProject }
    var selectedClip: TimelineClip? { project.clips.first { $0.id == selectedClipID } }
    var selectedMedia: MediaItem? { project.media.first { $0.id == selectedClip?.mediaID } }
    var canExport: Bool { render != nil && !isBuilding && !isExporting && !project.clips.isEmpty }

    init() {
        if let data = try? Data(contentsOf: LocalTools.support.appendingPathComponent("autoclip-profiles.json")), let profiles = try? JSONDecoder().decode([String: AutoClipSettings].self, from: data) { clipProfiles = profiles }
        if let saved = clipProfiles["last"] { clipSettings = saved }; clipSettings.hudCalibrated = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                // The observer's timestamp may be stale by the time this task runs.
                // Paused playback and explicit seeks own the displayed playhead.
                let current = self.player.currentTime().seconds
                self.playhead = current.isFinite ? current : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func commit(_ change: (inout EditProject) -> Void) {
        let old = project
        change(&project)
        guard old != project else { return }
        undoStack.append(old)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        scheduleAutosave()
        rebuild()
    }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project); project = previous; scheduleAutosave(); rebuild()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project); project = next; scheduleAutosave(); rebuild()
    }
    func rebuild() {
        visibleCaptions = project.projectedCaptions()
        aiSectionCount = EditingAssistant.transcriptChunks(for: project).count
        rebuildTask?.cancel(); player.pause(); isPlaying = false
        let token = UUID(); revision = token
        let snapshot = project
        let position = min(playhead, project.duration)
        render = nil
        guard !snapshot.clips.isEmpty else {
            player.replaceCurrentItem(with: nil); playhead = 0; isBuilding = false; return
        }
        isBuilding = true
        rebuildTask = Task {
            do {
                let result = try await CompositionEngine.build(snapshot)
                guard !Task.isCancelled, revision == token else { return }
                render = result; player.replaceCurrentItem(with: result.playerItem())
                seek(position); isBuilding = false
            } catch {
                guard !Task.isCancelled, revision == token else { return }
                player.replaceCurrentItem(with: nil)
                isBuilding = false; self.error = error.localizedDescription
            }
        }
    }
    func importMedia() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Import gameplay, facecam, video recordings, or still images."
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importURLs(panel.urls) }
        }
    }
    func importURLs(_ urls: [URL]) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            var imported: [MediaItem] = []; var failures: [String] = []
            for url in urls {
                guard !project.media.contains(where: { $0.url == url }), !imported.contains(where: { $0.url == url }) else { continue }
                do {
                    let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                    let video = isImage ? try await StillImageClip.make(from: url) : url
                    var item = try await CompositionEngine.inspect(video)
                    if isImage { item.displayName = url.deletingPathExtension().lastPathComponent }
                    imported.append(item)
                    await loadThumbnail(item)
                } catch { failures.append(error.localizedDescription) }
            }
            if !imported.isEmpty {
                commit { $0.media.append(contentsOf: imported) }
                status = "Imported \(imported.count) recording\(imported.count == 1 ? "" : "s"). Add one to your timeline."
            }
            isImporting = false
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    private func loadThumbnail(_ media: MediaItem) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        if let result = try? await generator.image(at: CMTime(seconds: min(1, media.duration / 2), preferredTimescale: 600)) {
            thumbnails[media.id] = NSImage(cgImage: result.image, size: .zero)
        }
    }
    func add(_ media: MediaItem) {
        let clip = TimelineClip(mediaID: media.id, sourceOut: media.duration)
        commit { project in
            project.clips.append(clip)
            if let transcript = project.transcripts?.first(where: { $0.mediaID == media.id }) {
                if project.captionTrack == nil { project.captionTrack = CaptionTrack() }
                project.captionTrack?.cues += transcript.segments.map { CaptionCue(clipID: clip.id, sourceStart: $0.start, sourceEnd: $0.end, text: $0.text) }
            }
        }; selectedClipID = clip.id
        status = "Added \(media.name) to the timeline."
    }
    func select(_ clip: TimelineClip) { selectedClipID = clip.id; seek(project.start(of: clip.id)) }
    func seek(_ seconds: Double) {
        let target = max(0, min(seconds, project.duration))
        playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlayback() {
        guard !isBuilding, render != nil else { return }
        if player.rate != 0 {
            player.pause(); isPlaying = false
            let current = player.currentTime().seconds
            if current.isFinite { playhead = current }
        }
        else {
            if playhead >= project.duration - 0.05 { seek(0) }
            player.play(); isPlaying = true
        }
    }
    func split() {
        let time = playhead
        var selection: UUID?
        commit { selection = $0.split(at: time) }
        if let selection { selectedClipID = selection; status = "Split at \(timecode(time))." }
    }
    func deleteSelected() {
        guard let id = selectedClipID else { return }
        commit { $0.removeClip(id) }; selectedClipID = nil
    }
    func duplicate() {
        guard let clip = selectedClip, let index = project.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var copy = clip; copy.id = UUID()
        commit { $0.clips.insert(copy, at: index + 1); $0.copyCaptions(from: clip.id, to: copy.id) }; selectedClipID = copy.id
    }
    func moveSelected(_ direction: Int) {
        guard let index = project.clips.firstIndex(where: { $0.id == selectedClipID }), project.clips.indices.contains(index + direction) else { return }
        commit { $0.clips.swapAt(index, index + direction) }
    }
    func updateClip(_ id: UUID, sourceIn: Double? = nil, sourceOut: Double? = nil, volume: Double? = nil) {
        guard [sourceIn, sourceOut, volume].compactMap({ $0 }).allSatisfy({ $0.isFinite }) else { return }
        guard let index = project.clips.firstIndex(where: { $0.id == id }), let media = project.media.first(where: { $0.id == project.clips[index].mediaID }) else { return }
        commit { project in
            if let sourceIn { project.clips[index].sourceIn = max(0, min(sourceIn, project.clips[index].sourceOut - 0.1)) }
            if let sourceOut { project.clips[index].sourceOut = min(media.duration, max(sourceOut, project.clips[index].sourceIn + 0.1)) }
            if let volume { project.clips[index].volume = max(0, min(2, volume)) }
        }
    }
    func trimToPlayhead(start: Bool) {
        guard let clip = selectedClip else { return }
        let source = clip.sourceIn + (playhead - project.start(of: clip.id)) * clip.speed
        guard source >= clip.sourceIn, source <= clip.sourceOut else { return }
        updateClip(clip.id, sourceIn: start ? source : nil, sourceOut: start ? nil : source)
    }
    func confirmDiscard() -> Bool {
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to this project?"
        alert.informativeText = "Your source recordings are never modified. Unsaved timeline edits will be lost."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func newProject() {
        guard !isImporting, !isExporting, confirmDiscard() else { return }
        resetJobs()
        project = EditProject(); status = "Your next highlight starts here."; savedProject = project; projectURL = nil
        selectedClipID = nil; thumbnails = [:]; undoStack = []; redoStack = []; rebuild()
    }
    @discardableResult func save(as: Bool = false) -> Bool {
        var destination = projectURL
        if destination == nil || `as` {
            let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + ".cutline"
            panel.allowedContentTypes = [.cutlineProject, .json]
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let url = destination else { return false }
        do {
            var snapshot = project; snapshot.name = url.deletingPathExtension().lastPathComponent
            try snapshot.write(to: url)
            project = snapshot; projectURL = url; savedProject = snapshot
            autosaveTask?.cancel()
            try? FileManager.default.removeItem(at: recoveryURL)
            status = "Project saved."; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func openProject() {
        guard !isImporting, !isExporting, confirmDiscard() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.cutlineProject, .json]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.loadProject(url) }
        }
    }
    func loadProject(_ url: URL) {
        do {
            let loaded = try EditProject.read(from: url)
            resetJobs()
            project = loaded; savedProject = loaded; projectURL = url
            undoStack = []; redoStack = []; selectedClipID = nil; thumbnails = [:]; playhead = 0
            rebuild(); status = "Opened \(loaded.name)."
            Task { for item in loaded.media { await loadThumbnail(item) } }
        } catch { self.error = error.localizedDescription }
    }
    func exportVideo() {
        guard canExport, let render else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = project.name + ".mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let sources = project.media.map(\.url) + (project.music ?? []).map(\.url)
        isExporting = true; exportProgress = 0; status = "Exporting your edit…"
        exportTask = Task {
            do {
                try await ExportDestination.write(to: destination, protecting: sources) { temporary in
                    try await CompositionEngine.export(render, to: temporary) { [weak self] value in Task { @MainActor in self?.exportProgress = value } }
                }
                status = "Export complete: \(destination.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                if error is CancellationError { status = "Export cancelled." } else { self.error = error.localizedDescription; status = "Export failed. Your existing files are safe." }
            }
            isExporting = false
        }
    }
}

@MainActor extension EditorStore {
    /// Menu key equivalents run before the field editor on some macOS versions.
    /// Preserve normal Delete behavior while typing instead of deleting a timeline clip.
    func deleteFromKeyboard(responder: NSResponder? = NSApp.keyWindow?.firstResponder) {
        if let editor = responder as? NSTextView, editor.isEditable {
            editor.deleteBackward(nil)
        } else {
            deleteSelected()
        }
    }
}
