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
                    .buttonStyle(.portbasePrimary)
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

extension View {
    /// Asks before an action discards staged grid edits, such as a reload, page change, or switching tables.
    func pendingEditsDiscardPrompt(_ workspace: WorkspaceViewModel) -> some View {
        alert(
            L10n.text("Discard unsubmitted changes?"),
            isPresented: Binding(get: { workspace.pendingDiscardRequest != nil },
                                 set: { if !$0 { workspace.pendingDiscardRequest = nil } }),
            presenting: workspace.pendingDiscardRequest
        ) { request in
            // The actions use the presented request, so dismissal order can't drop the choice.
            Button(L10n.text("Discard Changes"), role: .destructive) { workspace.discardPendingEdits(andContinue: request) }
            Button(L10n.text("Keep Editing"), role: .cancel) { workspace.keepPendingEdits(request) }
        } message: { _ in
            Text(L10n.format("Pending changes: %d", workspace.pendingCellEdits.count) + "\n"
                 + L10n.text("Submit them first to keep them, or discard them to continue."))
        }
    }
}
