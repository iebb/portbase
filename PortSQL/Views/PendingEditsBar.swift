import SwiftUI

/// Staged grid edits waiting to be written, with Revert and Submit. Hidden while nothing is pending.
struct PendingEditsBar: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if !workspace.pendingCellEdits.isEmpty || workspace.pendingEditError != nil {
            HStack(spacing: Spacing.s) {
                Image(systemName: workspace.pendingEditError == nil ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(workspace.pendingEditError == nil ? Color.orange : Color.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if !workspace.pendingCellEdits.isEmpty {
                        Text(L10n.format("Pending changes: %d", workspace.pendingCellEdits.count))
                            .font(.captionStrong)
                        Text(L10n.format("Rows: %d", workspace.pendingEditedRowCount))
                            .font(.captionText).foregroundStyle(.secondary)
                    }
                    if let error = workspace.pendingEditError {
                        Text(error).font(.captionText).foregroundStyle(.red).lineLimit(3)
                    }
                }
                Spacer(minLength: Spacing.s)
                if workspace.pendingCellEdits.isEmpty {
                    Button { workspace.pendingEditError = nil } label: {
                        Image(systemName: "xmark").frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                } else {
                    Button("Revert", systemImage: "arrow.uturn.backward") { workspace.discardPendingEdits() }
                        .buttonStyle(.portbaseSecondary)
                        .disabled(workspace.isSubmittingPendingEdits)
                    Button {
                        workspace.submitPendingEdits()
                    } label: {
                        if workspace.isSubmittingPendingEdits { ProgressView().controlSize(.small) }
                        else { Label("Submit", systemImage: "checkmark") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PortSQLPalette.accent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(workspace.isSubmittingPendingEdits)
                    .frame(minHeight: Sizes.touchTarget)
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(Color.orange.opacity(0.1))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
