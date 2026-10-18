import SwiftUI

struct SchemaBrowserView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var objects: [SchemaObject] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error {
                StatusBanner(title: L10n.text("Couldn't load database objects"), message: error, tint: .red)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: 0, bottom: Spacing.s, trailing: 0))
            }
            ForEach(SchemaObjectKind.allCases, id: \.self) { kind in
                let matches = objects.filter { $0.kind == kind && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
                if !matches.isEmpty {
                    Section(kind.title) {
                        ForEach(matches) { object in
                            NavigationLink { SchemaObjectView(object: object) } label: {
                                Label(object.displayName, systemImage: kind.symbol).frame(minHeight: Sizes.touchTarget)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PortSQLPalette.canvasTop)
        .searchable(text: $search, prompt: L10n.text("Search database objects"))
        .navigationTitle("Database Objects")
        .overlay {
            if loading { ProgressView() }
            else if objects.isEmpty && error == nil {
                PortbaseEmptyState(title: L10n.text("No database objects"),
                                   message: L10n.text("Tables, views, and routines in this database appear here."),
                                   systemImage: "square.stack.3d.up")
            }
        }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let profile = workspace.selectedBookmark else { return }
        loading = true; error = nil
        defer { loading = false }
        do { objects = try await DatabaseService.shared.schemaObjects(profile: profile, database: workspace.activeDatabaseName) }
        catch { self.error = DatabaseErrorFormatter.message(for: error) }
    }
}

struct SchemaObjectView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let object: SchemaObject
    @State private var details: SchemaObjectDetails?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if let table = workspace.schemaCatalog.first(where: { $0.schemaName == object.schema && $0.name == object.name }),
               object.kind != .function, object.kind != .procedure {
                Section("Columns") {
                    ForEach(table.columns) { column in
                        HStack {
                            Text(column.name).font(.codeText)
                            Spacer()
                            Text(column.type).foregroundStyle(.secondary)
                            if column.isPrimaryKey { Image(systemName: "key.fill").accessibilityLabel("Primary Key") }
                        }
                    }
                }
            }
            if let details {
                if !details.definition.isEmpty {
                    let engine = workspace.selectedBookmark?.engine ?? .postgresql
                    let script = SchemaDDLBuilder.createScript(object, details: details, engine: engine)
                    let columns = workspace.schemaCatalog.first(where: { $0.schemaName == object.schema && $0.name == object.name })?.columns ?? []
                    Section("DDL") {
                        ScrollView(.horizontal) {
                            Text(script).font(.codeDetail).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Button("Copy DDL", systemImage: "doc.on.doc") { PortbaseClipboard.copy(script) }
                        Button("Copy DROP Statement", systemImage: "trash") { PortbaseClipboard.copy(SchemaDDLBuilder.dropStatement(object, engine: engine)) }
                        if object.kind != .function, object.kind != .procedure {
                            Button("Copy SELECT Statement", systemImage: "text.magnifyingglass") {
                                PortbaseClipboard.copy(SchemaDDLBuilder.selectStatement(object, columns: columns, engine: engine))
                            }
                        }
                        if object.kind == .table, !columns.isEmpty {
                            Button("Copy INSERT Statement", systemImage: "plus.rectangle") {
                                PortbaseClipboard.copy(SchemaDDLBuilder.insertStatement(object, columns: columns, engine: engine))
                            }
                            Button("Copy UPDATE Statement", systemImage: "pencil") {
                                PortbaseClipboard.copy(SchemaDDLBuilder.updateStatement(object, columns: columns, engine: engine))
                            }
                        }
                    }
                }
                if !details.indexes.isEmpty {
                    Section("Indexes") { ForEach(details.indexes, id: \.self) { Text($0).font(.codeDetail).textSelection(.enabled) } }
                }
                if !details.constraints.isEmpty {
                    Section("Constraints") { ForEach(details.constraints, id: \.self) { Text($0).font(.codeDetail).textSelection(.enabled) } }
                }
                if !details.foreignKeys.isEmpty {
                    Section("Foreign Keys") {
                        ForEach(details.foreignKeys) { key in
                            NavigationLink {
                                SchemaObjectView(object: SchemaObject(id: key.id, schema: key.referencedSchema, name: key.referencedTable, kind: .table))
                            } label: {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(key.name)
                                    Text(key.summary).font(.codeCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PortSQLPalette.canvasTop)
        .navigationTitle(object.name)
        .portbaseTitleDisplayMode(.inline)
        .overlay { if loading { ProgressView() } }
        .task(id: object.id) {
            guard let profile = workspace.selectedBookmark else { return }
            loading = true; error = nil
            defer { loading = false }
            do { details = try await DatabaseService.shared.schemaObjectDetails(object, profile: profile, database: workspace.activeDatabaseName) }
            catch { self.error = error.localizedDescription }
        }
    }
}
