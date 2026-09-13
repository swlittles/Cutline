import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import CutlineCore

extension EditorStore {
    var transcriptionMedia: MediaItem? {
        project.media.first { $0.id == transcriptionMediaID } ?? selectedMedia ?? project.media.first
    }
    var recoveryURL: URL { LocalTools.support.appendingPathComponent("Recovery/autosave.cutline") }
    func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = project, url = recoveryURL
        autosaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try snapshot.write(to: url)
            } catch is CancellationError {} catch { status = "Autosave failed: \(error.localizedDescription)" }
        }
    }
    func recoverAutosave() {
        guard !isImporting, !isExporting, confirmDiscard() else { return }
        do {
            let recovered = try EditProject.read(from: recoveryURL)
            resetJobs(); project = recovered; savedProject = EditProject(); projectURL = nil
            undoStack = []; redoStack = []; selectedClipID = nil; playhead = 0; rebuild()
            status = "Recovered unsaved edits. Save this project to keep them."
        } catch { self.error = error.localizedDescription }
    }
    func resetJobs() {
        projectEpoch = UUID(); transcriptionTask?.cancel(); assistantTask?.cancel(); autosaveTask?.cancel()
        isTranscribing = false; isThinking = false; aiProposal = nil; aiSnapshot = nil; transcriptionMediaID = nil
    }
    func downloadSpeechModel() {
        guard !isDownloadingModel else { return }
        let model = speechModel; isDownloadingModel = true
        downloadTask = Task {
            do { try await model.download(); status = "Local speech model installed and verified." }
            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            isDownloadingModel = false
        }
    }
    func transcribe() {
        guard let media = transcriptionMedia, !isTranscribing else { return }
        let epoch = projectEpoch, model = speechModel, audioTrack = transcriptionAudioTrack, language = transcriptionLanguage, vocabulary = transcriptionVocabulary
        isTranscribing = true; transcriptionProgress = 0; transcriptionMessage = "Preparing your recording…"
        transcriptionTask = Task {
            do {
                let result = try await LocalTranscription.transcribe(media: media, audioTrack: audioTrack, model: model, language: language, vocabulary: vocabulary) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.projectEpoch == epoch else { return }
                        self.transcriptionProgress = progress.fraction; self.transcriptionMessage = progress.message
                    }
                }
                guard projectEpoch == epoch, project.media.contains(where: { $0.id == media.id && $0.url == media.url }) else { return }
                commit { project in
                    if project.transcripts == nil { project.transcripts = [] }
                    project.transcripts?.removeAll { $0.mediaID == media.id }
                    project.transcripts?.append(result)
                    project.generateCaptions(from: result)
                }
                status = result.segments.isEmpty ? "No speech was detected on that audio track." : "Created \(result.segments.count) captions locally. Review the wording and timing."
            } catch {
                guard projectEpoch == epoch else { return }
                if Task.isCancelled { transcriptionMessage = "Transcription cancelled." } else { self.error = error.localizedDescription; transcriptionMessage = "Transcription failed." }
            }
            if projectEpoch == epoch { isTranscribing = false }
        }
    }
    func editCaption(_ id: UUID, text: String, start: Double? = nil, end: Double? = nil) {
        guard let cue = project.captionTrack?.cues.first(where: { $0.id == id }), let clip = project.clips.first(where: { $0.id == cue.clipID }) else { return }
        let position = project.start(of: clip.id)
        let low = start.map { clip.sourceIn + ($0 - position) * clip.speed } ?? cue.sourceStart
        let high = end.map { clip.sourceIn + ($0 - position) * clip.speed } ?? cue.sourceEnd
        guard low.isFinite, high.isFinite, low >= 0, high > low, high <= (project.media.first { $0.id == clip.mediaID }?.duration ?? 0), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1000 else { error = "Enter valid caption text and timing within this source."; return }
        commit { project in
            guard let index = project.captionTrack?.cues.firstIndex(where: { $0.id == id }) else { return }
            project.captionTrack?.cues[index].text = text
            project.captionTrack?.cues[index].sourceStart = low; project.captionTrack?.cues[index].sourceEnd = high
        }
    }
    func cutRanges(_ ranges: [TimelineRange]) {
        do { var next = project; try next.removeTimelineRanges(ranges); commit { $0 = next }; status = "Transcript cut applied to video, captions, overlays, and audio. Undo restores it." }
        catch { self.error = error.localizedDescription }
    }
    func addCaption() {
        guard let clip = project.clips.first(where: { let start = project.start(of: $0.id); return playhead >= start && playhead < start + $0.duration }) else { return }
        let start = clip.sourceIn + (playhead - project.start(of: clip.id)) * clip.speed
        commit { project in
            if project.captionTrack == nil { project.captionTrack = CaptionTrack() }
            project.captionTrack?.cues.append(CaptionCue(clipID: clip.id, sourceStart: start, sourceEnd: min(start + 2 * clip.speed, clip.sourceOut), text: "Your caption"))
        }
    }
    func importSubtitles() {
        guard !project.clips.isEmpty else { error = "Add video to the timeline before importing captions."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let segments = try SubtitleFile.decode(String(contentsOf: url, encoding: .utf8)); commit { $0.importCaptions(segments) } }
        catch { self.error = error.localizedDescription }
    }
    func exportSubtitles(vtt: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + (vtt ? ".vtt" : ".srt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SubtitleFile.encode(project.projectedCaptions(), vtt: vtt).write(to: url, atomically: true, encoding: .utf8); status = "Subtitles exported." }
        catch { self.error = error.localizedDescription }
    }
    func requestAI() {
        guard !isThinking else { return }
        guard let key = OpenRouterKeychain.read() else { error = "Save your OpenRouter API key in the AI panel first."; return }
        let snapshot = project, epoch = projectEpoch, prompt = aiPrompt, model = aiModel
        aiSnapshot = snapshot; aiProposal = nil; isThinking = true
        UserDefaults.standard.set(model, forKey: "openrouter-model")
        assistantTask = Task {
            do {
                let proposal = try await EditingAssistant.request(project: snapshot, prompt: prompt, model: model, apiKey: key) { [weak self] index, count in
                    Task { @MainActor in self?.aiProgress = "Reading transcript section \(index) of \(count)…" }
                }
                guard projectEpoch == epoch else { return }
                aiProposal = proposal; status = "AI suggestions are ready for review."
            } catch {
                guard projectEpoch == epoch else { return }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if projectEpoch == epoch { isThinking = false }
        }
    }
    func applyHighlight(_ highlight: AIHighlight) {
        guard project == aiSnapshot else { error = "The timeline changed since these suggestions were generated. Ask the assistant again."; return }
        do {
            var next = project; try next.keepTimelineRange(start: highlight.start, end: highlight.end)
            next.name = highlight.title
            commit { $0 = next }; seek(0); aiProposal = nil; aiSnapshot = nil
            status = "Created highlight. Undo restores the full timeline."
        } catch { self.error = error.localizedDescription }
    }
    func applyCaptionEdits() {
        guard project == aiSnapshot, let proposal = aiProposal else { error = "The project changed. Generate a fresh suggestion first."; return }
        let edits = Dictionary(uniqueKeysWithValues: proposal.captionEdits.map { ($0.id, $0.text) })
        commit { project in
            guard project.captionTrack != nil else { return }
            for index in project.captionTrack!.cues.indices {
                if let text = edits[project.captionTrack!.cues[index].id.uuidString] { project.captionTrack!.cues[index].text = text }
            }
        }
        aiProposal = nil; aiSnapshot = nil
    }
    func updateAdjustments(_ id: UUID, _ change: (inout ClipAdjustments) -> Void) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var adjustments = project.clips[index].adjustments ?? ClipAdjustments(); change(&adjustments)
        var next = project; next.clips[index].adjustments = adjustments
        do { try next.validate(); commit { $0 = next } } catch { self.error = error.localizedDescription }
    }
    func moveClip(_ id: UUID, before target: UUID) {
        guard id != target, let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        commit { project in
            let clip = project.clips.remove(at: index)
            let destination = project.clips.firstIndex(where: { $0.id == target }) ?? project.clips.count
            project.clips.insert(clip, at: destination)
        }
    }
    func addOverlay(_ media: MediaItem) {
        guard project.duration > playhead else { error = "Place the playhead within your timeline first."; return }
        let overlay = OverlayClip(mediaID: media.id, start: playhead, duration: min(media.duration, project.duration - playhead))
        commit { if $0.overlays == nil { $0.overlays = [] }; $0.overlays?.append(overlay) }; workspace = "Layers"
    }
    func addAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertAudio(url)
    }
    func insertAudio(_ url: URL) {
        let epoch = projectEpoch, position = playhead
        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw EditError.invalid("No audio track found.") }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0, projectEpoch == epoch else { return }
                commit { if $0.music == nil { $0.music = [] }; $0.music?.append(AudioClip(url: url, start: position, duration: duration)) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func addMarker() {
        guard let clip = project.clips.first(where: { project.start(of: $0.id) <= playhead && project.start(of: $0.id) + $0.duration > playhead }) else { return }
        let marker = HighlightMarker(clipID: clip.id, sourceTime: clip.sourceIn + (playhead - project.start(of: clip.id)) * clip.speed, label: "Highlight \((project.markers?.count ?? 0) + 1)")
        commit { if $0.markers == nil { $0.markers = [] }; $0.markers?.append(marker) }
    }
    func relink(_ item: MediaItem) {
        let panel = NSOpenPanel(); panel.message = "Locate the source for \(item.name)"; panel.allowedContentTypes = [.movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let epoch = projectEpoch
        Task {
            do {
                let replacement = try await CompositionEngine.inspect(url)
                let required = project.clips.filter { $0.mediaID == item.id }.map(\.sourceOut).max() ?? 0
                guard replacement.duration >= required else { throw EditError.invalid("The replacement is shorter than the ranges used by this project.") }
                guard projectEpoch == epoch, let index = project.media.firstIndex(where: { $0.id == item.id }) else { return }
                commit { $0.media[index].url = url; $0.media[index].duration = replacement.duration; $0.media[index].audioTrackCount = replacement.audioTrackCount }
                status = "Relinked \(item.name)."
            } catch { self.error = error.localizedDescription }
        }
    }
}
