import SwiftUI

struct ConnectionStatusLine: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if let profile = workspace.selectedBookmark,
           profile.isReadOnly || (!profile.engine.isLocal && profile.transportSecurityMode == .plaintext) {
            HStack(spacing: 8) {
                if profile.isReadOnly {
                    PortbaseChip(title: L10n.text("Read-only"), systemImage: "lock.fill", tint: .secondary)
                }
                if !profile.engine.isLocal && profile.transportSecurityMode == .plaintext {
                    PortbaseChip(title: L10n.text("Unencrypted"), systemImage: "lock.open.fill", tint: .red, filled: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}
