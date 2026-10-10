import SwiftUI

struct MongoIndexesButton: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var selection: MongoIndexContext?
    private var collection: String { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection }

    var body: some View {
        Button {
            if let profile = workspace.selectedBookmark, let database = workspace.activeDatabaseName {
                selection = MongoIndexContext(profile: profile, database: database, collection: collection)
            }
        } label: { Label("Indexes", systemImage: "list.bullet.indent").labelStyle(.iconOnly).toolIconChrome() }
        .buttonStyle(.plain)
        .disabled(collection.isEmpty || workspace.activeDatabaseName == nil)
        .sheet(item: $selection) { MongoIndexesView(context: $0) }
    }
}

struct MongoIndexContext: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let database: String
    let collection: String
}

struct MongoIndexesView: View {
    let context: MongoIndexContext
    @Environment(\.dismiss) private var dismiss
    @State private var indexes: [MongoIndexDescriptor] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var truncated = false

    private var matching: [MongoIndexDescriptor] {
        indexes.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.fields.contains { $0.name.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section { Text(context.database + "." + context.collection).font(.callout.monospaced()) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if truncated { Text("Index results were truncated.").foregroundStyle(.orange) }
                ForEach(matching) { index in
                    NavigationLink {
                        MongoIndexDetailsView(index: index)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(index.name).font(.headline)
                            Text(index.fields.map { $0.name + ": " + $0.direction }.joined(separator: ", ")).font(.caption.monospaced())
                            let flags = [index.unique ? L10n.text("Unique") : nil, index.sparse ? L10n.text("Sparse") : nil,
                                         index.hidden ? L10n.text("Hidden") : nil, index.expiration.map { L10n.format("TTL: %@ s", $0) }].compactMap { $0 }
                            if !flags.isEmpty { Text(flags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if !loading && matching.isEmpty && error == nil { Text("No matching indexes").foregroundStyle(.secondary) }
            }
            .searchable(text: $search, prompt: L10n.text("Search indexes"))
            .navigationTitle("Indexes")
            .portbaseTitleDisplayMode(.inline)
            .overlay { if loading { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading) }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await DatabaseService.shared.mongoIndexes(profile: context.profile, database: context.database, collection: context.collection)
            try Task.checkCancellation()
            indexes = result.indexes; truncated = result.truncated
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct MongoIndexDetailsView: View {
    let index: MongoIndexDescriptor
    var body: some View {
        List {
            Section("Index Keys") {
                ForEach(index.fields) { field in HStack { Text(field.name).font(.body.monospaced()); Spacer(); Text(field.direction).foregroundStyle(.secondary) } }
            }
            Section("Options") {
                LabeledContent("Unique", value: index.unique ? L10n.text("Yes") : L10n.text("No"))
                LabeledContent("Sparse", value: index.sparse ? L10n.text("Yes") : L10n.text("No"))
                LabeledContent("Hidden", value: index.hidden ? L10n.text("Yes") : L10n.text("No"))
                if let expiration = index.expiration { LabeledContent("TTL", value: L10n.format("%@ s", expiration)) }
            }
            Section("Definition") {
                Text(ResultInspectionService.formattedJSON(index.json)).font(.callout.monospaced()).textSelection(.enabled)
                Button("Copy Definition", systemImage: "doc.on.doc") { PortbaseClipboard.copy(index.json )}
            }
        }
        .navigationTitle(index.name)
        .portbaseTitleDisplayMode(.inline)
    }
}
