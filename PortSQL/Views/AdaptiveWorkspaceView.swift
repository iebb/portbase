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
            let layout = columns ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
                                 : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l))
            ScrollView {
                layout {
                    leading.frame(maxWidth: .infinity, alignment: .topLeading)
                    trailing.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(Spacing.l)
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
    @ObservedObject private var pinnedTables = PinnedTableStore.shared

    private var pinScope: String {
        PinnedTableStore.scope(profileID: workspace.selectedBookmarkID, database: workspace.activeDatabaseName)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            List {
              if let profile = workspace.selectedBookmark {
                Section {
                    HStack(spacing: Spacing.m) {
                        BookmarkAvatar(profile: profile, size: Sizes.avatarLarge, cornerRadius: Radius.control)
                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(profile.displayTitle).font(.rowTitle).lineLimit(1)
                            Text(workspace.activeDatabaseName ?? profile.engine.rawValue)
                                .font(.captionText).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if workspace.isLoadingSchema { ProgressView().controlSize(.small) }
                    }
                    .padding(.vertical, Spacing.xxs)
                    .accessibilityElement(children: .combine)
                }
              }
              if workspace.selectedBookmark?.engine.supportsSchemaObjects == true {
                Section {
                    NavigationLink { SchemaBrowserView() } label: { Label("Database Objects", systemImage: "square.stack.3d.up") }
                }
              }
              let filtered = workspace.schemaCatalog.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
              let groups = pinnedTables.partition(filtered, in: pinScope)
              if !groups.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(groups.pinned) { table in tableRow(table) }
                }
              }
              Section {
                ForEach(groups.others) { table in tableRow(table) }
              } header: {
                  Text(workspace.isDocumentDatabase ? L10n.text("Collections") : L10n.text("Tables"))
              }
            }
            .overlay {
                if workspace.selectedBookmark != nil, workspace.schemaCatalog.isEmpty, !workspace.isLoadingSchema {
                    ContentUnavailableView(workspace.isDocumentDatabase ? L10n.text("No collections") : L10n.text("No tables"),
                                           systemImage: "tablecells",
                                           description: Text(workspace.schemaErrorMessage.map { ConnectionIssue.classify($0).title } ?? L10n.text("Choose a database or refresh the schema.")))
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

    private func pinButton(_ table: SchemaTableDescriptor) -> some View {
        let pinned = pinnedTables.isPinned(table.displayName, in: pinScope)
        return Button(pinned ? L10n.text("Unpin") : L10n.text("Pin"), systemImage: pinned ? "pin.slash" : "pin") {
            withAnimation { pinnedTables.toggle(table.displayName, in: pinScope) }
        }
    }

    @ViewBuilder
    private func tableRow(_ table: SchemaTableDescriptor) -> some View {
        let selected = workspace.selectedExplorerTableID == table.id
        Button {
            workspace.selectExplorerTable(table)
            preferredColumn = .detail
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: workspace.isDocumentDatabase ? "doc.on.doc.fill" : (table.objectKind?.symbol ?? "tablecells"))
                    .font(.rowDetail)
                    .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                    .frame(width: Sizes.symbolColumn)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(table.name)
                        .font(.rowDetail.weight(selected ? .semibold : .regular))
                        .foregroundStyle(PortSQLPalette.ink)
                        .lineLimit(1)
                    let details = [table.schemaName.isEmpty ? nil : table.schemaName,
                                   table.columns.isEmpty ? nil : L10n.plural("column_count_short", count: table.columns.count)].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.microText).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.xxs)
                if let estimate = table.rowCountEstimate {
                    Text(estimate.formatted(.number.notation(.compactName)))
                        .font(.microText.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxxs)
                        .background(PortSQLPalette.sunken, in: Capsule())
                        .accessibilityLabel(L10n.plural("row_count", count: estimate))
                }
            }
            .frame(minHeight: Sizes.touchTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? PortSQLPalette.accent.opacity(0.10) : nil)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .swipeActions(edge: .leading) { pinButton(table).tint(.orange) }
        .contextMenu {
            Button("Query", systemImage: "terminal") { workspace.queryText = workspace.defaultQuery(for: table) }
            Button("Copy Name", systemImage: "doc.on.doc") { PortbaseClipboard.copy(table.displayName) }
            pinButton(table)
            if workspace.selectedBookmark?.engine.supportsSchemaObjects == true {
                NavigationLink("Structure") {
                    SchemaObjectView(object: SchemaObject(id: table.displayName, schema: table.schemaName, name: table.name, kind: table.objectKind ?? .table))
                }
            }
        }
    }
}
