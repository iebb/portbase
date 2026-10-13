import SwiftUI

struct ConsoleTransactionControls: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if workspace.selectedBookmark?.engine.supportsConsoleTransactions == true {
            Menu {
                Button("Auto-commit") { workspace.setManualCommit(false) }
                    .disabled(workspace.hasOpenTransaction)
                Button("Manual Commit") { workspace.setManualCommit(true) }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: workspace.manualCommit ? "hand.raised.fill" : "arrow.triangle.branch")
                    Text(workspace.manualCommit ? L10n.text("Manual Commit") : L10n.text("Auto-commit"))
                        .lineLimit(1)
                    if workspace.hasOpenTransaction {
                        Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot)
                            .accessibilityLabel("Transaction open")
                    }
                }
                .font(.captionStrong)
                .foregroundStyle(workspace.manualCommit ? Color.orange : PortSQLPalette.ink)
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: Sizes.control)
                .background(workspace.manualCommit ? Color.orange.opacity(0.12) : PortSQLPalette.sunken,
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(PortSQLPalette.stroke, lineWidth: 1)
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .disabled(workspace.isRunning)
            if workspace.manualCommit {
                Button { workspace.finishTransaction(commit: true) } label: {
                    Label("Commit", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).toolIconChrome(tint: .green)
                }
                .buttonStyle(.plain)
                .disabled(workspace.isRunning || !workspace.hasOpenTransaction)
                Button { workspace.finishTransaction(commit: false) } label: {
                    Label("Rollback", systemImage: "arrow.uturn.backward.circle.fill").labelStyle(.iconOnly).toolIconChrome(tint: .orange)
                }
                .buttonStyle(.plain)
                .disabled(workspace.isRunning || !workspace.hasOpenTransaction)
            }
        }
    }
}
