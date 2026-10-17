import SwiftUI
import AVKit
import CutlineCore

/// Step 3: moments fill in as Cutline finds them. Each plays as the finished short; keep it,
/// skip it, or nudge where it starts and ends. Mouse-friendly, with keyboard shortcuts for speed.
struct ReviewStepView: View {
    @EnvironmentObject var store: EditorStore
    @State private var filter = ReviewFilter.all
    @FocusState private var hookFocused: Bool
    @State private var showEvidence = false
    @State private var addingMoment = false
    @State private var showDetection = false
    @State private var showShortcuts = false
    private var kept: Int { store.moments.filter { store.decision($0.id) == .kept }.count }
    private var skipped: Int { store.moments.filter { store.decision($0.id) == .skipped }.count }
    private var visible: [AutoClipCandidate] { store.moments.filter { filter.includes(store.decision($0.id)) } }
    private var waiting: Bool { store.isScanningClips && store.clipReport == nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom) {
                        StepTitle(title: "Pick your clips", detail: "Each moment plays as the finished short. Keep the good ones.")
                        Spacer()
                        if !store.moments.isEmpty {
                            Text("\(store.moments.count) \(store.moments.count == 1 ? "moment" : "moments") · \(kept) kept · \(skipped) skipped")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Studio.muted).accessibilityIdentifier("review.summary")
                        }
                    }
                    toolbar
                    if store.isScanningClips { ProgressLine(value: store.clipProgress, message: store.clipMessage).accessibilityIdentifier("find.progress") }
                    else if !store.moments.isEmpty { Text(store.clipMessage).font(.system(size: 12)).foregroundStyle(Studio.muted).accessibilityIdentifier("clips.status") }
                    MomentHeatStrip(height: 44)
                    if store.moments.isEmpty { emptyState } else {
                        Picker("Show", selection: $filter) { ForEach(ReviewFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(visible, id: \.id) { candidate in row(candidate).id(candidate.id) }
                                }.padding(.bottom, 8)
                            }.accessibilityIdentifier("review.list")
                            .onChange(of: store.focusedMoment) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } } }
                        }
                    }
                }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Rectangle().fill(Studio.line).frame(width: 1)
                detail.frame(width: 420)
            }.frame(maxHeight: .infinity)
            StepFooter(back: .setup, title: kept == 0 ? "Export" : "Export \(kept) \(kept == 1 ? "clip" : "clips")", enabled: store.canEnter(.export), hint: kept == 0 ? "Keep at least one moment to export." : nil, identifier: "review.continue") {
                store.goTo(.export)
            } leading: {
                Button { showShortcuts.toggle() } label: { Label("Keyboard shortcuts", systemImage: "keyboard") }.buttonStyle(.quiet)
                    .popover(isPresented: $showShortcuts, arrowEdge: .top) { shortcuts }
            }
        }
        .sheet(isPresented: $addingMoment) { AddMomentSheet().environmentObject(store) }
        .sheet(isPresented: $showDetection) { DetectionSettingsSheet().environmentObject(store) }
        .onAppear { store.ensureFocus(); store.refreshReviewPreview(); if store.clipReport == nil && !store.isScanningClips { store.beginAnalysis() } }
        .onDisappear { store.reviewPlayer.pause() }
        .onChange(of: store.focusedMoment) { _, _ in store.refreshReviewPreview() }
        .onChange(of: store.project.clipReview) { _, _ in store.refreshReviewPreview() }
        .onChange(of: store.project.autoClipHooks) { _, _ in store.refreshReviewPreview() }
        .onChange(of: store.hookFocusRequest) { _, _ in hookFocused = true }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Fewer").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Slider(value: Binding(get: { store.clipSettings.sensitivity }, set: { store.clipSettings.sensitivity = $0 }), in: 0...1).frame(width: 160).accessibilityIdentifier("find.sensitivity")
                Text("More").font(.system(size: 11)).foregroundStyle(Studio.muted)
            }.help("How many moments to show. Updates instantly.")
            Spacer()
            Button { addingMoment = true } label: { Label("Add a moment", systemImage: "plus") }.buttonStyle(.secondary).disabled(store.clipMedia == nil).accessibilityIdentifier("review.addMoment")
            Button { showDetection = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.secondary).help("How Cutline finds moments").accessibilityIdentifier("review.detection")
        }
    }
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: waiting ? "sparkle.magnifyingglass" : "film.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Studio.accent)
            Text(waiting ? "Finding your best moments…" : "No moments stood out yet").font(Studio.title(20))
            Text(waiting ? "Cutline is listening for big reactions and watching for action. Long streams take a few minutes." : store.clipMessage)
                .font(.system(size: 12)).foregroundStyle(Studio.muted).multilineTextAlignment(.center).frame(maxWidth: 360).accessibilityIdentifier("clips.status")
            if !waiting && !store.isScanningClips {
                HStack {
                    Button("Show more moments") { store.clipSettings.sensitivity = min(1, store.clipSettings.sensitivity + 0.25) }.buttonStyle(.secondary).disabled(store.clipSettings.sensitivity >= 1)
                    Button { addingMoment = true } label: { Label("Add a moment", systemImage: "plus") }.buttonStyle(.primary)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var shortcuts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach([("K", "Keep"), ("X", "Skip"), ("U", "Undecide"), ("↑ ↓", "Previous / next moment"), ("Space", "Play / pause"), ("[  ]", "Start earlier / end later"), ("⇧[  ⇧]", "Start later / end earlier"), ("Return", "Edit the hook"), ("⌘Z", "Undo")], id: \.0) { key, action in
                GridRow {
                    Text(key).font(.system(size: 11, weight: .semibold, design: .monospaced)).padding(.horizontal, 6).padding(.vertical, 2).background(Studio.well, in: RoundedRectangle(cornerRadius: 4))
                    Text(action).font(.system(size: 12))
                }
            }
        }.padding(16)
    }
    private func row(_ candidate: AutoClipCandidate) -> some View {
        let decision = store.decision(candidate.id)
        let shown = store.applied(candidate)
        let focused = store.focusedMoment == candidate.id
        let hook = store.autoClipHook(candidate.id)
        return Button { store.focus(candidate.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: decision == .kept ? "checkmark.circle.fill" : decision == .skipped ? "xmark.circle" : "circle")
                    .font(.system(size: 18)).foregroundStyle(decision == .kept ? Studio.success : Studio.muted)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(clockTime(shown.start)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text("\(Int((shown.end - shown.start).rounded())) sec").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        ForEach(signals(candidate), id: \.self) { Image(systemName: $0).font(.system(size: 10)).foregroundStyle(Studio.muted) }
                    }
                    Text(hook.isEmpty ? candidate.title : hook).font(.system(size: 12)).foregroundStyle(hook.isEmpty ? Studio.muted : Studio.text).lineLimit(1)
                }
                Spacer()
                ScoreBar(score: candidate.score).frame(width: 46)
            }.padding(.horizontal, 14).frame(height: 56)
                .background(focused ? Studio.accent.opacity(0.08) : Studio.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Studio.accent : Studio.line, lineWidth: focused ? 1.5 : 1))
                .opacity(decision == .skipped ? 0.55 : 1).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("review.row.\(candidate.id)").accessibilityValue(decision == .kept ? "Kept" : decision == .skipped ? "Skipped" : "Undecided")
    }
    private func signals(_ candidate: AutoClipCandidate) -> [String] {
        var icons: [String] = []
        if candidate.evidence.contains(where: { $0.signal == .audio }) { icons.append("waveform") }
        if candidate.evidence.contains(where: { $0.signal == .motion }) { icons.append("sparkles.tv") }
        if candidate.evidence.contains(where: { $0.signal == .elimination }) { icons.append("scope") }
        if candidate.evidence.contains(where: { $0.signal == .marker }) { icons.append("flag.fill") }
        return icons
    }
    @ViewBuilder private var detail: some View {
        if let candidate = store.focusedCandidate, let media = store.clipMedia {
            let shown = store.applied(candidate)
            let decision = store.decision(candidate.id)
            // No scrolling: the player flexes so Keep, Skip and the hook always stay in view.
            VStack(alignment: .leading, spacing: 14) {
                NativePlayer(player: store.reviewPlayer).aspectRatio(9 / 16, contentMode: .fit).frame(minHeight: 220, maxHeight: .infinity).frame(maxWidth: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .onTapGesture { store.toggleReviewPlayback() }.help("Click to play or pause").accessibilityIdentifier("review.player")
                RangeTrimBar(candidate: candidate, shown: shown, duration: media.duration) { start, end in store.setMomentRange(candidate.id, start: start, end: end) }
                HStack(spacing: 6) {
                    nudgeGroup("Start", earlier: { store.nudge(start: true, by: -1) }, later: { store.nudge(start: true, by: 1) }, id: "start")
                    Spacer()
                    VStack(spacing: 1) {
                        Text("\(Int((shown.end - shown.start).rounded())) sec").font(.system(size: 12, weight: .semibold))
                        Text("\(clockTime(shown.start)) – \(clockTime(shown.end))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).accessibilityIdentifier("review.range")
                    }
                    if store.review?.ranges[candidate.id] != nil {
                        Button { store.resetMomentRange(candidate.id) } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.quiet).help("Undo trimming")
                    }
                    Spacer()
                    nudgeGroup("End", earlier: { store.nudge(start: false, by: -1) }, later: { store.nudge(start: false, by: 1) }, id: "end")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hook").font(.system(size: 12, weight: .semibold))
                        Text("Big text for the first 3 seconds").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        Spacer()
                        Menu {
                            ForEach(HookIdeas.suggestions(for: candidate, game: store.clipSettings.game), id: \.self) { idea in Button(idea) { store.setHook(candidate.id, idea) } }
                        } label: { Label("Ideas", systemImage: "lightbulb") }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(Studio.accent).help("Hook ideas").accessibilityIdentifier("review.ideas")
                    }
                    TextField("e.g. \(store.suggestedHook(candidate))", text: Binding(get: { store.autoClipHook(candidate.id) }, set: { store.setHook(candidate.id, $0) }))
                        .textFieldStyle(.roundedBorder).controlSize(.large).focused($hookFocused).accessibilityIdentifier("review.hook")
                }
                HStack(spacing: 10) {
                    Button { hookFocused = false; store.skipFocused() } label: { Label("Skip", systemImage: "xmark").frame(maxWidth: .infinity) }
                        .buttonStyle(.secondaryLarge).accessibilityIdentifier("review.skip")
                    if decision == .kept {
                        Button { hookFocused = false; store.clearFocusedDecision() } label: { Label("Kept", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(KeptButtonStyle()).help("Click to undo").accessibilityIdentifier("review.keep")
                    } else {
                        Button { hookFocused = false; store.keepFocused() } label: { Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity) }
                            .buttonStyle(.primaryLarge).accessibilityIdentifier("review.keep")
                    }
                }
                HStack {
                    Button("Why this moment?") { showEvidence.toggle() }.buttonStyle(.accentLink)
                        .popover(isPresented: $showEvidence, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(candidate.evidence.enumerated()), id: \.offset) { _, event in
                                    Text("\(clockTime(event.time)) · \(event.detail)").font(.system(size: 11)).textSelection(.enabled)
                                }
                                Text("Cutline measures activity, not quality. You decide what’s good.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
                            }.padding(14).frame(maxWidth: 360, alignment: .leading)
                        }
                    Spacer()
                    Button("Edit this clip…") { store.openMomentInEditor(candidate) }.buttonStyle(.accentLink).help("Open in the editor. Your picks are kept.").accessibilityIdentifier("review.openEditor")
                }
            }.padding(20).frame(maxHeight: .infinity).background(Studio.panel).accessibilityElement(children: .contain).accessibilityIdentifier("review.detail")
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "rectangle.portrait.on.rectangle.portrait").font(.system(size: 30, weight: .light)).foregroundStyle(Studio.muted)
                Text(store.moments.isEmpty ? "Your short previews here" : "Select a moment").foregroundStyle(Studio.muted)
                Spacer()
            }.frame(maxWidth: .infinity).background(Studio.panel)
        }
    }
    private func nudgeGroup(_ title: String, earlier: @escaping () -> Void, later: @escaping () -> Void, id: String) -> some View {
        VStack(alignment: id == "start" ? .leading : .trailing, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Studio.muted)
            HStack(spacing: 4) {
                Button(action: earlier) { Text("−1s").frame(minWidth: 30) }.buttonStyle(.secondary).help("\(title) 1 second earlier").accessibilityIdentifier("review.\(id).earlier")
                Button(action: later) { Text("+1s").frame(minWidth: 30) }.buttonStyle(.secondary).help("\(title) 1 second later").accessibilityIdentifier("review.\(id).later")
            }.controlSize(.small)
        }
    }
}

private struct KeptButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Studio.success)
            .padding(.horizontal, 20).frame(minHeight: 40)
            .background(Studio.success.opacity(configuration.isPressed ? 0.25 : 0.14), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Studio.success.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

enum ReviewFilter: String, CaseIterable, Identifiable {
    case all = "All", undecided = "To do", kept = "Kept", skipped = "Skipped"
    var id: String { rawValue }
    func includes(_ decision: ClipDecision) -> Bool {
        switch self { case .all: return true; case .undecided: return decision == .undecided; case .kept: return decision == .kept; case .skipped: return decision == .skipped }
    }
}

private struct ScoreBar: View {
    let score: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.well)
                Capsule().fill(Studio.accent.opacity(0.8)).frame(width: geometry.size.width * max(0.05, min(1, score / 100)))
            }
        }.frame(height: 4).help("How much happened: \(Int(score)) / 100. Not a judgment of quality.")
    }
}

/// Drag the handles to change where the clip starts and ends. The faint band shows the detected range.
private struct RangeTrimBar: View {
    let candidate: AutoClipCandidate
    let shown: AutoClipCandidate
    let duration: Double
    let commit: (Double, Double) -> Void
    @State private var draft: (start: Double, end: Double)?
    var body: some View {
        let low = max(0, min(candidate.start, shown.start) - 20), high = min(duration, max(candidate.end, shown.end) + 20)
        let span = max(0.1, high - low)
        let current = draft ?? (shown.start, shown.end)
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = { (time: Double) in (time - low) / span * width }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Studio.well)
                Rectangle().fill(Studio.text.opacity(0.08)).frame(width: max(1, x(candidate.end) - x(candidate.start))).offset(x: x(candidate.start))
                Rectangle().fill(Studio.accent.opacity(0.28)).frame(width: max(1, x(current.end) - x(current.start))).offset(x: x(current.start))
                handle.offset(x: x(current.start) - 5).gesture(drag(start: true, low: low, high: high, width: width, span: span))
                handle.offset(x: x(current.end) - 5).gesture(drag(start: false, low: low, high: high, width: width, span: span))
            }.coordinateSpace(name: "trim")
        }.frame(height: 28).help("Drag the handles to change where the clip starts and ends")
            .accessibilityElement(children: .ignore).accessibilityLabel("Clip range").accessibilityIdentifier("review.trim")
    }
    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Studio.accent).frame(width: 10, height: 28)
            .overlay(Capsule().fill(Color.white.opacity(0.8)).frame(width: 2, height: 12))
    }
    private func drag(start: Bool, low: Double, high: Double, width: Double, span: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trim")).onChanged { value in
            let time = max(low, min(high, low + value.location.x / max(1, width) * span))
            var next = draft ?? (shown.start, shown.end)
            if start { next.start = min(time, next.end - ClipReview.minimumLength) } else { next.end = max(time, next.start + ClipReview.minimumLength) }
            draft = next
        }.onEnded { _ in
            if let draft { commit(draft.start, draft.end) }
            draft = nil
        }
    }
}
