import SwiftUI

extension View {
    /// Browses a table selected for the user (the first one after a database loads, or one picked from a
    /// list) like a clicked one, instead of showing its name over an empty grid. Browsing is read-only.
    func autoBrowsesSelectedTable(_ workspace: WorkspaceViewModel) -> some View {
        task(id: workspace.selectedExplorerTableID) {
            guard let table = workspace.selectedExplorerTable, !workspace.isRunning,
                  workspace.result.sourceTableReference != table.displayName else { return }
            workspace.selectExplorerTable(table)
        }
    }
}

/// Recently applied filters or sorts for the current table; choosing one fills the field and applies it.
struct ClauseHistoryMenu: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @ObservedObject private var store = ClauseHistoryStore.shared
    let kind: ClauseHistoryStore.Kind
    @Binding var text: String

    private var entries: [String] {
        workspace.clauseHistoryScope.map { store.history(kind, in: $0) } ?? []
    }

    var body: some View {
        Menu {
            ForEach(entries, id: \.self) { entry in
                Button {
                    text = entry
                    workspace.restartBrowse()
                } label: {
                    Text(verbatim: entry)
                }
            }
            if !entries.isEmpty {
                Divider()
                Button(L10n.text("Clear History"), role: .destructive) {
                    if let scope = workspace.clauseHistoryScope { store.clear(kind, in: scope) }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(entries.isEmpty ? PortSQLPalette.muted.opacity(0.5) : PortSQLPalette.muted)
                .frame(minWidth: Sizes.control, minHeight: Sizes.control)
                .contentShape(Rectangle())
        }
        .portbaseToolbarMenu()
        .disabled(entries.isEmpty)
        .help(kind == .filter ? L10n.text("Recent filters") : L10n.text("Recent sorts"))
        .accessibilityLabel(kind == .filter ? L10n.text("Recent filters") : L10n.text("Recent sorts"))
    }
}
