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
                HStack(spacing: 6) {
                    Image(systemName: workspace.manualCommit ? "hand.raised.fill" : "arrow.triangle.branch")
                    Text(workspace.manualCommit ? L10n.text("Manual Commit") : L10n.text("Auto-commit"))
                        .lineLimit(1)
                    if workspace.hasOpenTransaction {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                            .accessibilityLabel("Transaction open")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(workspace.manualCommit ? Color.orange : PortSQLPalette.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: PortbaseMetrics.toolSize)
                .background(workspace.manualCommit ? Color.orange.opacity(0.12) : PortSQLPalette.sunken,
                            in: RoundedRectangle(cornerRadius: PortbaseMetrics.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PortbaseMetrics.controlRadius, style: .continuous)
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
