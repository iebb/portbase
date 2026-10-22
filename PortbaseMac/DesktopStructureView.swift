import SwiftUI

/// The database's objects beside the selected object's structure, like a desktop schema browser:
/// a searchable list grouped by kind on the left, columns, indexes, keys, and definition on the right.
struct DesktopStructureView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var onOpenData: (SchemaTableDescriptor) -> Void = { _ in }
    var onQuery: (SchemaTableDescriptor) -> Void = { _ in }
    /// Puts SQL into the console without running it.
    var onOpenSQL: (String) -> Void = { _ in }

    @State private var objects: [SchemaObject] = []
    @State private var search = ""
    @State private var listError: String?
    @State private var loading = false
    @State private var selectedID: String?
    @State private var details: SchemaObjectDetails?
    @State private var detailsError: String?
    @State private var loadingDetails = false
    @State private var showsDiagram = false
    @State private var showsCompare = false

    private var selected: SchemaObject? { objects.first { $0.id == selectedID } }
    private var loadKey: String { (workspace.selectedBookmarkID?.uuidString ?? "") + "/" + (workspace.activeDatabaseName ?? "") }

    var body: some View {
        HStack(spacing: 0) {
            objectList
                .frame(width: 280)
                .background(PortSQLPalette.panel)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PortSQLPalette.canvasTop)
        }
        .task(id: loadKey) { await load() }
        .onChange(of: workspace.selectedExplorerTableID) { _, _ in selectSidebarTable() }
        .sheet(isPresented: $showsDiagram) {
            SchemaDiagramView { table in onOpenData(table) }.portbaseDesktopSheetSize(width: 1100, height: 760)
        }
        .sheet(isPresented: $showsCompare) {
            SchemaCompareView().portbaseDesktopSheetSize(width: 640, height: 640)
        }
    }

    // MARK: Object list

    private var objectList: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                PortbaseSearchField(prompt: L10n.text("Search database objects"), text: $search)
                    .font(.bodyText)
                    .portbaseFieldChrome()
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: Sizes.tool, height: Sizes.tool)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PortSQLPalette.muted)
                .disabled(loading)
                .help(L10n.text("Refresh"))
                if workspace.selectedBookmark?.engine.isRelational == true {
                    Button { showsDiagram = true } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted").frame(width: Sizes.tool, height: Sizes.tool)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PortSQLPalette.muted)
                    .help(L10n.text("Schema Diagram"))
                    .accessibilityLabel("Schema Diagram")
                    Button { showsCompare = true } label: {
                        Image(systemName: "arrow.left.arrow.right.square").frame(width: Sizes.tool, height: Sizes.tool)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PortSQLPalette.muted)
                    .help(L10n.text("Compare Schema…"))
                    .accessibilityLabel("Compare Schema…")
                }
            }
            .padding(Spacing.s)
            Divider()
            List(selection: $selectedID) {
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle.fill")
                        .font(.captionText)
                        .foregroundStyle(.red)
                }
                ForEach(SchemaObjectKind.allCases, id: \.self) { kind in
                    let matches = objects.filter { $0.kind == kind && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches) { object in
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: kind.symbol)
                                        .foregroundStyle(PortSQLPalette.muted)
                                        .frame(width: Sizes.symbolColumn)
                                    Text(object.name + (object.signature.isEmpty ? "" : "(" + object.signature + ")"))
                                        .font(.bodyText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: Spacing.xxs)
                                    if showsSchemas {
                                        Text(object.schema).font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
                                    }
                                }
                                .tag(object.id)
                            }
                        } header: {
                            HStack {
                                Text(kind.title)
                                Spacer()
                                Text("\(matches.count)").monospacedDigit()
                            }
                            .font(.captionStrong)
                            .foregroundStyle(PortSQLPalette.muted)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if loading && objects.isEmpty { ProgressView() }
                else if !loading && objects.isEmpty && listError == nil {
                    Text("No database objects").font(.rowDetail).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Schema names only help when objects come from more than one schema.
    private var showsSchemas: Bool { Set(objects.map(\.schema)).count > 1 }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let object = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(object)
                    if let detailsError {
                        StatusBanner(title: L10n.text("Couldn't load database objects"), message: detailsError, tint: .red)
                    }
                    if let table = table(for: object), object.kind != .function, object.kind != .procedure {
                        columnsCard(table)
                    }
                    if let details {
                        if !details.indexes.isEmpty { listCard(L10n.text("Indexes"), systemImage: "list.number", items: details.indexes) }
                        if !details.constraints.isEmpty { listCard(L10n.text("Constraints"), systemImage: "checkmark.shield", items: details.constraints) }
                        if !details.foreignKeys.isEmpty { foreignKeysCard(details.foreignKeys) }
                        if !details.definition.isEmpty {
                            definitionCard(SchemaDDLBuilder.createScript(object, details: details, engine: engine))
                        }
                    } else if loadingDetails {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: object.id) { await loadDetails(object) }
        } else {
            VStack(spacing: Spacing.s) {
                Image(systemName: "list.bullet.rectangle").font(.emptyStateSymbol).foregroundStyle(PortSQLPalette.muted)
                Text("Choose an object").font(.rowTitle)
                Text("Its columns, indexes, keys, and definition appear here.")
                    .font(.footnoteText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ object: SchemaObject) -> some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: object.kind.symbol)
                .font(.tileSymbol)
                .foregroundStyle(PortSQLPalette.accent)
                .frame(width: Sizes.iconTileLarge, height: Sizes.iconTileLarge)
                .background(PortSQLPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(object.name).font(.sectionTitle).foregroundStyle(PortSQLPalette.ink).textSelection(.enabled)
                Text([singular(object.kind), object.schema].joined(separator: " · "))
                    .font(.captionText).foregroundStyle(PortSQLPalette.muted)
            }
            Spacer(minLength: Spacing.m)
            if let table = table(for: object), object.kind != .function, object.kind != .procedure {
                Button("Browse Data", systemImage: "tablecells") { onOpenData(table) }
                    .buttonStyle(.portbaseSecondary)
                Button("Query", systemImage: "terminal") { onQuery(table) }
                    .buttonStyle(.portbaseSecondary)
            }
            copyMenu(object)
        }
    }

    private func card<Content: View>(_ title: String, systemImage: String, count: Int? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Label(title, systemImage: systemImage).font(.cardTitle).foregroundStyle(PortSQLPalette.ink)
                if let count {
                    Text("\(count)").font(.captionText.monospacedDigit()).foregroundStyle(PortSQLPalette.muted)
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.m)
            .frame(height: Sizes.toolbar)
            Divider()
            content()
        }
        .portbaseCardSurface(radius: Radius.control)
    }

    private func columnsCard(_ table: SchemaTableDescriptor) -> some View {
        card(L10n.text("Columns"), systemImage: "tablecells", count: table.columns.count) {
            VStack(spacing: 0) {
                columnRow(name: Text("Name"), type: Text("Type"), nullable: Text("Null"), key: Text("Key"))
                    .font(.captionStrong)
                    .foregroundStyle(PortSQLPalette.muted)
                    .background(PortSQLPalette.sunken)
                ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                    // Primary keys can't hold NULL, whatever the catalog reports (SQLite's INTEGER PRIMARY KEY).
                    let nullable = column.isNullable && !column.isPrimaryKey
                    Divider()
                    columnRow(
                        name: Text(column.name).font(.codeText).foregroundStyle(PortSQLPalette.ink),
                        type: Text(column.type.lowercased()).font(.codeDetail).foregroundStyle(PortSQLPalette.muted),
                        nullable: Text(nullable ? L10n.text("Yes") : L10n.text("No"))
                            .foregroundStyle(nullable ? PortSQLPalette.muted : PortSQLPalette.ink),
                        key: keyBadge(column)
                    )
                    .font(.rowDetail)
                    .background(index.isMultiple(of: 2) ? Color.clear : PortSQLPalette.sunken.opacity(0.45))
                }
            }
        }
    }

    private func columnRow<A: View, B: View, C: View, D: View>(name: A, type: B, nullable: C, key: D) -> some View {
        HStack(spacing: Spacing.m) {
            name.frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).textSelection(.enabled)
            type.frame(width: 200, alignment: .leading).lineLimit(1)
            nullable.frame(width: 56, alignment: .leading)
            key.frame(width: 64, alignment: .leading)
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 30)
    }

    @ViewBuilder private func keyBadge(_ column: SchemaColumnDescriptor) -> some View {
        if column.isPrimaryKey {
            PortbaseChip(title: "PK", systemImage: "key.fill", tint: Color(red: 0.96, green: 0.62, blue: 0.04))
        } else if column.isUnique {
            PortbaseChip(title: L10n.text("Unique"), tint: PortSQLPalette.accent)
        } else {
            Text(verbatim: "")
        }
    }

    private func listCard(_ title: String, systemImage: String, items: [String]) -> some View {
        card(title, systemImage: systemImage, count: items.count) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider() }
                    Text(verbatim: item)
                        .font(.codeDetail)
                        .foregroundStyle(PortSQLPalette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                }
            }
        }
    }

    private func foreignKeysCard(_ keys: [SchemaForeignKey]) -> some View {
        card(L10n.text("Foreign Keys"), systemImage: "link", count: keys.count) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    if index > 0 { Divider() }
                    Button {
                        if let target = objects.first(where: { $0.schema == key.referencedSchema && $0.name == key.referencedTable }) {
                            selectedID = target.id
                        }
                    } label: {
                        HStack(spacing: Spacing.s) {
                            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                Text(key.name).font(.rowDetail.weight(.medium)).foregroundStyle(PortSQLPalette.ink)
                                Text(key.summary).font(.codeCaption).foregroundStyle(PortSQLPalette.muted)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.captionStrong).foregroundStyle(PortSQLPalette.muted)
                        }
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.format("Show %@", key.referencedSchema + "." + key.referencedTable))
                }
            }
        }
    }

    private var engine: DatabaseEngine { workspace.selectedBookmark?.engine ?? .postgresql }

    /// Copies the object's name or SQL for it; statements with values use named parameters.
    private func copyMenu(_ object: SchemaObject) -> some View {
        let columns = table(for: object)?.columns ?? []
        let isRelation = object.kind != .function && object.kind != .procedure
        return Menu {
            Button("Copy Name") { PortbaseClipboard.copy(object.displayName) }
            if isRelation, !columns.isEmpty {
                Button("Copy Column Names") { PortbaseClipboard.copy(SchemaDDLBuilder.columnList(columns, engine: engine)) }
            }
            Divider()
            Button("Copy CREATE Statement") {
                if let details { PortbaseClipboard.copy(SchemaDDLBuilder.createScript(object, details: details, engine: engine)) }
            }
            .disabled(details?.definition.isEmpty ?? true)
            Button("Copy DROP Statement") { PortbaseClipboard.copy(SchemaDDLBuilder.dropStatement(object, engine: engine)) }
            if isRelation {
                Divider()
                Button("Copy SELECT Statement") { PortbaseClipboard.copy(SchemaDDLBuilder.selectStatement(object, columns: columns, engine: engine)) }
                if object.kind == .table, !columns.isEmpty {
                    Button("Copy INSERT Statement") { PortbaseClipboard.copy(SchemaDDLBuilder.insertStatement(object, columns: columns, engine: engine)) }
                    Button("Copy UPDATE Statement") { PortbaseClipboard.copy(SchemaDDLBuilder.updateStatement(object, columns: columns, engine: engine)) }
                }
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .menuStyle(.button)
        .buttonStyle(.portbaseSecondary)
        .fixedSize()
    }

    private func definitionCard(_ definition: String) -> some View {
        card(L10n.text("DDL"), systemImage: "chevron.left.forwardslash.chevron.right") {
            VStack(alignment: .trailing, spacing: Spacing.s) {
                ScrollView(.horizontal) {
                    Text(verbatim: definition)
                        .font(.codeDetail)
                        .foregroundStyle(PortSQLPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(Spacing.m)
                }
                HStack(spacing: Spacing.s) {
                    Button("Open in Console", systemImage: "terminal") { onOpenSQL(definition) }
                        .help(L10n.text("Puts the statement in the console without running it"))
                    Button("Copy DDL", systemImage: "doc.on.doc") { PortbaseClipboard.copy(definition) }
                }
                .buttonStyle(.portbaseSecondary)
                .padding([.trailing, .bottom], Spacing.m)
            }
        }
    }

    // MARK: Data

    private func table(for object: SchemaObject) -> SchemaTableDescriptor? {
        workspace.schemaCatalog.first { $0.schemaName == object.schema && $0.name == object.name }
    }

    private func singular(_ kind: SchemaObjectKind) -> String {
        switch kind {
        case .table: L10n.text("Table")
        case .view: L10n.text("View")
        case .materializedView: L10n.text("Materialized View")
        case .function: L10n.text("Function")
        case .procedure: L10n.text("Procedure")
        }
    }

    /// Shows the table chosen in the sidebar, so "Structure" from a table's menu opens that table.
    private func selectSidebarTable() {
        guard let table = workspace.selectedExplorerTable,
              let match = objects.first(where: { $0.schema == table.schemaName && $0.name == table.name }) else { return }
        selectedID = match.id
    }

    private func load() async {
        guard let profile = workspace.selectedBookmark else { objects = []; return }
        loading = true
        listError = nil
        defer { loading = false }
        do {
            objects = try await DatabaseService.shared.schemaObjects(profile: profile, database: workspace.activeDatabaseName)
            if selected == nil { selectSidebarTable() }
            if selected == nil { selectedID = objects.first?.id }
        } catch {
            listError = DatabaseErrorFormatter.message(for: error)
        }
    }

    private func loadDetails(_ object: SchemaObject) async {
        guard let profile = workspace.selectedBookmark else { return }
        details = nil
        detailsError = nil
        loadingDetails = true
        defer { loadingDetails = false }
        do { details = try await DatabaseService.shared.schemaObjectDetails(object, profile: profile, database: workspace.activeDatabaseName) }
        catch { detailsError = error.localizedDescription }
    }
}
