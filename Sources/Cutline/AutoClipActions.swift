import SwiftUI
import AVFoundation
import CutlineCore

extension EditorStore {
    var clipMedia: MediaItem? { project.media.first { $0.id == clipMediaID } ?? selectedMedia ?? project.media.first }
    var clipSourceUnchanged: Bool { guard let report = clipReport else { return false }; return project.media.contains(report.media) }
    func selectClipGame(_ game: ClipGame) {
        clipProfiles[clipSettings.game.rawValue] = clipSettings
        clipSettings = clipProfiles[game.rawValue] ?? .preset(game)
    }
    func resetAutoClips() {
        clipJobID = UUID(); clipTask?.cancel(); clipExportTask?.cancel()
        isScanningClips = false; isExportingClips = false; clipReport = nil; selectedAutoClips = []; clipMediaID = nil; clipOutput = nil
    }
    func scanAutoClips() {
        guard !isScanningClips, !isExportingClips, let media = clipMedia else { return }
        do { try clipSettings.validate() } catch { self.error = error.localizedDescription; return }
        clipProfiles[clipSettings.game.rawValue] = clipSettings; clipProfiles["last"] = clipSettings
        do {
            try FileManager.default.createDirectory(at: LocalTools.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(clipProfiles).write(to: LocalTools.support.appendingPathComponent("autoclip-profiles.json"), options: .atomic)
        } catch { self.error = error.localizedDescription; return }
        let settings = clipSettings, token = UUID(); clipJobID = token
        let markers = (project.markers ?? []).filter { marker in project.clips.contains { $0.id == marker.clipID && $0.mediaID == media.id } }.map { ClipEvidence(time: $0.sourceTime, signal: .marker, detail: $0.label) }
        isScanningClips = true; clipProgress = 0; clipMessage = "Starting local scan…"; clipReport = nil; selectedAutoClips = []; clipOutput = nil
        clipTask = Task {
            do {
                let report = try await ClipMediaScanner.scan(media: media, settings: settings, markers: markers) { [weak self] update in
                    Task { @MainActor in guard let self, self.clipJobID == token else { return }; self.clipProgress = update.fraction; self.clipMessage = update.message }
                }
                try Task.checkCancellation()
                guard clipJobID == token else { return }
                guard project.media.contains(media) else { throw EditError.invalid("The source changed while scanning. Scan the recording again.") }
                clipReport = report; selectedAutoClips = Set(report.candidates.map(\.id))
                clipMessage = report.candidates.isEmpty ? "No clips met these rules. Try another track or adjust the thresholds." : "Found \(report.candidates.count) \(report.candidates.count == 1 ? "clip" : "clips") to review."
            } catch {
                guard clipJobID == token else { return }
                clipMessage = Task.isCancelled ? "Scan cancelled." : "Scan failed."
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if clipJobID == token { isScanningClips = false }
        }
    }
    func addAutoClip(_ candidate: AutoClipCandidate) {
        guard clipSourceUnchanged, let media = clipReport?.media else { error = "The recording changed. Scan it again."; return }
        do {
            let new = try AutoClipRules.project(for: candidate, media: media)
            let clip = new.clips[0]
            commit { $0.clips.append(clip) }; selectedClipID = clip.id; seek(project.start(of: clip.id))
            status = "Added automatic clip to the timeline. Undo restores it."
        } catch { self.error = error.localizedDescription }
    }
    func exportAutoClips() {
        guard !isExportingClips, !isScanningClips, clipSourceUnchanged, let report = clipReport, !selectedAutoClips.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Export clips"; panel.message = "A new folder will contain each MP4, editable project, and the scan report."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportAutoClips(to: folder, report: report)
    }
    func exportAutoClips(to folder: URL, report: AutoClipReport) {
        guard !isExportingClips else { return }
        let candidates = report.candidates.filter { selectedAutoClips.contains($0.id) }
        guard !candidates.isEmpty else { return }
        let token = clipJobID, options = project.options
        isExportingClips = true; clipProgress = 0; clipMessage = "Preparing clip exports…"; clipOutput = nil
        clipExportTask = Task {
            do {
                let output = try await AutoClipBatch.export(report: report, candidates: candidates, to: folder, options: options) { [weak self] update in
                    Task { @MainActor in guard let self, self.clipJobID == token else { return }; self.clipProgress = update.fraction; self.clipMessage = update.message }
                }
                guard clipJobID == token else { return }
                clipOutput = output; clipMessage = "Exported \(candidates.count) \(candidates.count == 1 ? "clip" : "clips")."
            } catch {
                guard clipJobID == token else { return }
                clipMessage = Task.isCancelled ? "Clip export cancelled." : "Clip export failed."
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if clipJobID == token { isExportingClips = false }
        }
    }
}
