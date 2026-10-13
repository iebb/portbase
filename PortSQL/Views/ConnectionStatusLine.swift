import SwiftUI

/// The connection's environment stripe plus access and security warnings above a workspace.
struct ConnectionStatusLine: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if let profile = workspace.selectedBookmark {
            let unencrypted = !profile.engine.isLocal && profile.transportSecurityMode == .plaintext
            VStack(spacing: 0) {
                EnvironmentStripe(environment: profile.environment)
                if profile.environment != .none || profile.isReadOnly || unencrypted {
                    HStack(spacing: Spacing.s) {
                        EnvironmentBadge(environment: profile.environment)
                        if profile.isReadOnly {
                            PortbaseChip(title: L10n.text("Read-only"), systemImage: "lock.fill", tint: .secondary)
                        }
                        if unencrypted {
                            PortbaseChip(title: L10n.text("Unencrypted"), systemImage: "lock.open.fill", tint: .red, filled: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(.bar)
                }
            }
        }
    }
}
