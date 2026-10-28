import SwiftUI

/// Staged grid edits waiting to be written, with Revert and Submit. Hidden while nothing is pending.
struct PendingEditsBar: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if let notice = workspace.writeWithoutRollbackNotice, !workspace.hasPendingChanges, workspace.pendingEditError == nil {
            // Shown once per database; never in the way of saving.
            HStack(spacing: Spacing.s) {
                Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(notice).font(.captionText).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: Spacing.s)
                Button { workspace.writeWithoutRollbackNotice = nil } label: {
                    Image(systemName: "xmark").frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, Spacing.m)
            .overlay(alignment: .bottom) { Divider() }
        } else if workspace.hasPendingChanges || workspace.pendingEditError != nil {
            HStack(spacing: Spacing.s) {
                Image(systemName: workspace.pendingEditError == nil ? "pencil.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(workspace.pendingEditError == nil ? Color.orange : Color.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if workspace.hasPendingChanges {
                        Text(L10n.format("Pending changes: %d", workspace.pendingChangeCount))
                            .font(.captionStrong)
                    }
                    if let error = workspace.pendingEditError {
                        Text(error).font(.captionText).foregroundStyle(.red).lineLimit(3)
                    }
                }
                Spacer(minLength: Spacing.s)
                if !workspace.hasPendingChanges {
                    Button { workspace.pendingEditError = nil } label: {
                        Image(systemName: "xmark").frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                } else {
                    Button("Revert", systemImage: "arrow.uturn.backward") { workspace.discardPendingEdits() }
                        .buttonStyle(.portbaseSecondary)
                        .disabled(workspace.isSubmittingPendingEdits)
                    Button("Preview", systemImage: "eye") { workspace.isShowingChangePreview = true }
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
            .sheet(isPresented: $workspace.isShowingChangePreview) {
                PendingChangesPreview().portbaseDesktopSheetSize(width: 640, height: 480)
            }
        }
    }
}

/// The statements Submit will run, with their values written in for reading. What runs is the bound
/// statement; the literals here are only for the eye.
struct PendingChangesPreview: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let planned = workspace.plannedPendingWrites()
        let writes = (try? planned.get()) ?? []
        let deletions = writes.filter { $0.kind == .delete }.count
        PortbaseSheet(L10n.text("Pending Changes")) {
            List {
                if case .failure(let error) = planned {
                    ExecutionErrorLine(message: error.message)
                }
                ForEach(writes) { write in
                    Text(verbatim: Self.readable(write.mutation, engine: workspace.selectedBookmark?.engine ?? .postgresql))
                        .font(.codeCaption)
                        .foregroundStyle(write.kind == .delete ? Color.red : PortSQLPalette.ink)
                        .textSelection(.enabled)
                        .padding(.vertical, Spacing.xxs)
                }
            }
            .listStyle(.plain)
        } footer: {
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button {
                workspace.submitPendingEdits(confirmed: true)
            } label: {
                Text(deletions > 0 ? L10n.format("Submit and Delete %d", deletions) : L10n.text("Submit"))
            }
            .buttonStyle(PortbasePrimaryButtonStyle(tint: deletions > 0 ? PortbasePrimaryButtonStyle.portbaseDestructive.tint : nil))
            .disabled(writes.isEmpty || workspace.isSubmittingPendingEdits)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// The statement with each placeholder replaced by its value as a SQL literal, for display only.
    static func readable(_ query: BoundQuery, engine: DatabaseEngine) -> String {
        var text = query.sql
        if engine == .postgresql {
            for index in query.values.indices.reversed() {
                text = text.replacingOccurrences(of: "$\(index + 1)", with: query.values[index].previewLiteral)
            }
            return text
        }
        var output = ""
        var values = query.values.makeIterator()
        var quote: Character?
        for character in text {
            if let open = quote {
                output.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "`" || character == "'" {
                quote = character
                output.append(character)
            } else if character == "?", let value = values.next() {
                output += value.previewLiteral
            } else {
                output.append(character)
            }
        }
        return output
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

extension WorkspaceViewModel {
    /// A result cell's own actions, for both platforms' grids: clone the row, and open the rows it
    /// references or that reference it. Deleting and reverting act on the whole selection in the grid.
    func gridRowActions(rowIndex: Int, columnIndex: Int) -> [ResultGridRowAction] {
        guard result.rows.indices.contains(rowIndex), result.columns.indices.contains(columnIndex) else { return [] }
        let row = result.rows[rowIndex]
        let names = Set(result.columns.map(\.name))
        var actions: [ResultGridRowAction] = []
        if canInsertIntoCurrentTable, selectedBookmark?.isReadOnly != true, result.documents == nil {
            actions.append(ResultGridRowAction(title: L10n.text("Duplicate Row"), symbolName: "plus.square.on.square", shortcut: .cloneRow) { [weak self] in
                self?.prepareDuplicate(row: row)
            })
        }
        actions += foreignKeys.filter { $0.columns.contains(result.columns[columnIndex].name) }.map { key in
            ResultGridRowAction(title: L10n.format("Go to %@", key.referencedTable)) { [weak self] in
                guard let self, self.result.rows.contains(where: { $0.id == row.id }) else { return }
                self.followForeignKey(key, row: row)
            }
        }
        // Rows elsewhere that point at this one, when the columns they point at are in the result.
        actions += referencingKeys.filter { $0.key.referencedColumns.allSatisfy(names.contains) }.map { reference in
            ResultGridRowAction(title: L10n.format("Referenced by %@", reference.table + "." + reference.key.columns.joined(separator: ", ")),
                                symbolName: "arrowshape.turn.up.backward") { [weak self] in
                guard let self, self.result.rows.contains(where: { $0.id == row.id }) else { return }
                self.followReference(reference, row: row)
            }
        }
        return actions
    }
}
