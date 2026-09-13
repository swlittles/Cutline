import SwiftUI
import CutlineCore

struct AIPanel: View {
    @EnvironmentObject var store: EditorStore
    @State private var key = ""
    @State private var keySaved = false
    @State private var configure = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Editing assistant", systemImage: "sparkles").font(.system(size: 14, weight: .semibold))
                Text("Find moments worth clipping, improve captions, translate dialogue, and draft titles.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                DisclosureGroup(keySaved ? "OpenRouter · connected" : "Connect OpenRouter", isExpanded: $configure) {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("OpenRouter API key", text: $key).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Save to Keychain") {
                                do { try OpenRouterKeychain.save(key); key = ""; keySaved = true; configure = false }
                                catch { store.error = error.localizedDescription }
                            }.disabled(key.isEmpty)
                            if keySaved { Button("Remove") { do { try OpenRouterKeychain.remove(); keySaved = false } catch { store.error = error.localizedDescription } } }
                        }
                        TextField("Model ID", text: $store.aiModel).textFieldStyle(.roundedBorder)
                        Text("Use a model that supports structured outputs. Your key is stored in macOS Keychain, never in project files.").foregroundStyle(Studio.muted)
                    }.font(.system(size: 10)).padding(.top, 8)
                }.font(.system(size: 11))
                Divider()
                DisclosureGroup("Generate images & video") { GenerationPanel().padding(.top, 10) }.font(.system(size: 11))
                Divider()
                Text("Work with your transcript").font(.system(size: 14, weight: .semibold))
                HStack {
                    quick("Highlights", "Find the best gaming highlights, with context and reactions. Suggest clips and titles.")
                    quick("Fix captions", "Correct obvious transcription mistakes and punctuation. Preserve the speaker's meaning and supplied caption IDs.")
                }
                TextEditor(text: $store.aiPrompt).accessibilityIdentifier("ai.prompt").font(.system(size: 12)).scrollContentBackground(.hidden).padding(8).frame(height: 110).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
                let sections = store.aiSectionCount
                Text("Sends your instruction and transcript text to OpenRouter and its model provider. No video or audio is uploaded. Uses your OpenRouter credits · \(sections) request\(sections == 1 ? "" : "s").").font(.system(size: 10)).foregroundStyle(Studio.muted).lineSpacing(3)
                Button(action: store.requestAI) {
                    Label(store.isThinking ? "Working…" : "Generate suggestions", systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(!keySaved || sections == 0 || store.isThinking)
                if store.isThinking {
                    ProgressView(); Text(store.aiProgress).font(.system(size: 10)).foregroundStyle(Studio.muted)
                    Button("Cancel") { store.assistantTask?.cancel() }
                }
                if let proposal = store.aiProposal {
                    Divider()
                    Text(proposal.summary).font(.system(size: 11)).textSelection(.enabled)
                    ForEach(proposal.highlights) { highlight in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(highlight.title).font(.system(size: 12, weight: .semibold))
                            Text("\(timecode(highlight.start)) – \(timecode(highlight.end))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.mint)
                            Text(highlight.reason).font(.system(size: 10)).foregroundStyle(Studio.muted)
                            HStack {
                                Button("Preview") { store.seek(highlight.start); store.togglePlayback() }
                                Button("Keep this range") { store.applyHighlight(highlight) }
                            }.font(.system(size: 10))
                        }.padding(12).background(Studio.raised, in: RoundedRectangle(cornerRadius: 7))
                    }
                    if !proposal.captionEdits.isEmpty {
                        Text("\(proposal.captionEdits.count) proposed caption edits").font(.system(size: 12, weight: .medium))
                        ForEach(proposal.captionEdits) { edit in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.project.captionTrack?.cues.first { $0.id.uuidString == edit.id }?.text ?? "").foregroundStyle(Studio.muted)
                                Text(edit.text).foregroundStyle(Studio.mint)
                            }.font(.system(size: 11)).padding(9).background(Studio.raised, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Button("Apply caption edits", action: store.applyCaptionEdits)
                    }
                    if !proposal.titles.isEmpty {
                        Text("Title ideas").font(.system(size: 12, weight: .medium))
                        ForEach(proposal.titles, id: \.self) { Text($0).font(.system(size: 11)).textSelection(.enabled) }
                    }
                } else if !store.isThinking {
                    Label("Suggestions are reviewed before you apply them. Every applied edit can be undone.", systemImage: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.top, 20)
                }
            }.padding(16)
        }.accessibilityIdentifier("ai.scroll").onAppear { keySaved = OpenRouterKeychain.read() != nil; configure = !keySaved }
    }
    private func quick(_ title: String, _ prompt: String) -> some View {
        Button(title) { store.aiPrompt = prompt }.font(.system(size: 10)).buttonStyle(.bordered)
    }
}
