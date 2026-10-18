import SwiftUI

/// The connection's environment stripe plus access and security warnings above a workspace. On iPad
/// the warnings sit in the connection button in the navigation bar instead, and only the stripe shows here.
struct ConnectionStatusLine: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif

    private var showsBadgesHere: Bool {
#if os(iOS)
        horizontalSizeClass != .regular
#else
        true
#endif
    }

    var body: some View {
        if let profile = workspace.selectedBookmark {
            VStack(spacing: 0) {
                EnvironmentStripe(environment: profile.environment)
                if showsBadgesHere, ConnectionStatusBadges.hasBadges(profile) {
                    HStack(spacing: Spacing.s) {
                        ConnectionStatusBadges(profile: profile)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    .background(PortSQLPalette.panel)
                    .overlay(alignment: .bottom) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
                }
            }
        }
    }
}

/// The connection's environment, read-only access, and an unencrypted transport's warning.
struct ConnectionStatusBadges: View {
    let profile: ConnectionProfile

    static func hasBadges(_ profile: ConnectionProfile) -> Bool {
        profile.environment != .none || profile.isReadOnly || isUnencrypted(profile)
    }

    static func isUnencrypted(_ profile: ConnectionProfile) -> Bool {
        !profile.engine.isLocal && profile.transportSecurityMode == .plaintext
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            EnvironmentBadge(environment: profile.environment)
            if profile.isReadOnly {
                PortbaseChip(title: L10n.text("Read-only"), systemImage: "lock.fill", tint: .secondary)
            }
            if Self.isUnencrypted(profile) {
                PortbaseChip(title: L10n.text("Unencrypted"), systemImage: "lock.open.fill", tint: .red, filled: true)
            }
        }
    }
}
