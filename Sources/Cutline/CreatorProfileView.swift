import SwiftUI
import CutlineCore

struct CreatorProfileView: View {
    @EnvironmentObject var store: EditorStore
    @State private var draft = ShortBranding()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Channel name or address", text: $draft.text, prompt: Text("e.g. kick.com/yourname")).accessibilityIdentifier("creator.text")
            Picker("Logo", selection: $draft.logo) {
                Text("Text only").tag(ShortBranding.Logo.none)
                Text("With Kick logo").tag(ShortBranding.Logo.kick)
            }.accessibilityIdentifier("creator.logo")
            Text("Shown in a thin strip on every short. Saved only on this Mac, never in project files.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            HStack {
                Text(message).font(.system(size: 11)).foregroundStyle(Studio.success).accessibilityIdentifier("creator.status")
                Spacer()
                Button("Save") {
                    do { try store.saveCreatorProfile(draft); message = "Saved on this Mac." }
                    catch { message = error.localizedDescription }
                }.accessibilityIdentifier("creator.save")
            }
        }.onAppear { draft = store.creatorProfile }
    }
}
