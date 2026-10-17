import SwiftUI
import AVFoundation
import CutlineCore

enum AppMode { case home, clipper, editor }

/// Video → Layout → Pick clips → Export. Finding moments runs in the background and
/// fills the Pick clips list; it is not a step the user has to manage.
enum ClipStep: Int, CaseIterable, Identifiable, Comparable {
    case importVOD, setup, review, export
    var id: Int { rawValue }
    var title: String { ["Video", "Layout", "Pick clips", "Export"][rawValue] }
    static func < (a: ClipStep, b: ClipStep) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Session and navigation
extension EditorStore {
    var clipMedia: MediaItem? { project.media.first { $0.id == clipMediaID } ?? selectedMedia ?? project.media.first }
    var clipSourceUnchanged: Bool { guard let report = clipReport else { return false }; return project.media.contains { $0.sameSource(as: report.media) } }
    var review: ClipReview? { guard let media = clipMedia, project.clipReview?.mediaID == media.id else { return nil }; return project.clipReview }
    var moments: [AutoClipCandidate] { clipReport?.candidates ?? [] }
    func applied(_ candidate: AutoClipCandidate) -> AutoClipCandidate { review?.applied(candidate) ?? candidate }
    func decision(_ id: String) -> ClipDecision { review?.decision(id) ?? .undecided }
    var keptMoments: [AutoClipCandidate] { moments.filter { decision($0.id) == .kept }.map(applied) }
    var focusedCandidate: AutoClipCandidate? { moments.first { $0.id == focusedMoment } }
    var audioRoles: [AudioRole] { clipMedia?.audioRoles ?? AudioRole.guess(count: clipMedia?.audioTrackCount ?? 1, names: clipMedia.flatMap { trackNames[$0.id] } ?? []) }
    var routes: AudioRoutes { AudioRoutes(audioRoles) }
    var brandingReady: Bool { (try? creatorProfile.validate()) != nil }
    var setupComplete: Bool { clipMedia?.shortFraming?.confirmed == true && brandingReady }

    func canEnter(_ step: ClipStep) -> Bool {
        switch step {
        case .importVOD: return true
        case .setup: return clipMedia != nil
        case .review: return clipMedia != nil && setupComplete
        case .export: return canEnter(.review) && !keptMoments.isEmpty
        }
    }
    func goTo(_ step: ClipStep) {
        guard canEnter(step) else { return }
        clipStep = step; stopAudition()
        if step == .review { ensureFocus(); refreshReviewPreview() } else { reviewPlayer.pause() }
    }
    func showHome() { reviewPlayer.pause(); stopAudition(); refreshRecoverableSession(); mode = .home }
    func showEditor() { reviewPlayer.pause(); stopAudition(); mode = .editor }
    /// Starts a fresh session. An empty project is reused rather than prompting.
    func startClipping() {
        guard !isImporting, !isExporting, !isExportingClips else { return }
        if !(project.media.isEmpty && project.clips.isEmpty) {
            guard confirmDiscard() else { return }
            resetJobs(); project = EditProject(workflow: .mobileShort); savedProject = project; projectURL = nil
            selectedClipID = nil; thumbnails = [:]; undoStack = []; redoStack = []; rebuild()
        }
        parkedSession = nil
        mode = .clipper; clipStep = .importVOD; status = "Choose a stream recording to start."
    }
    /// The session to offer on Home: in memory, parked behind an open clip, or autosaved.
    var continuableSessionName: String? {
        if let parked = parkedSession { return parked.project.clipReview.flatMap { review in parked.project.media.first { $0.id == review.mediaID }?.name } }
        if let review = project.clipReview, let media = project.media.first(where: { $0.id == review.mediaID }) { return media.name }
        return recoverableSession?.name
    }
    var continuableSessionReview: ClipReview? { parkedSession?.project.clipReview ?? project.clipReview ?? recoverableSession?.review }
    func continueClipping() {
        if parkedSession != nil { returnToClips(); return }
        if project.clipReview == nil, recoverableSession != nil { loadRecoverableSession(); return }
        mode = .clipper
        if let review = project.clipReview, clipMediaID != review.mediaID { chooseVOD(review.mediaID) }
    }
    /// Clip a recording from the editor's media library, keeping the current project.
    func clipRecording(_ media: MediaItem) {
        chooseVOD(media.id); mode = .clipper; clipStep = setupComplete ? .review : .setup
    }
    /// Saved sessions reopen where they left off; everything else opens in the editor.
    func resumeSessionOrEdit() {
        guard let review = project.clipReview, project.clips.isEmpty, project.media.contains(where: { $0.id == review.mediaID }) else { mode = .editor; return }
        mode = .clipper; chooseVOD(review.mediaID)
        clipStep = !setupComplete ? .setup : .review
    }
}

// MARK: - Import and setup
extension EditorStore {
    func importVOD(_ urls: [URL]) {
        importURLs(urls) { [weak self] imported in
            guard let self, let item = imported.last else { return }
            self.chooseVOD(item.id)
        }
    }
    func chooseVODFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie] + MediaConversion.convertibleTypes
        panel.message = "Choose a stream recording."
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importVOD(panel.urls) }
        }
    }
    /// Selecting a recording immediately starts measuring it in the background, so the
    /// scan runs while the user checks framing and audio.
    func chooseVOD(_ id: UUID) {
        guard let media = project.media.first(where: { $0.id == id }) else { return }
        if clipMediaID != id || clipAnalysis?.media.sameSource(as: media) != true {
            clipJobID = UUID(); clipTask?.cancel(); isScanningClips = false; clipInflight = nil
            clipAnalysis = ClipAnalysisCache.load(for: media); clipReport = nil; focusedMoment = nil; clipOutput = nil
        }
        clipMediaID = id
        if project.clipReview?.mediaID != id { commit { $0.clipReview = ClipReview(mediaID: id) } }
        if trackNames[id] == nil { Task { trackNames[id] = await AudioTrackNames.load(media.url); if clipMediaID == id { adoptRoutes() } } }
        adoptRoutes()
        beginAnalysis()
    }
    /// Detection, export and caption tracks follow the recording's audio roles.
    func adoptRoutes() {
        guard let media = clipMedia else { return }
        let routes = routes
        var next = clipSettings
        next.audioTrack = routes.detect; next.outputAudioTrack = routes.export[0]; next.outputAudioTracks = routes.export
        if (media.audioTrackCount ?? 1) == 0 { next.audioEnabled = false }
        if next != clipSettings { clipSettings = next }
        transcriptionAudioTrack = routes.speech
    }
    var lastScenePreset: ScenePreset? {
        let id = UserDefaults.standard.string(forKey: "last-scene-preset").flatMap(UUID.init(uuidString:))
        return scenePresets.first { $0.id == id }
    }
    func applyScenePreset(_ preset: ScenePreset) {
        guard let media = clipMedia, let index = project.media.firstIndex(where: { $0.id == media.id }) else { return }
        commit { preset.apply(to: &$0.media[index]) }
        if clipSettings.game != preset.game { selectClipGame(preset.game) }
        clipSettings.motionRegion = preset.motionRegion
        adoptRoutes()
        UserDefaults.standard.set(preset.id.uuidString, forKey: "last-scene-preset")
    }
    func saveScenePreset(named name: String, framing: ShortFraming, roles: [AudioRole], game: ClipGame) throws {
        var preset = ScenePreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), framing: framing, audioRoles: roles, game: game, motionRegion: clipSettings.motionRegion)
        var presets = scenePresets
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) { preset.id = presets[index].id; presets[index] = preset }
        else { presets.append(preset) }
        try ScenePresetStore.save(presets); scenePresets = presets
        UserDefaults.standard.set(preset.id.uuidString, forKey: "last-scene-preset")
    }
    func deleteScenePreset(_ id: UUID) {
        let presets = scenePresets.filter { $0.id != id }
        do { try ScenePresetStore.save(presets); scenePresets = presets } catch { self.error = error.localizedDescription }
    }
    /// Continue from setup: confirms crops, saves roles, branding and an optional preset.
    @discardableResult func completeSetup(framing: ShortFraming, roles: [AudioRole], game: ClipGame, branding: ShortBranding?, presetName: String?) -> Bool {
        guard let media = clipMedia, let index = project.media.firstIndex(where: { $0.id == media.id }) else { return false }
        do {
            try framing.validate()
            if let branding { try branding.validate(); try saveCreatorProfile(branding) }
            try creatorProfile.validate()
            var confirmed = framing; confirmed.confirmed = true
            if game != clipSettings.game { selectClipGame(game) }
            commit { $0.media[index].shortFraming = confirmed; $0.media[index].audioRoles = roles }
            adoptRoutes()
            if let name = presetName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                try saveScenePreset(named: name, framing: confirmed, roles: roles, game: game)
            }
            clipStep = .review
            beginAnalysis()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func selectClipGame(_ game: ClipGame) {
        clipProfiles[clipSettings.game.rawValue] = clipSettings
        var next = clipProfiles[game.rawValue] ?? .preset(game); next.hudCalibrated = false
        next.audioTrack = clipSettings.audioTrack; next.outputAudioTrack = clipSettings.outputAudioTrack; next.outputAudioTracks = clipSettings.outputAudioTracks
        clipSettings = next
    }
}

// MARK: - Measuring and finding moments
extension EditorStore {
    func resetAutoClips() {
        clipJobID = UUID(); clipTask?.cancel(); clipExportTask?.cancel(); clipEvaluateTask?.cancel(); clipSettingsTask?.cancel(); clipCaptionTask?.cancel(); reviewPreviewTask?.cancel()
        isScanningClips = false; isExportingClips = false; isTranscribingClips = false; clipInflight = nil
        clipAnalysis = nil; clipReport = nil; focusedMoment = nil; clipMediaID = nil; clipOutput = nil; clipSettings.hudCalibrated = false
        reviewPreviewProject = nil; reviewPreviewID = nil; reviewPlayer.replaceCurrentItem(with: nil); stopAudition()
    }
    /// Explicit request from the UI. Invalid settings are reported instead of silently skipped.
    func scanAutoClips() { beginAnalysis(explicit: true) }
    func persistClipProfiles() throws {
        clipProfiles[clipSettings.game.rawValue] = clipSettings; clipProfiles["last"] = clipSettings
        let url = LocalTools.support.appendingPathComponent("autoclip-profiles.json")
        try FileManager.default.createDirectory(at: LocalTools.support, withIntermediateDirectories: true)
        try JSONEncoder().encode(clipProfiles).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Measures only what the current settings still need. Thresholds, timing and track
    /// changes re-evaluate retained measurements without touching the recording.
    func beginAnalysis(explicit: Bool = false) {
        guard let media = clipMedia else { return }
        do { try clipSettings.validate() } catch {
            if explicit { self.error = error.localizedDescription } else { clipMessage = error.localizedDescription }
            return
        }
        do { try persistClipProfiles() } catch { self.error = error.localizedDescription; return }
        let key = ClipVisualKey(clipSettings)
        if isScanningClips, let inflight = clipInflight, inflight.serves(key) { return }
        if let analysis = clipAnalysis, analysis.media.sameSource(as: media), analysis.covers(clipSettings) { evaluateMoments(); return }
        let settings = clipSettings, token = UUID(); clipJobID = token
        clipTask?.cancel()
        let existing = clipAnalysis?.media.sameSource(as: media) == true ? clipAnalysis : nil
        isScanningClips = true; clipInflight = key; clipProgress = 0; clipMessage = "Finding the best moments…"; clipOutput = nil
        clipTask = Task {
            do {
                let analysis = try await ClipAnalyzer.analyze(media: media, settings: settings, existing: existing, progress: { [weak self] update in
                    Task { @MainActor in guard let self, self.clipJobID == token, self.isScanningClips else { return }; self.clipProgress = update.fraction; self.clipMessage = update.message }
                }, audioReady: { [weak self] audio in
                    Task { @MainActor in
                        guard let self, self.clipJobID == token else { return }
                        var partial = self.clipAnalysis.flatMap { $0.media.sameSource(as: media) ? $0 : nil } ?? ClipAnalysis(media: media)
                        partial.audioTracks = audio; self.clipAnalysis = partial
                    }
                })
                try Task.checkCancellation()
                guard clipJobID == token else { return }
                guard project.media.contains(where: { $0.sameSource(as: media) }) else { throw EditError.invalid("The source changed while scanning. Scan the recording again.") }
                clipAnalysis = analysis
                Task.detached(priority: .utility) { try? ClipAnalysisCache.save(analysis) }
                await evaluateNow()
            } catch {
                guard clipJobID == token else { return }
                clipMessage = Task.isCancelled ? "Scan cancelled." : "Scan failed."
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if clipJobID == token { isScanningClips = false; clipInflight = nil }
        }
    }
    func clipSettingsChanged() {
        clipSettingsTask?.cancel()
        guard clipMedia != nil, clipAnalysis != nil || isScanningClips else { return }
        clipSettingsTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            beginAnalysis()
        }
    }
    func momentMarkers(for media: MediaItem) -> [ClipEvidence] {
        let timeline = (project.markers ?? []).filter { marker in project.clips.contains { $0.id == marker.clipID && $0.mediaID == media.id } }.map { ClipEvidence(time: $0.sourceTime, signal: .marker, detail: $0.label) }
        let marked = (review?.moments ?? []).map { ClipEvidence(time: $0, signal: .marker, detail: "Marked by you at \(clockTime($0))") }
        return timeline + marked
    }
    func evaluateMoments() {
        clipEvaluateTask?.cancel()
        clipEvaluateTask = Task { await evaluateNow() }
    }
    func evaluateNow() async {
        guard let analysis = clipAnalysis, let media = clipMedia, analysis.media.sameSource(as: media), analysis.covers(clipSettings) else { return }
        let settings = clipSettings, markers = momentMarkers(for: media)
        let result = await Task.detached(priority: .userInitiated) { Result { try analysis.report(settings: settings, markers: markers) } }.value
        guard !Task.isCancelled, clipSettings == settings, clipMedia?.sameSource(as: media) == true else { return }
        switch result {
        case .success(let report):
            clipReport = report
            let count = report.candidates.count
            clipMessage = count == 0 ? "No moments stood out. Slide toward More, or add a moment you remember." : "Found \(count) \(count == 1 ? "moment" : "moments") to review."
            ensureFocus()
            if clipStep == .review { refreshReviewPreview() }
        case .failure(let error):
            clipReport = nil; clipMessage = error.localizedDescription
        }
    }
}

// MARK: - Review
extension EditorStore {
    func updateReview(_ change: (inout ClipReview) -> Void) {
        guard let media = clipMedia else { return }
        commit { project in
            if project.clipReview?.mediaID != media.id { project.clipReview = ClipReview(mediaID: media.id) }
            change(&project.clipReview!)
        }
    }
    func autoClipHook(_ id: String) -> String { project.autoClipHooks?[id] ?? project.shortHook ?? "" }
    func setHook(_ id: String, _ text: String) {
        commit { if $0.autoClipHooks == nil { $0.autoClipHooks = [:] }; $0.autoClipHooks?[id] = text }
    }
    func decide(_ id: String, _ decision: ClipDecision) { updateReview { $0.decide(id, decision) } }
    func suggestedHook(_ candidate: AutoClipCandidate) -> String { HookIdeas.suggestions(for: candidate, game: clipSettings.game).first ?? "Wait for it…" }
    /// A kept clip always ships with a hook. Keeping without one uses the top suggestion,
    /// in the same undo step, so Keep never refuses.
    @discardableResult func keepFocused() -> Bool {
        guard let id = focusedMoment, let candidate = focusedCandidate, let media = clipMedia else { return false }
        let typed = autoClipHook(id).trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion = suggestedHook(candidate)
        commit { project in
            if typed.isEmpty { if project.autoClipHooks == nil { project.autoClipHooks = [:] }; project.autoClipHooks?[id] = suggestion }
            if project.clipReview?.mediaID != media.id { project.clipReview = ClipReview(mediaID: media.id) }
            project.clipReview?.decide(id, .kept)
        }
        status = typed.isEmpty ? "Kept with the hook “\(suggestion)”. Change it any time." : "Kept. \(keptMoments.count) \(keptMoments.count == 1 ? "clip" : "clips") ready to export."
        advanceFocus(); return true
    }
    func skipFocused() { guard let id = focusedMoment else { return }; decide(id, .skipped); advanceFocus() }
    func clearFocusedDecision() { guard let id = focusedMoment else { return }; decide(id, .undecided) }
    func focus(_ id: String) { focusedMoment = id; refreshReviewPreview() }
    func moveFocus(_ delta: Int) {
        guard !moments.isEmpty else { return }
        let index = moments.firstIndex { $0.id == focusedMoment } ?? 0
        focus(moments[max(0, min(moments.count - 1, index + delta))].id)
    }
    /// After a decision, go to the next moment still waiting for one.
    func advanceFocus() {
        guard let index = moments.firstIndex(where: { $0.id == focusedMoment }) else { ensureFocus(); return }
        let order = moments[(index + 1)...] + moments[..<index]
        if let next = order.first(where: { decision($0.id) == .undecided }) { focus(next.id) }
        else if index + 1 < moments.count { focus(moments[index + 1].id) }
    }
    func ensureFocus() {
        guard !moments.contains(where: { $0.id == focusedMoment }) else { return }
        focusedMoment = (moments.first { decision($0.id) == .undecided } ?? moments.first)?.id
    }
    func nudge(start: Bool, by delta: Double) {
        guard let candidate = focusedCandidate else { return }
        let current = applied(candidate)
        setMomentRange(candidate.id, start: start ? current.start + delta : current.start, end: start ? current.end : current.end + delta)
    }
    func setMomentRange(_ id: String, start: Double, end: Double) {
        guard let media = clipMedia else { return }
        updateReview { $0.setRange(id, start: start, end: end, duration: media.duration) }
    }
    func resetMomentRange(_ id: String) { updateReview { $0.ranges[id] = nil; $0.captions[id] = nil } }
    func addMoment(at time: Double) {
        guard let media = clipMedia else { return }
        updateReview { $0.addMoment(time, duration: media.duration) }
        evaluateMoments()
    }
    func removeMoment(_ time: Double) { updateReview { $0.moments.removeAll { $0 == time } }; evaluateMoments() }

    func preparedAutoClip(_ candidate: AutoClipCandidate, report: AutoClipReport) throws -> EditProject {
        var source = report
        source.media = project.media.first { $0.sameSource(as: report.media) } ?? report.media
        let captions = review?.captionsEnabled == true ? review?.captions[candidate.id] : nil
        return try AutoClipBatch.clipProject(applied(candidate), report: source, options: project.options, hook: autoClipHook(candidate.id), captions: captions)
    }
    /// The review preview renders the real short: framing, branding strip, hook and captions.
    func refreshReviewPreview() {
        guard mode == .clipper, clipStep == .review, let candidate = focusedCandidate, let report = clipReport, let prepared = try? preparedAutoClip(candidate, report: report) else {
            if focusedCandidate == nil { reviewPlayer.replaceCurrentItem(with: nil); reviewPreviewProject = nil; reviewPreviewID = nil }
            return
        }
        guard prepared != reviewPreviewProject else { return }
        let sameMoment = reviewPreviewID == candidate.id
        let resume = sameMoment ? reviewPlayer.currentTime() : .zero
        let wasPlaying = reviewPlayer.rate != 0
        reviewPreviewProject = prepared; reviewPreviewID = candidate.id
        reviewPreviewTask?.cancel()
        let branding = creatorProfile
        reviewPreviewTask = Task {
            try? await Task.sleep(nanoseconds: sameMoment ? 350_000_000 : 60_000_000)
            guard !Task.isCancelled else { return }
            do {
                let render = try await CompositionEngine.build(prepared, branding: branding)
                guard !Task.isCancelled else { return }
                let item = render.playerItem()
                if let reviewLoop { NotificationCenter.default.removeObserver(reviewLoop) }
                reviewLoop = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reviewPlayer.seek(to: .zero); self?.reviewPlayer.play() }
                }
                reviewPlayer.replaceCurrentItem(with: item)
                if sameMoment, resume.seconds.isFinite, resume.seconds < prepared.duration { await reviewPlayer.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero) }
                if !sameMoment || wasPlaying { reviewPlayer.play() }
            } catch { if !Task.isCancelled { clipMessage = error.localizedDescription } }
        }
    }
    func toggleReviewPlayback() {
        guard reviewPlayer.currentItem != nil else { return }
        if reviewPlayer.rate != 0 { reviewPlayer.pause() } else { reviewPlayer.play() }
    }
    func installReviewKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let key = ReviewKey(event)
            return MainActor.assumeIsolated { self.handleReviewKey(key) } ? nil : event
        }
    }
    /// Review is keyboard-first. Typing in the hook field is never intercepted, except
    /// Return or Escape, which hand the keyboard back to review.
    func handleReviewKey(_ key: ReviewKey) -> Bool {
        let event = key.event
        guard mode == .clipper, clipStep == .review, let window = event.window, window.attachedSheet == nil, !(window is NSPanel) else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            if [36, 53, 76].contains(event.keyCode) { window.makeFirstResponder(nil); return true }
            return false
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123, 126: moveFocus(-1)
        case 124, 125: moveFocus(1)
        case 49: toggleReviewPlayback()
        case 33: nudge(start: true, by: shift ? 1 : -1)
        case 30: nudge(start: false, by: shift ? -1 : 1)
        case 36, 76: hookFocusRequest += 1
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": keepFocused()
            case "x": skipFocused()
            case "u": clearFocusedDecision()
            case "h": hookFocusRequest += 1
            default: return false
            }
        }
        return true
    }
}

/// Local key monitors run on the main thread; this carries the event into main-actor code.
struct ReviewKey: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}

// MARK: - Audio roles
extension EditorStore {
    /// Plays eight seconds of one embedded track, starting just before its loudest moment.
    func auditionTrack(_ index: Int) {
        guard let media = clipMedia else { return }
        if auditioningTrack == index { stopAudition(); return }
        auditioningTrack = index
        let loudest = clipAnalysis?.audioTracks?[index]?.max { $0.db < $1.db }?.time
        let start = max(0, min(media.duration - 1, (loudest ?? media.duration * 0.25) - 2))
        Task {
            let asset = AVURLAsset(url: media.url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.indices.contains(index), auditioningTrack == index else { return }
            let mix = AVMutableAudioMix()
            mix.inputParameters = tracks.enumerated().map { offset, track in
                let parameters = AVMutableAudioMixInputParameters(track: track); parameters.setVolume(offset == index ? 1 : 0, at: .zero); return parameters
            }
            let item = AVPlayerItem(asset: asset); item.audioMix = mix
            auditionPlayer.replaceCurrentItem(with: item)
            await auditionPlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            guard auditioningTrack == index else { return }
            auditionPlayer.play()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if auditioningTrack == index, auditionPlayer.currentItem === item { stopAudition() }
        }
    }
    func stopAudition() { auditionPlayer.pause(); auditionPlayer.replaceCurrentItem(with: nil); auditioningTrack = nil }
}

// MARK: - Captions and export
extension EditorStore {
    /// Whisper when it is installed with a model, otherwise the on-device macOS recognizer.
    var captionEngine: CaptionEngine {
        let whisperTools = LocalTools.executable("whisper-cli") != nil && LocalTools.executable("ffmpeg") != nil
        if whisperTools && speechModel.installed { return .whisper }
        if AppleSpeech.available { return .apple }
        return whisperTools ? .whisperNeedsModel : .unavailable
    }
    var captionEngineReady: Bool { captionEngine == .whisper || captionEngine == .apple }
    func setClipCaptions(_ enabled: Bool) { updateReview { $0.captionsEnabled = enabled } }
    var pendingCaptionClips: [AutoClipCandidate] { moments.filter { decision($0.id) == .kept && review?.captions[$0.id] == nil }.map(applied) }
    /// Transcribes only the kept ranges, never the whole recording.
    func transcribeKeptClips() {
        guard !isTranscribingClips else { return }
        clipCaptionTask = Task { _ = await transcribePendingClips() }
    }
    /// Returns false when transcription failed or was cancelled.
    func transcribePendingClips() async -> Bool {
        guard !isTranscribingClips, let media = clipMedia else { return false }
        let pending = pendingCaptionClips
        guard !pending.isEmpty else { return true }
        let engine = captionEngine
        guard engine == .whisper || engine == .apple else { error = "Captions aren’t available on this Mac yet."; return false }
        let model = speechModel, language = transcriptionLanguage, vocabulary = transcriptionVocabulary, track = routes.speech, epoch = projectEpoch
        isTranscribingClips = true; clipProgress = 0
        defer { if projectEpoch == epoch { isTranscribingClips = false } }
        do {
            for (index, clip) in pending.enumerated() {
                try Task.checkCancellation()
                clipMessage = "Writing captions for clip \(index + 1) of \(pending.count)…"
                let report: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in guard let self, self.projectEpoch == epoch else { return }; self.clipProgress = (Double(index) + fraction) / Double(pending.count) }
                }
                let range = ClipRange(start: clip.start, end: clip.end)
                let segments: [TranscriptSegment]
                if engine == .whisper {
                    segments = try await LocalTranscription.transcribe(media: media, audioTrack: track, model: model, language: language, vocabulary: vocabulary, range: range) { report($0.fraction) }.segments
                } else {
                    segments = try await AppleSpeech.transcribe(media: media, audioTrack: track, range: range, progress: report)
                }
                guard projectEpoch == epoch else { return false }
                // A trim made while transcribing invalidates this result.
                guard let current = moments.first(where: { $0.id == clip.id }).map(applied), current.start == clip.start, current.end == clip.end else { continue }
                updateReview { $0.captions[clip.id] = segments }
            }
            clipMessage = "Captions ready. Check the wording before you export."
            return true
        } catch {
            guard projectEpoch == epoch else { return false }
            clipMessage = Task.isCancelled ? "Captions cancelled." : "Captions couldn’t be created."
            if !Task.isCancelled { self.error = error.localizedDescription }
            return false
        }
    }
    func editClipCaption(_ clipID: String, segment: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateReview { review in
            guard let index = review.captions[clipID]?.firstIndex(where: { $0.id == segment }) else { return }
            review.captions[clipID]?[index].text = text
        }
    }
    /// Problems that would stop an export, checked before any file is written.
    var exportProblems: [String] {
        guard let report = clipReport else { return ["Wait for Cutline to finish finding moments."] }
        var problems: [String] = []
        if !brandingReady { problems.append("Add your channel name for the branding strip.") }
        if clipMedia?.shortFraming?.confirmed != true { problems.append("Check the layout first.") }
        let missing = moments.filter { decision($0.id) == .kept && autoClipHook($0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if missing > 0 { problems.append("\(missing) \(missing == 1 ? "clip needs" : "clips need") hook text.") }
        if problems.isEmpty {
            do { for candidate in moments where decision(candidate.id) == .kept { try validateExport(preparedAutoClip(candidate, report: report)) } }
            catch { problems.append(error.localizedDescription) }
        }
        return problems
    }
    static var defaultExportFolder: URL {
        LocalTools.testingRoot ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline", isDirectory: true)
    }
    func chooseExportFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = exportFolder; panel.prompt = "Use this folder"; panel.message = "Where should Cutline save your shorts?"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportFolder = folder; UserDefaults.standard.set(folder.path, forKey: "export-folder")
    }
    /// One button: writes any missing captions, then exports every kept clip to the export folder.
    func exportKeptClips() {
        guard !isExportingClips, !isScanningClips, !isTranscribingClips, clipSourceUnchanged, clipReport != nil, !keptMoments.isEmpty else { return }
        if let problem = exportProblems.first { error = problem; return }
        let folder = exportFolder
        clipExportTask = Task {
            if review?.captionsEnabled == true, captionEngineReady, !pendingCaptionClips.isEmpty {
                guard await transcribePendingClips(), !Task.isCancelled else { return }
            }
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { self.error = "Cutline can’t save to \(folder.path). Choose another folder."; return }
            exportKeptClips(to: folder)
        }
    }
    func exportKeptClips(to folder: URL) {
        guard !isExportingClips, let report = clipReport else { return }
        let kept = moments.filter { decision($0.id) == .kept }
        guard !kept.isEmpty else { return }
        guard let media = project.media.first(where: { $0.sameSource(as: report.media) }) else { error = "The recording changed. Choose it again."; return }
        var exportReport = report; exportReport.media = media
        let candidates = kept.map(applied)
        let hooks = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, autoClipHook($0.id)) })
        let captions = review?.captionsEnabled == true ? (review?.captions ?? [:]) : [:]
        let token = clipJobID, options = project.options, branding = creatorProfile
        let name = "\(media.name) shorts"
        isExportingClips = true; clipProgress = 0; clipMessage = "Getting your shorts ready…"; clipOutput = nil
        clipExportTask = Task {
            do {
                let output = try await AutoClipBatch.export(report: exportReport, candidates: candidates, to: folder, name: name, options: options, hooks: hooks, branding: branding, captions: captions) { [weak self] update in
                    Task { @MainActor in guard let self, self.clipJobID == token, self.isExportingClips else { return }; self.clipProgress = update.fraction; self.clipMessage = update.message }
                }
                guard clipJobID == token else { return }
                clipOutput = output; clipMessage = "Exported \(candidates.count) \(candidates.count == 1 ? "clip" : "clips")."
                status = "Your shorts are in \(output.lastPathComponent)."
            } catch {
                guard clipJobID == token else { return }
                clipMessage = Task.isCancelled ? "Export cancelled." : "Export failed."
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if clipJobID == token { isExportingClips = false }
        }
    }
}

// MARK: - Editing one clip without losing the session

/// The clipping session, set aside while one of its clips is open in the editor.
struct ParkedSession {
    var project: EditProject
    var savedProject: EditProject
    var projectURL: URL?
    var undoStack: [EditProject]
    var redoStack: [EditProject]
    var step: ClipStep
    var focused: String?
}

/// An autosaved clipping session that can be resumed from Home after relaunch.
struct RecoverableSession {
    var name: String
    var review: ClipReview
}

extension EditorStore {
    var sessionRecoveryURL: URL { LocalTools.support.appendingPathComponent("Recovery/clip-session.cutline") }
    func refreshRecoverableSession() {
        guard let saved = try? EditProject.read(from: sessionRecoveryURL), let review = saved.clipReview,
              let media = saved.media.first(where: { $0.id == review.mediaID }), FileManager.default.fileExists(atPath: media.url.path) else { recoverableSession = nil; return }
        recoverableSession = RecoverableSession(name: media.name, review: review)
    }
    func loadRecoverableSession() {
        guard !isImporting, !isExporting, confirmDiscard() else { return }
        do {
            let saved = try EditProject.read(from: sessionRecoveryURL)
            resetJobs(); project = saved; savedProject = saved; projectURL = nil
            undoStack = []; redoStack = []; selectedClipID = nil; playhead = 0; thumbnails = [:]; parkedSession = nil
            rebuild(); resumeSessionOrEdit()
            status = "Picked up where you left off."
            Task { for item in saved.media { await loadThumbnail(item) } }
        } catch { self.error = error.localizedDescription; recoverableSession = nil }
    }
    /// Opens one moment as its own project. The session is parked, not discarded:
    /// "Back to my clips" restores every decision, hook and trim.
    func openMomentInEditor(_ candidate: AutoClipCandidate) {
        guard let report = clipReport, !isExportingClips, !isTranscribingClips else { return }
        do {
            var clip = try preparedAutoClip(candidate, report: report)
            let hook = autoClipHook(candidate.id).trimmingCharacters(in: .whitespacesAndNewlines)
            clip.name = hook.isEmpty ? candidate.title : String(hook.prefix(60))
            let session = project
            try? FileManager.default.createDirectory(at: sessionRecoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? session.write(to: sessionRecoveryURL)
            let parked = ParkedSession(project: session, savedProject: savedProject, projectURL: projectURL, undoStack: undoStack, redoStack: redoStack, step: clipStep, focused: candidate.id)
            resetJobs(); parkedSession = parked
            project = clip; savedProject = clip; projectURL = nil
            undoStack = []; redoStack = []; selectedClipID = clip.clips.first?.id; playhead = 0; thumbnails = [:]
            rebuild(); mode = .editor; status = "Editing one clip. “Back to my clips” keeps everything you picked."
            Task { for item in clip.media { await loadThumbnail(item) } }
        } catch { self.error = error.localizedDescription }
    }
    func returnToClips() {
        guard let parked = parkedSession, !isExporting, !isImporting else { return }
        if dirty {
            let alert = NSAlert(); alert.messageText = "Save your changes to this clip?"
            alert.informativeText = "Saving keeps this edit as its own project file. Your clipping session is safe either way."
            alert.addButton(withTitle: "Save…"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Don’t Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard save() else { return }
            case .alertThirdButtonReturn: break
            default: return
            }
        }
        resetJobs(); parkedSession = nil
        project = parked.project; savedProject = parked.savedProject; projectURL = parked.projectURL
        undoStack = parked.undoStack; redoStack = parked.redoStack; selectedClipID = nil; playhead = 0; thumbnails = [:]
        rebuild(); mode = .clipper
        if let review = project.clipReview { chooseVOD(review.mediaID) }
        clipStep = canEnter(parked.step) ? parked.step : .review
        focusedMoment = parked.focused
        status = "Back to your clips."
        Task { for item in project.media { await loadThumbnail(item) } }
    }
}
