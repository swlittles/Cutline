import SwiftUI
import CutlineCore

// MARK: - What was said
/// The whole stream is transcribed on this Mac (Whisper when it's set up, otherwise macOS speech
/// recognition), once per recording and speech track. With OpenRouter connected, an AI model then
/// reads the transcript and the measured signals and picks moments, each with a title and hook.
extension EditorStore {
    /// Identifies one recording's speech track, so a failed AI run isn't retried on every refresh.
    private var speechKey: String? { clipMedia.map { "\($0.url.path)#\(routes.speech)" } }
    var sharesWithOpenRouter: Bool { aiFindsMoments && openRouterConnected }
    var sharesFramesWithOpenRouter: Bool { sharesWithOpenRouter && aiLooksAtFrames }

    /// Shows whatever was already made for this recording, without starting anything.
    func loadSpeech() {
        listenTask?.cancel(); aiPickTask?.cancel(); isListening = false; isPickingWithAI = false
        listenMessage = ""; aiPickMessage = ""
        guard let media = clipMedia else { streamTranscript = nil; aiPicks = nil; return }
        let track = routes.speech
        streamTranscript = StreamTranscriptCache.load(for: media, track: track)
        aiPicks = AIClipPicksCache.load(for: media, track: track)
        screenNotes = aiPicks?.visionModel == nil ? [] : ScreenNotesCache.load(for: media)?.notes ?? []
        if let aiPicks { aiPickMessage = picksSummary(aiPicks) }
    }
    func stopListening() { listenTask?.cancel(); listenTask = nil; isListening = false }

    /// Starts transcribing once the layout (and so the speech track) is confirmed.
    func listenIfNeeded() {
        guard listenToStream, setupComplete, !isListening, let media = clipMedia else { return }
        let track = routes.speech
        if streamTranscript?.audioTrack != track || aiPicks.map({ $0.audioTrack != track }) == true { loadSpeech() }
        if streamTranscript != nil { pickWithAIIfNeeded(); return }
        guard (media.audioTrackCount ?? 0) > track else { return }
        let engine = captionEngine
        guard engine == .whisper || engine == .apple else {
            listenMessage = engine == .whisperNeedsModel ? "Download a speech model in Export → Captions to hear what was said." : "Speech recognition isn’t available on this Mac."
            return
        }
        let model = speechModel, language = transcriptionLanguage, vocabulary = transcriptionVocabulary
        let label = engine == .whisper ? "whisper.\(model.rawValue)" : "apple"
        isListening = true; listenProgress = 0; listenMessage = "Listening to what was said…"
        listenTask = Task {
            let report: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
                Task { @MainActor in guard let self, self.isListening, self.clipMedia?.sameSource(as: media) == true else { return }; self.listenProgress = fraction; self.listenMessage = message }
            }
            do {
                let segments: [TranscriptSegment]
                if engine == .whisper {
                    if !WhisperVAD.installed { report(0, "Getting speech detection ready…"); try? await WhisperVAD.download() }
                    segments = try await LocalTranscription.transcribe(media: media, audioTrack: track, model: model, language: language, vocabulary: vocabulary) { update in
                        report(update.fraction, "Listening to what was said…")
                    }.segments
                } else {
                    segments = try await AppleSpeech.transcribe(media: media, audioTrack: track, range: ClipRange(start: 0, end: media.duration)) { fraction in
                        report(fraction, "Listening to what was said…")
                    }
                }
                try Task.checkCancellation()
                guard clipMedia?.sameSource(as: media) == true, routes.speech == track else { return }
                let transcript = StreamTranscript(audioTrack: track, engine: label, segments: StreamTranscript.withoutLoops(segments))
                streamTranscript = transcript; isListening = false
                listenMessage = segments.isEmpty ? "No speech found on track \(track + 1)." : "Heard \(segments.count) lines of speech."
                Task.detached(priority: .utility) { try? StreamTranscriptCache.save(transcript, for: media) }
                pickWithAIIfNeeded()
            } catch {
                guard clipMedia?.sameSource(as: media) == true else { return }
                isListening = false
                listenMessage = Task.isCancelled ? "" : "Couldn’t transcribe the stream: \(error.localizedDescription)"
            }
        }
    }

    /// Runs once per recording after both the transcript and the scan are ready:
    /// optionally describe frames, pick moments, then optionally polish their titles and hooks.
    func pickWithAIIfNeeded(force: Bool = false) {
        guard aiFindsMoments, !isPickingWithAI, !isScanningClips, let media = clipMedia, let transcript = streamTranscript, let key = speechKey else { return }
        guard force || (aiPicks == nil && !aiPickAttempts.contains(key)) else { return }
        guard let apiKey = OpenRouterKeychain.read() else { aiPickMessage = "Connect OpenRouter to have AI pick moments from what was said."; return }
        let lookAtFrames = aiLooksAtFrames
        guard !transcript.segments.isEmpty || lookAtFrames else { return }
        aiPickAttempts.insert(key)
        let pickModel = clipPickModel.trimmingCharacters(in: .whitespacesAndNewlines), copyModel = clipCopyModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let visionModel = clipVisionModel.trimmingCharacters(in: .whitespacesAndNewlines), budget = min(ClipVisionAI.budgetRange.upperBound, max(ClipVisionAI.budgetRange.lowerBound, visionFrameBudget))
        let polish = aiPolishesCopy, signals = clipReport?.evidence ?? [], track = transcript.audioTrack
        isPickingWithAI = true; aiPickProgress = 0; aiPickMessage = "AI is reading the stream…"
        let step: @Sendable (String, Int, Int) -> Void = { [weak self] message, done, total in
            Task { @MainActor in guard let self, self.isPickingWithAI else { return }; self.aiPickProgress = Double(done) / Double(max(1, total)); self.aiPickMessage = message }
        }
        aiPickTask = Task {
            do {
                var notes: [ScreenNote] = [], frameProblem: String?
                if lookAtFrames {
                    if let cached = ScreenNotesCache.load(for: media), cached.model == visionModel, cached.budget == budget, !force { notes = cached.notes }
                    else {
                        let times = ClipVisionAI.frameTimes(signals: signals, transcript: transcript, duration: media.duration, budget: budget)
                        step("AI is looking at \(times.count) frames…", 0, 1)
                        do {
                            notes = try await ClipVisionAI.describe(media: media, times: times, model: visionModel, apiKey: apiKey) { done, total in
                                step("AI is looking at \(times.count) frames · batch \(done) of \(total)", done, total)
                            }
                            let saved = ScreenNotes(model: visionModel, budget: budget, notes: notes)
                            Task.detached(priority: .utility) { try? ScreenNotesCache.save(saved, for: media) }
                        } catch is CancellationError { throw CancellationError() }
                        // Picking still works from what was said; say why frames were left out.
                        catch { frameProblem = error.localizedDescription }
                    }
                }
                step("AI is reading the stream…", 0, 1)
                var picks = try await ClipFinderAI.find(transcript: transcript, signals: signals, notes: notes, duration: media.duration, model: pickModel, apiKey: apiKey) { done, total in
                    step("AI is reading the stream · part \(min(total, done + 1)) of \(total)", done, total)
                }
                var polished = 0
                if polish, !picks.isEmpty {
                    step("AI is writing titles and hooks…", 0, 1)
                    (picks, polished) = try await ClipCopyAI.polish(picks, transcript: transcript, signals: signals, notes: notes, model: copyModel, apiKey: apiKey) { done, total in
                        step("AI is writing titles and hooks · \(done) of \(total)", done, total)
                    }
                }
                try Task.checkCancellation()
                guard clipMedia?.sameSource(as: media) == true, routes.speech == track else { return }
                let result = AIClipPicks(audioTrack: track, model: pickModel, picks: picks, copyModel: polished > 0 ? copyModel : nil, visionModel: notes.isEmpty ? nil : visionModel)
                aiPicks = result; screenNotes = notes; isPickingWithAI = false
                aiPickMessage = picksSummary(result) + (frameProblem.map { " · frames skipped: \($0)" } ?? "")
                Task.detached(priority: .utility) { try? AIClipPicksCache.save(result, for: media) }
                evaluateMoments()
            } catch {
                guard clipMedia?.sameSource(as: media) == true else { return }
                isPickingWithAI = false
                aiPickMessage = Task.isCancelled ? "" : "AI couldn’t pick moments: \(error.localizedDescription)"
            }
        }
    }
    /// Asks the model again, replacing its earlier picks. Review decisions on them are kept.
    func repickWithAI() {
        guard let media = clipMedia else { return }
        aiPickTask?.cancel(); isPickingWithAI = false
        AIClipPicksCache.remove(for: media, track: routes.speech)
        pickWithAIIfNeeded(force: true)
    }
    private func picksSummary(_ picks: AIClipPicks) -> String {
        guard !picks.picks.isEmpty else { return "AI found nothing worth clipping." }
        let models = [picks.visionModel, picks.model, picks.copyModel].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "AI picked \(picks.picks.count) \(picks.picks.count == 1 ? "moment" : "moments") · \(models.joined(separator: ", "))"
    }
    /// AI picks for the current speech track, when they're turned on.
    var activeAIPicks: [AIClipPick] {
        guard aiFindsMoments, let aiPicks, aiPicks.audioTrack == routes.speech else { return [] }
        return aiPicks.picks
    }
    /// What the vision model saw during a moment.
    func screenNotes(_ candidate: AutoClipCandidate) -> [ScreenNote] {
        guard aiFindsMoments else { return [] }
        return screenNotes.filter { $0.time >= candidate.start - 1 && $0.time <= candidate.end }
    }
    /// What was said during a moment, for the list and "Why this moment?".
    func spokenText(_ candidate: AutoClipCandidate) -> String? {
        guard let transcript = streamTranscript, transcript.audioTrack == routes.speech else { return nil }
        let text = transcript.text(from: candidate.start, to: candidate.end).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func saveOpenRouterKey(_ key: String) throws {
        try OpenRouterKeychain.save(key); openRouterConnected = true
        aiPickAttempts.removeAll(); pickWithAIIfNeeded()
    }
    func removeOpenRouterKey() throws { try OpenRouterKeychain.remove(); openRouterConnected = false }
}
