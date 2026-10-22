import SwiftUI

/// The console's less frequent tools in one menu, so the toolbar keeps only Run, Run All, Format, and
/// Explain in view. The menu owns every sheet and dialog its items open, since modifiers on a menu nested
/// inside another menu never take effect.
struct ConsoleMoreMenu: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var openLibrary: () -> Void
    var openFullScreen: () -> Void

    @State private var transfer: DataTransferPresentation?
    @State private var importingScript = false
    @State private var pendingScript: String?
    @State private var confirmsReplacement = false
    @State private var sharedScript: SharedConsoleScript?
    @State private var indexes: MongoIndexContext?
    @State private var error: String?

    private var hasResult: Bool { !workspace.result.columns.isEmpty || workspace.result.documents != nil }

    var body: some View {
        Menu {
            Section {
                if workspace.isSQLDatabase { SQLTemplateMenu(compact: false) }
                Button("Save Query", systemImage: "bookmark") { workspace.saveSnippet() }
                    .disabled(script.isEmpty)
                Button("Query Library", systemImage: "books.vertical", action: openLibrary)
                Button(workspace.usesJSONEditor ? "Open JSON editor" : "Open full screen SQL editor",
                       systemImage: "arrow.up.left.and.arrow.down.right", action: openFullScreen)
            }
            Section {
                Menu {
                    if let url = workspace.exportResultURL(format: .csv) { ShareLink(item: url) { Label("CSV", systemImage: "tablecells") } }
                    if let url = workspace.exportResultURL(format: .json) { ShareLink(item: url) { Label("JSON", systemImage: "curlybraces") } }
                } label: { Label("Export Results", systemImage: "square.and.arrow.up") }
                .disabled(!hasResult)
                Button("Import Data…", systemImage: "square.and.arrow.down") { present(.importData) }
                    .disabled(workspace.selectedBookmark?.isReadOnly != false || workspace.selectedBookmark?.engine.supportsDataImport != true)
                Button("Export All Rows…", systemImage: "arrow.down.doc") { present(.exportData) }
                    .disabled(workspace.selectedBookmark?.engine.supportsFullExport != true)
            }
            Section {
                Button("Open Script", systemImage: "folder") { importingScript = true }
                    .disabled(workspace.isRunning)
                Button("Share Script", systemImage: "doc.text") {
                    do { sharedScript = SharedConsoleScript(url: try ScriptFileService.export(script, engine: workspace.selectedBookmark?.engine)) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(script.isEmpty)
            }
            Section {
                if workspace.selectedBookmark?.engine.supportsConsoleTransactions == true {
                    Picker(selection: Binding(get: { workspace.manualCommit }, set: { workspace.setManualCommit($0) })) {
                        Text("Auto-commit").tag(false)
                        Text("Manual Commit").tag(true)
                    } label: { Label("Transactions", systemImage: "arrow.triangle.branch") }
                    .pickerStyle(.menu)
                    .disabled(workspace.isRunning || workspace.hasOpenTransaction)
                }
                if workspace.isDocumentDatabase {
                    Button("Indexes", systemImage: "list.bullet.indent") {
                        if let profile = workspace.selectedBookmark, let database = workspace.activeDatabaseName {
                            indexes = MongoIndexContext(profile: profile, database: database, collection: collection)
                        }
                    }
                    .disabled(collection.isEmpty || workspace.activeDatabaseName == nil)
                }
                if workspace.isSchemaCachingEnabled {
                    Button("Refresh Schema", systemImage: "arrow.clockwise") { workspace.refreshSchemaCatalog() }
                        .disabled(workspace.activeDatabaseName == nil || workspace.isLoadingSchema)
                }
            }
        } label: {
            Image(systemName: "ellipsis").toolIconChrome()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .sheet(item: $transfer) { DataTransferSheet(presentation: $0).portbaseDesktopSheetSize(width: 680, height: 500) }
        .sheet(item: $indexes) { MongoIndexesView(context: $0) }
        .fileImporter(isPresented: $importingScript, allowedContentTypes: [.text, .json, .data]) { result in
            do {
                let text = try ScriptFileService.read(result.get())
                if !script.isEmpty && script != text { pendingScript = text; confirmsReplacement = true } else { open(text) }
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Replace current query?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button("Replace Query", role: .destructive) { if let pendingScript { open(pendingScript) }; pendingScript = nil }
            Button("Cancel", role: .cancel) { pendingScript = nil }
        }
#if canImport(UIKit)
        .sheet(item: $sharedScript) { file in
            ScriptActivitySheet(url: file.url).onDisappear { try? FileManager.default.removeItem(at: file.url) }
        }
#endif
        .alert("Script File", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var collection: String { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection }

    private var script: String {
        if workspace.isDocumentDatabase, workspace.mongoDraft.mode != .command {
            return (try? workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name)) ?? ""
        }
        return workspace.activeBoundQuery?.sql == workspace.queryText ? workspace.activeBoundQuery?.sourceSQL ?? workspace.queryText : workspace.queryText
    }

    private func present(_ mode: DataTransferMode) {
        guard let profile = workspace.selectedBookmark else { return }
        transfer = DataTransferPresentation(mode: mode, profile: profile, database: workspace.activeDatabaseName,
            schema: workspace.schemaCatalog, table: workspace.selectedExplorerTable, query: workspace.transferBoundQuery)
    }

    private func open(_ text: String) {
        guard !workspace.isRunning else { return }
        workspace.activeBoundQuery = nil
        workspace.queryText = text
        workspace.queryCursorOffset = 0
        workspace.querySelectionLength = 0
        if workspace.isDocumentDatabase { workspace.mongoDraft.mode = .command }
        workspace.refreshAssist()
    }
}

private struct SharedConsoleScript: Identifiable { let id = UUID(); let url: URL }

/// Commit and Rollback, in view only while the console is in manual-commit mode, where they're needed.
struct ConsoleCommitControls: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if workspace.manualCommit, workspace.selectedBookmark?.engine.supportsConsoleTransactions == true {
            HStack(spacing: Spacing.xs) {
                if workspace.hasOpenTransaction {
                    Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot)
                        .accessibilityLabel("Transaction open")
                }
                Button { workspace.finishTransaction(commit: true) } label: {
                    Label("Commit", systemImage: "checkmark.circle").labelStyle(.iconOnly).toolIconChrome()
                }
                .disabled(workspace.isRunning || !workspace.hasOpenTransaction)
                Button { workspace.finishTransaction(commit: false) } label: {
                    Label("Rollback", systemImage: "arrow.uturn.backward.circle").labelStyle(.iconOnly).toolIconChrome()
                }
                .disabled(workspace.isRunning || !workspace.hasOpenTransaction)
            }
            .buttonStyle(.plain)
        }
    }
}
