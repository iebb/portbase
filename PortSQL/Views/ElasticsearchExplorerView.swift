import SwiftUI

struct ElasticsearchExplorerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        AdaptiveWorkspaceView {
            VStack(alignment: .leading, spacing: 12) {
                PanelCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Menu {
                            ForEach(workspace.schemaCatalog) { index in
                                Button(index.name) { workspace.selectExplorerTable(index) }
                            }
                        } label: {
                            HStack {
                                Text("Index").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(verbatim: workspace.selectedExplorerTable?.name ?? "_all")
                                    .font(.system(.body, design: .monospaced))
                                Image(systemName: "chevron.down")
                            }.frame(minHeight: 44)
                        }
                        .disabled(workspace.schemaCatalog.isEmpty)
                        DisclosureGroup("Mappings") {
                            if let table = workspace.selectedExplorerTable {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(table.columns) { column in
                                        ViewThatFits(in: .horizontal) {
                                            HStack { Text(verbatim: column.name); Spacer(); Text(verbatim: column.type).foregroundStyle(.secondary) }
                                            VStack(alignment: .leading) { Text(verbatim: column.name); Text(verbatim: column.type).foregroundStyle(.secondary) }
                                        }
                                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .frame(minHeight: 44).accessibilityElement(children: .combine)
                                    }
                                }
                            } else { Text("Select an index.").foregroundStyle(.secondary) }
                        }
                        .frame(minHeight: 44)
                    }
                }
                ElasticsearchQueryEditorCard()
            }
        } trailing: { ResultsCard() }
        .background(WorkbenchBackground().ignoresSafeArea())
#if !os(macOS)
        .navigationTitle("Explorer").portbaseTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: PortbaseToolbar.leading) { ConnectionSwitcherButton(toolbarMode: true) }
            ToolbarItemGroup(placement: PortbaseToolbar.trailing) { SchemaRefreshButton(); DatabaseSwitcherButton() }
        }
#endif
    }
}
