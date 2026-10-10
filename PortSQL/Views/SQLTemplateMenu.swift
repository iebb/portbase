import SwiftUI

/// Inserts starter statements at the cursor. Templates are only inserted, never executed.
struct SQLTemplateMenu: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var compact = true

    private var templates: [SQLTemplate] {
        SQLTemplateService.templates(table: workspace.selectedExplorerTable, engine: workspace.selectedBookmark?.engine ?? .postgresql)
    }

    var body: some View {
        Menu {
            Section(workspace.selectedExplorerTable.map { L10n.format("Templates for %@", $0.name) } ?? L10n.text("Templates")) {
                ForEach(templates.filter { !$0.isWrite }) { template in
                    Button(template.title, systemImage: template.systemImage) { insert(template) }
                }
            }
            if workspace.selectedBookmark?.isReadOnly != true {
                Section(L10n.text("Changes")) {
                    ForEach(templates.filter(\.isWrite)) { template in
                        Button(template.title, systemImage: template.systemImage) { insert(template) }
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: "text.badge.plus").toolIconChrome()
            } else {
                Label("Templates", systemImage: "text.badge.plus")
            }
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Insert SQL template")
        .disabled(!workspace.isSQLDatabase || workspace.isRunning)
    }

    private func insert(_ template: SQLTemplate) {
        let edit = SQLTemplateService.insert(template.sql, into: workspace.queryText,
                                             cursor: workspace.queryCursorOffset, selectionLength: workspace.querySelectionLength)
        workspace.activeBoundQuery = nil
        workspace.queryText = edit.text
        workspace.queryCursorOffset = edit.cursor
        workspace.querySelectionLength = 0
    }
}
