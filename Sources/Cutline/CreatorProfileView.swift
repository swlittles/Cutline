import SwiftUI
import CutlineCore

struct CreatorProfileView: View {
    @EnvironmentObject var store: EditorStore
    @State private var draft = ShortBranding()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your short branding").font(.headline)
            Text("Saved only on this Mac, separately for Dev and release builds. Project files do not include your creator profile.").font(.caption)
            TextField("Channel address or branding text", text: $draft.text).accessibilityIdentifier("creator.text")
            Picker("Platform mark", selection: $draft.logo) {
                Text("Text only").tag(ShortBranding.Logo.none)
                Text("Kick").tag(ShortBranding.Logo.kick)
            }.accessibilityIdentifier("creator.logo")
            Text("Every short requires branding in its black strip. API credentials remain in Keychain.").font(.caption)
            Button("Save branding on this Mac") {
                do { try store.saveCreatorProfile(draft); message = "Branding saved on this Mac." }
                catch { message = error.localizedDescription }
            }.accessibilityIdentifier("creator.save")
            Text(message).font(.caption).accessibilityIdentifier("creator.status")
        }.onAppear { draft = store.creatorProfile }
    }
}
