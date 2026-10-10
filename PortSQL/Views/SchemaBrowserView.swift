import SwiftUI

struct SchemaBrowserView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var objects: [SchemaObject] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(SchemaObjectKind.allCases, id: \.self) { kind in
                let matches = objects.filter { $0.kind == kind && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
                if !matches.isEmpty {
                    Section(kind.title) {
                        ForEach(matches) { object in
                            NavigationLink { SchemaObjectView(object: object) } label: {
                                Label(object.displayName, systemImage: kind.symbol).frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.text("Search database objects"))
        .navigationTitle("Database Objects")
        .overlay { if loading { ProgressView() } }
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let profile = workspace.selectedBookmark else { return }
        loading = true; error = nil
        defer { loading = false }
        do { objects = try await DatabaseService.shared.schemaObjects(profile: profile, database: workspace.activeDatabaseName) }
        catch { self.error = error.localizedDescription }
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
                            Text(column.name).font(.body.monospaced())
                            Spacer()
                            Text(column.type).foregroundStyle(.secondary)
                            if column.isPrimaryKey { Image(systemName: "key.fill").accessibilityLabel("Primary Key") }
                        }
                    }
                }
            }
            if let details {
                if !details.definition.isEmpty {
                    Section("Definition") {
                        ScrollView(.horizontal) {
                            Text(details.definition).font(.callout.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Button("Copy Definition", systemImage: "doc.on.doc") { PortbaseClipboard.copy(details.definition )}
                    }
                }
                if !details.indexes.isEmpty {
                    Section("Indexes") { ForEach(details.indexes, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) } }
                }
                if !details.constraints.isEmpty {
                    Section("Constraints") { ForEach(details.constraints, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) } }
                }
                if !details.foreignKeys.isEmpty {
                    Section("Foreign Keys") {
                        ForEach(details.foreignKeys) { key in
                            NavigationLink {
                                SchemaObjectView(object: SchemaObject(id: key.id, schema: key.referencedSchema, name: key.referencedTable, kind: .table))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key.name)
                                    Text(key.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
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
