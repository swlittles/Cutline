import SwiftUI
import CutlineCore

/// Home → guided clipper → editor. The clipper is the main path; the editor is for fine-tuning.
struct RootView: View {
    @EnvironmentObject var store: EditorStore
    var body: some View {
        Group {
            switch store.mode {
            case .home: HomeView()
            case .clipper: ClipperView()
            case .editor: EditorView()
            }
        }
        .disclosureGroupStyle(StudioDisclosureStyle())
        .foregroundStyle(Studio.text)
        .background(Studio.base).tint(Studio.accent).frame(minWidth: 1120, minHeight: 760)
        .alert("Something needs your attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: EditorStore
    private var recents: [URL] { NSDocumentController.shared.recentDocumentURLs.filter { $0.pathExtension == "cutline" && FileManager.default.fileExists(atPath: $0.path) }.prefix(5).map { $0 } }
    var body: some View {
        VStack(spacing: 0) {
            AppHeader { Spacer() } trailing: {
                Button("Open a project…", action: store.openProject).buttonStyle(.quiet).accessibilityIdentifier("home.open")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turn a stream into shorts.").font(Studio.title(38)).tracking(-0.6)
                        Text("Pick a recording, check the layout once, keep the moments you like. Everything happens on this Mac.")
                            .font(.system(size: 14)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if let name = store.continuableSessionName, let review = store.continuableSessionReview {
                        Button(action: store.continueClipping) {
                            HStack(spacing: 14) {
                                Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundStyle(Studio.accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Continue clipping “\(name)”").font(.system(size: 14, weight: .semibold))
                                    Text(review.kept.isEmpty ? "Pick up where you left off" : "\(review.kept.count) \(review.kept.count == 1 ? "clip" : "clips") kept so far")
                                        .font(.system(size: 12)).foregroundStyle(Studio.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").foregroundStyle(Studio.muted)
                            }.padding(18).background(Studio.raised, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Studio.accent.opacity(0.5)))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain).accessibilityIdentifier("home.continue")
                    }
                    HStack(alignment: .top, spacing: 18) {
                        Button(action: store.startClipping) {
                            HomeCard(icon: "scissors", title: "Clip a stream", detail: "Cutline finds the big moments in your recording and turns the ones you keep into vertical shorts.", accent: true) {
                                HStack(spacing: 6) {
                                    ForEach(ClipStep.allCases) { step in
                                        Text("\(step.rawValue + 1)  \(step.title)").font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                                            .background(Color.white.opacity(0.18), in: Capsule())
                                    }
                                }
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("home.clip")
                        Button(action: store.showEditor) {
                            HomeCard(icon: "film.stack", title: "Edit a video", detail: "Trim, split and caption any video, or fine-tune a short you already made.", accent: false) { EmptyView() }
                        }.buttonStyle(.plain).accessibilityIdentifier("home.openEditor")
                    }
                    if !recents.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Recent projects")
                            VStack(spacing: 0) {
                                ForEach(Array(recents.enumerated()), id: \.element) { index, url in
                                    if index > 0 { Rectangle().fill(Studio.line).frame(height: 1).padding(.leading, 44) }
                                    Button { guard store.confirmDiscard() else { return }; store.loadProject(url) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "doc.richtext").foregroundStyle(Studio.accent).frame(width: 20)
                                            Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 13))
                                            Spacer()
                                            Text(url.deletingLastPathComponent().lastPathComponent).font(.system(size: 11)).foregroundStyle(Studio.muted)
                                        }.padding(.horizontal, 14).frame(height: 42).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.background(Studio.raised, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Studio.line))
                        }
                    }
                }.frame(maxWidth: 860, alignment: .leading).padding(.horizontal, 40).padding(.vertical, 48).frame(maxWidth: .infinity)
            }
        }.onAppear { store.refreshRecoverableSession() }
    }
}

private struct HomeCard<Footer: View>: View {
    let icon: String, title: String, detail: String, accent: Bool
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.system(size: 24, weight: .regular))
                .frame(width: 46, height: 46).background(accent ? Color.white.opacity(0.18) : Studio.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(accent ? Studio.onAccent : Studio.accent)
            Text(title).font(Studio.title(24))
            Text(detail).font(.system(size: 13)).opacity(0.85).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            footer
        }
        .foregroundStyle(accent ? Studio.onAccent : Studio.text)
        .padding(24).frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(accent ? Studio.accent : Studio.raised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent ? Color.clear : Studio.line))
        .shadow(color: .black.opacity(accent ? 0.12 : 0.04), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
