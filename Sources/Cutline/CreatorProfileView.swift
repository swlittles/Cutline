import SwiftUI
import CutlineCore

/// Usernames, badge choice, size and position for the channel badge on every short.
struct CreatorProfileView: View {
    @EnvironmentObject var store: EditorStore
    @State private var draft = ShortBranding()
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    BrandingFields(branding: $draft)
                    BadgeSizeControl(placement: $draft.placement)
                    Text("Your badge appears on every short. Saved only on this Mac, never in project files.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                ShortLayoutPreview(image: nil, framing: ShortFraming(), branding: draft, hook: "Your hook", placement: $draft.placement).frame(width: 130)
            }
            HStack {
                Text(message).font(.system(size: 11)).foregroundStyle(message == "Saved on this Mac." ? Studio.success : Studio.danger).accessibilityIdentifier("creator.status")
                Spacer()
                Button("Save") {
                    do { try store.saveCreatorProfile(draft); message = "Saved on this Mac." }
                    catch { message = error.localizedDescription }
                }.disabled(draft == store.creatorProfile).accessibilityIdentifier("creator.save")
            }
        }
        .onAppear { draft = store.creatorProfile }
        .onChange(of: draft) { _, _ in if message == "Saved on this Mac." { message = "" } }
    }
}
