import SwiftUI

struct ElasticsearchExplorerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        AdaptiveWorkspaceView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PanelCard {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Menu {
                            ForEach(workspace.schemaCatalog) { index in
                                Button(index.name) { workspace.selectExplorerTable(index) }
                            }
                        } label: {
                            HStack {
                                Text("Index").font(.rowTitle)
                                Spacer()
                                Text(verbatim: workspace.selectedExplorerTable?.name ?? "_all")
                                    .font(.codeText)
                                Image(systemName: "chevron.down")
                            }.frame(minHeight: Sizes.touchTarget)
                        }
                        .disabled(workspace.schemaCatalog.isEmpty)
                        DisclosureGroup("Mappings") {
                            if let table = workspace.selectedExplorerTable {
                                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                                    ForEach(table.columns) { column in
                                        ViewThatFits(in: .horizontal) {
                                            HStack { Text(verbatim: column.name); Spacer(); Text(verbatim: column.type).foregroundStyle(.secondary) }
                                            VStack(alignment: .leading) { Text(verbatim: column.name); Text(verbatim: column.type).foregroundStyle(.secondary) }
                                        }
                                        .font(.codeCaption).textSelection(.enabled)
                                        .frame(minHeight: Sizes.touchTarget).accessibilityElement(children: .combine)
                                    }
                                }
                            } else { Text("Select an index.").foregroundStyle(.secondary) }
                        }
                        .frame(minHeight: Sizes.touchTarget)
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
