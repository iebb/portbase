import SwiftUI

enum WorkspaceLayout {
    static func usesColumns(width: CGFloat, height: CGFloat, regularWidth: Bool, accessibilitySize: Bool) -> Bool {
        regularWidth && !accessibilitySize && width >= 780 && height >= 400
    }
}

// AnyLayout preserves view identity, editor focus, and sheets while the window changes size.
struct AdaptiveWorkspaceView<Leading: View, Trailing: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GeometryReader { geometry in
#if os(macOS)
            let regularWidth = true
#else
            let regularWidth = horizontalSizeClass == .regular
#endif
            let columns = WorkspaceLayout.usesColumns(width: geometry.size.width, height: geometry.size.height,
                regularWidth: regularWidth, accessibilitySize: dynamicTypeSize.isAccessibilitySize)
            let layout = columns ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            ScrollView {
                layout {
                    leading.frame(maxWidth: .infinity, alignment: .topLeading)
                    trailing.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(12)
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

struct ExplorerWorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var showsConsole = false
    @State private var search = ""
    @State private var preferredColumn: NavigationSplitViewColumn = .detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List {
              if let profile = workspace.selectedBookmark {
                Section {
                    HStack(spacing: 12) {
                        BookmarkAvatar(profile: profile, size: 40, cornerRadius: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(workspace.activeDatabaseName ?? profile.engine.rawValue)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if workspace.isLoadingSchema { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
              }
              if workspace.selectedBookmark?.engine.supportsSchemaObjects == true {
                Section {
                    NavigationLink { SchemaBrowserView() } label: { Label("Database Objects", systemImage: "square.stack.3d.up") }
                }
              }
              Section {
                ForEach(workspace.schemaCatalog.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }) { table in
                    let selected = workspace.selectedExplorerTableID == table.id
                    Button {
                        workspace.selectExplorerTable(table)
                        preferredColumn = .detail
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: workspace.isDocumentDatabase ? "doc.on.doc.fill" : (table.objectKind?.symbol ?? "tablecells"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selected ? .white : PortSQLPalette.accent)
                                .frame(width: 28, height: 28)
                                .background(selected ? AnyShapeStyle(PortSQLPalette.accentGradient) : AnyShapeStyle(PortSQLPalette.accent.opacity(0.12)),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(table.name)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(PortSQLPalette.ink)
                                    .lineLimit(1)
                                let details = [table.schemaName.isEmpty ? nil : table.schemaName,
                                               table.columns.isEmpty ? nil : L10n.plural("column_count_short", count: table.columns.count)].compactMap { $0 }
                                if !details.isEmpty {
                                    Text(details.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            if let estimate = table.rowCountEstimate {
                                Text(estimate.formatted(.number.notation(.compactName)))
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(PortSQLPalette.sunken, in: Capsule())
                                    .accessibilityLabel(L10n.plural("row_count", count: estimate))
                            }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected ? PortSQLPalette.accent.opacity(0.10) : nil)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .contextMenu {
                        Button("Query", systemImage: "terminal") { workspace.queryText = workspace.defaultQuery(for: table) }
                        Button("Copy Name", systemImage: "doc.on.doc") { PortbaseClipboard.copy(table.displayName) }
                        if workspace.selectedBookmark?.engine.supportsSchemaObjects == true {
                            NavigationLink("Structure") {
                                SchemaObjectView(object: SchemaObject(id: table.displayName, schema: table.schemaName, name: table.name, kind: table.objectKind ?? .table))
                            }
                        }
                    }
                }
              } header: {
                  Text(workspace.isDocumentDatabase ? L10n.text("Collections") : L10n.text("Tables"))
              }
            }
            .overlay {
                if workspace.selectedBookmark != nil, workspace.schemaCatalog.isEmpty, !workspace.isLoadingSchema {
                    ContentUnavailableView(workspace.isDocumentDatabase ? L10n.text("No collections") : L10n.text("No tables"),
                                           systemImage: "tablecells",
                                           description: Text(workspace.schemaErrorMessage ?? L10n.text("Choose a database or refresh the schema.")))
                }
            }
            .searchable(text: $search, prompt: workspace.isDocumentDatabase ? L10n.text("Search collections") : L10n.text("Search tables"))
            .navigationTitle(workspace.isDocumentDatabase ? L10n.text("Collections") : L10n.text("Tables"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            if showsConsole {
                WorkbenchView()
            } else if workspace.selectedBookmark?.engine == .redis {
                RedisExplorerView()
            } else if workspace.selectedBookmark?.engine == .elasticsearch {
                ElasticsearchExplorerView()
            } else if workspace.isDocumentDatabase {
                MongoExplorerView()
            } else {
                ExplorerView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) { if !showsConsole { ConnectionStatusLine() } }
    }
}
