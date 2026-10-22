import SwiftUI

/// Compares the current database's tables and columns with another connection's, such as staging with
/// production. Both sides are read with metadata queries only.
struct SchemaCompareView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.dismiss) private var dismiss

    @State private var targetID: UUID?
    @State private var targetDatabase = ""
    @State private var comparison: SchemaComparison?
    @State private var comparing = false
    @State private var error: String?
    @State private var copied = false

    private var candidates: [ConnectionProfile] {
        bookmarks.bookmarks.filter { $0.engine.isRelational }
    }
    private var target: ConnectionProfile? { candidates.first { $0.id == targetID } }
    private var sourceName: String { name(workspace.selectedBookmark, database: workspace.activeDatabaseName) }
    private var targetName: String { name(target, database: targetDatabase.isEmpty ? target?.trimmedDefaultDatabase : targetDatabase) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("This database", value: sourceName)
                    Picker("Compare with", selection: $targetID) {
                        Text("Choose a connection").tag(Optional<UUID>.none)
                        ForEach(candidates) { profile in
                            Text(verbatim: profile.name.isEmpty ? profile.host : profile.name).tag(Optional(profile.id))
                        }
                    }
                    // Labeled, since a list shows a field's prompt rather than its title.
                    LabeledContent("Database") {
                        TextField("Database", text: $targetDatabase, prompt: Text(verbatim: target?.trimmedDefaultDatabase ?? L10n.text("Default")))
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        Task { await compare() }
                    } label: {
                        HStack {
                            Text("Compare")
                            if comparing { Spacer(); ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(target == nil || comparing || workspace.selectedBookmark == nil)
                }
                if let error {
                    Section { ExecutionErrorLine(message: error) }
                }
                if let comparison { results(comparison) }
            }
            .navigationTitle("Compare Schema")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if let comparison {
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied ? L10n.text("Copied") : L10n.text("Copy Report"), systemImage: copied ? "checkmark" : "doc.on.doc") {
                            PortbaseClipboard.copy(comparison.report(source: sourceName, target: targetName))
                            copied = true
                        }
                    }
                }
            }
            .onChange(of: targetID) { _, _ in targetDatabase = ""; comparison = nil; error = nil }
        }
    }

    @ViewBuilder private func results(_ comparison: SchemaComparison) -> some View {
        Section {
            Text(verbatim: summary(comparison)).font(.rowDetail).foregroundStyle(.secondary)
        }
        if !comparison.changed.isEmpty {
            Section(L10n.text("Different")) {
                ForEach(comparison.changed) { table in
                    DisclosureGroup {
                        ForEach(table.columns) { column in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                                Text(verbatim: column.kind == .onlyInSource ? "−" : column.kind == .onlyInTarget ? "+" : "~")
                                    .font(.codeText.weight(.semibold))
                                    .foregroundStyle(column.kind == .onlyInSource ? Color.red : column.kind == .onlyInTarget ? Color.green : Color.orange)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: column.column).font(.codeText)
                                    Text(verbatim: column.details.joined(separator: " · ")).font(.codeCaption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } label: {
                        HStack {
                            Text(verbatim: table.name).font(.codeText)
                            Spacer()
                            Text(L10n.format("Columns: %d", table.columns.count)).font(.captionText).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        tableSection(L10n.format("Only in %@", sourceName), comparison.onlyInSource, mark: "−", tint: .red)
        tableSection(L10n.format("Only in %@", targetName), comparison.onlyInTarget, mark: "+", tint: .green)
    }

    @ViewBuilder private func tableSection(_ title: String, _ tables: [SchemaComparison.TableChange], mark: String, tint: Color) -> some View {
        if !tables.isEmpty {
            Section(title) {
                ForEach(tables) { table in
                    HStack(spacing: Spacing.s) {
                        Text(verbatim: mark).font(.codeText.weight(.semibold)).foregroundStyle(tint).frame(width: 14)
                        Text(verbatim: table.name).font(.codeText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func summary(_ comparison: SchemaComparison) -> String {
        if comparison.isIdentical { return L10n.format("No differences across %d tables.", comparison.identicalTables) }
        return [L10n.format("Different: %d", comparison.changed.count),
                L10n.format("Only here: %d", comparison.onlyInSource.count),
                L10n.format("Only there: %d", comparison.onlyInTarget.count),
                L10n.format("Same: %d", comparison.identicalTables)].joined(separator: " · ")
    }

    private func name(_ profile: ConnectionProfile?, database: String?) -> String {
        guard let profile else { return "—" }
        let connection = profile.name.isEmpty ? profile.host : profile.name
        guard let database, !database.isEmpty else { return connection }
        return connection + " / " + database
    }

    private func compare() async {
        guard let target, let source = workspace.selectedBookmark else { return }
        comparing = true
        error = nil
        defer { comparing = false }
        do {
            // The current side uses the catalog already loaded; the other is read fresh.
            let sourceCatalog = workspace.schemaCatalog.isEmpty
                ? try await DatabaseService.shared.loadSchema(profile: source, database: workspace.activeDatabaseName)
                : workspace.schemaCatalog
            let database = targetDatabase.trimmingCharacters(in: .whitespaces)
            let targetCatalog = try await DatabaseService.shared.loadSchema(profile: target, database: database.isEmpty ? nil : database)
            comparison = SchemaComparison.compare(source: sourceCatalog, target: targetCatalog)
            copied = false
        } catch is CancellationError {
        } catch {
            self.error = DatabaseErrorFormatter.message(for: error)
        }
    }
}
