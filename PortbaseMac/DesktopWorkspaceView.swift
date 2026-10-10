import AppKit
import SwiftUI

extension Notification.Name {
    static let portbaseShowCommandPalette = Notification.Name("Portbase.showCommandPalette")
    static let portbaseShowHome = Notification.Name("Portbase.showHome")
    /// The notification's object is a `DesktopWorkspaceView.Destination` raw value.
    static let portbaseShowDestination = Notification.Name("Portbase.showDestination")
}

struct DesktopWorkspaceView: View {
    enum Destination: String, CaseIterable {
        case home, console, explorer, structure, charts
        var title: String {
            switch self { case .home: "Home"; case .console: "Console"; case .explorer: "Explorer"; case .structure: "Structure"; case .charts: "Charts" }
        }
        var symbol: String {
            switch self { case .home: "house"; case .console: "terminal"; case .explorer: "tablecells"; case .structure: "list.bullet.rectangle"; case .charts: "chart.xyaxis.line" }
        }
    }
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var destination = Destination.home
    @State private var search = ""
    @State private var expandedConnections: Set<UUID> = []
    @State private var showsLibrary = false
    @State private var showsPalette = false
    @State private var deletingProfile: ConnectionProfile?
    @State private var createsSQLite = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                DesktopConsoleTabs()
                destinationBar
                Divider()
                ConnectionStatusLine()
                if let error = workspace.schemaErrorMessage, workspace.selectedBookmark != nil, destination != .home {
                    ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                Group {
                    switch destination {
                    case .home:
                        HomeView(onNavigate: navigate, onSearch: { showsPalette = true })
                    case .console: console
                    case .explorer:
                        if workspace.selectedBookmark?.engine == .redis { RedisExplorerView() }
                        else if workspace.selectedBookmark?.engine == .elasticsearch { ElasticsearchExplorerView() }
                        else { DesktopTableBrowser() }
                    case .structure: NavigationStack {
                        if workspace.isDocumentDatabase {
                            if let profile = workspace.selectedBookmark, let database = workspace.activeDatabaseName,
                               let collection = workspace.selectedExplorerTable?.name {
                                MongoIndexesView(context: MongoIndexContext(profile: profile, database: database, collection: collection))
                            } else { Text("Choose a collection").foregroundStyle(.secondary) }
                        } else { SchemaBrowserView() }
                    }
                    case .charts: NavigationStack { VisualizerView() }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = library.storageError ?? consoles.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).padding(8)
                }
            }.background(PortSQLPalette.surface)
        }
        .navigationTitle("Portbase")
        .navigationSubtitle(workspace.selectedBookmark?.displayTitle ?? "")
        .toolbar {
            ToolbarItem(placement: .navigation) { Button("Add Connection", systemImage: "plus") { workspace.createBookmark() } }
            ToolbarItemGroup(placement: .primaryAction) {
                if workspace.selectedBookmark != nil {
                    Button("Refresh Schema", systemImage: "arrow.clockwise") { workspace.refreshSchemaCatalog() }
                        .disabled(workspace.isLoadingSchema)
                }
                Button("Query Library", systemImage: "books.vertical") { showsLibrary = true }
                Button("Search", systemImage: "magnifyingglass") { showsPalette = true }
                    .help(L10n.text("Search actions, tables, and queries") + " (⌘K)")
            }
        }
        .sheet(isPresented: $showsLibrary) { LibrarySheetView().frame(minWidth: 680, minHeight: 480) }
        .sheet(isPresented: $showsPalette) { CommandPaletteView(onNavigate: navigate, onCreateSQLite: { createsSQLite = true }) }
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { destination = .console }
        .sheet(item: $workspace.dataEditorDraft) { _ in DesktopRowEditor().frame(minWidth: 620, minHeight: 360) }
        .sheet(item: $workspace.parameterDraft) { draft in QueryParameterSheet(draft: draft).frame(minWidth: 480, minHeight: 320) }
        .sheet(item: $workspace.selectedProfileForEdit) { profile in BookmarkEditorView(profile: profile).frame(width: 640, height: 600) }
        .alert(item: $workspace.pendingSafetyConfirmation) { pending in
            Alert(title: Text(pending.assessment.title), message: Text(pending.assessment.message),
                  primaryButton: .destructive(Text("Run Anyway")) { workspace.runPendingSafetyConfirmation() },
                  secondaryButton: .cancel { workspace.cancelPendingSafetyConfirmation() })
        }
        .focusedSceneObject(workspace)
        .confirmationDialog("Delete Connection?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }), titleVisibility: .visible) {
            Button("Delete Connection", role: .destructive) {
                if let profile = deletingProfile, let index = bookmarks.bookmarks.firstIndex(where: { $0.id == profile.id }) {
                    for console in consoles.consoles where console.workspace.selectedBookmarkID == profile.id { console.workspace.disconnectConsole() }
                    bookmarks.delete(at: IndexSet(integer: index))
                    for console in consoles.consoles where console.workspace.selectedBookmarkID == profile.id { console.workspace.selectBookmark(bookmarks.bookmarks.first?.id) }
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: { Text("Pending transactions on this connection will be rolled back.") }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowCommandPalette)) { _ in showsPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowHome)) { _ in destination = .home }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowDestination)) { note in
            if let raw = note.object as? String, let target = Destination(rawValue: raw) { destination = target }
        }
        .onChange(of: workspace.queryText) { _, _ in workspace.refreshAssist() }
        .onChange(of: workspace.queryCursorOffset) { _, _ in workspace.refreshAssist() }
        .onChange(of: consoles.selectedID) { _, _ in destination = .console }
        .onChange(of: workspace.selectedBookmarkID) { _, id in
            if let id { expandedConnections.insert(id) }
            if destination != .home { destination = .console }
        }
        .onAppear { if let id = workspace.selectedBookmarkID { expandedConnections.insert(id) } }
        .onChange(of: workspace.activeDatabaseName) { _, _ in if destination != .home { destination = .console } }
    }

    private func navigate(_ target: PortbaseDestination) {
        switch target {
        case .home, .servers: destination = .home
        case .explorer: destination = .explorer
        case .console: destination = .console
        case .charts: destination = .charts
        case .library: showsLibrary = true
        case .settings: openSettings()
        }
    }

    private var destinationBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Destination.allCases, id: \.self) { item in
                    Button { withAnimation(.easeOut(duration: 0.15)) { destination = item } } label: {
                        Label(L10n.text(item.title), systemImage: item.symbol)
                            .font(.system(size: 13, weight: destination == item ? .semibold : .medium))
                            .padding(.horizontal, 11).frame(height: 30)
                            .foregroundStyle(destination == item ? PortSQLPalette.ink : Color.secondary)
                            .background {
                                if destination == item {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PortSQLPalette.surface)
                                        .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
                }
            }
            .padding(3)
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
            Spacer(minLength: 0)
            if let profile = workspace.selectedBookmark {
                HStack(spacing: 7) {
                    Circle()
                        .fill(workspace.errorMessage == nil && workspace.schemaErrorMessage == nil ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    BookmarkAvatar(profile: profile, size: 18, cornerRadius: 5)
                    Text(profile.displayTitle).lineLimit(1).font(.system(size: 13, weight: .medium))
                    DatabasePicker().labelsHidden()
                }
                .help(profile.endpointSummary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(PortSQLPalette.panel)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 30)
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
            .padding(.horizontal, 10).padding(.vertical, 8)
            List {
                Button { destination = .home } label: {
                    Label("Home", systemImage: "house.fill")
                        .foregroundStyle(destination == .home ? PortSQLPalette.accent : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Section("Servers") {
                    ForEach(bookmarks.bookmarks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id == workspace.selectedBookmarkID }) { profile in
                        DisclosureGroup(isExpanded: Binding(get: { expandedConnections.contains(profile.id) }, set: { if $0 { expandedConnections.insert(profile.id) } else { expandedConnections.remove(profile.id) } })) {
                            if profile.id == workspace.selectedBookmarkID {
                                if let database = workspace.activeDatabaseName { Label(database, systemImage: "externaldrive").foregroundStyle(.secondary) }
                                if workspace.isLoadingSchema { ProgressView().controlSize(.small) }
                                if let error = workspace.schemaErrorMessage {
                                    SidebarConnectionIssueRow(message: error)
                                }
                                ForEach(workspace.schemaCatalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || profile.name.localizedCaseInsensitiveContains(search) }) { table in
                                    let selected = workspace.selectedExplorerTableID == table.id && destination == .explorer
                                    Button { workspace.selectExplorerTable(table); destination = .explorer } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: workspace.isDocumentDatabase ? "doc.on.doc" : table.objectKind?.symbol ?? "tablecells")
                                                .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                                                .frame(width: 16)
                                            Text(table.name).lineLimit(1)
                                            Spacer(minLength: 4)
                                            if let estimate = table.rowCountEstimate {
                                                Text(estimate.formatted(.number.notation(.compactName)))
                                                    .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    .foregroundStyle(selected ? PortSQLPalette.accent : .primary)
                                    .fontWeight(selected ? .semibold : .regular)
                                    .contextMenu {
                                        Button("Query") { workspace.queryText = workspace.defaultQuery(for: table); destination = .console }
                                        Button("Structure") { workspace.selectedExplorerTableID = table.id; destination = .structure }
                                        Button("Copy") { PortbaseClipboard.copy(table.displayName) }
                                    }
                                }
                            } else {
                                Button("Connect") { workspace.selectBookmark(profile.id); destination = .console }
                            }
                        } label: {
                            Button { workspace.selectBookmark(profile.id); destination = .console } label: {
                                HStack(spacing: 7) {
                                    BookmarkAvatar(profile: profile, size: 20, cornerRadius: 6)
                                    Text(profile.displayTitle).lineLimit(1)
                                        .fontWeight(workspace.selectedBookmarkID == profile.id ? .semibold : .regular)
                                    Spacer(minLength: 4)
                                    if profile.isReadOnly { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                                    if profile.transportSecurityMode == .plaintext && !profile.engine.isLocal {
                                        Image(systemName: "lock.open.fill").foregroundStyle(.red).help(L10n.text("Unencrypted"))
                                    }
                                    if workspace.selectedBookmarkID == profile.id, let error = workspace.schemaErrorMessage {
                                        let issue = ConnectionIssue.classify(error)
                                        Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange).help(issue.title)
                                    }
                                    if workspace.selectedBookmarkID == profile.id { Circle().fill(Color.green).frame(width: 6, height: 6) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .foregroundStyle(workspace.selectedBookmarkID == profile.id ? PortSQLPalette.accent : .primary)
                            .contextMenu {
                                Button("Edit Connection") { workspace.selectedProfileForEdit = profile }
                                Button("Duplicate Connection") { workspace.selectedProfileForEdit = profile.duplicate() }
                                Button("New Console") { consoles.add(); consoles.active.workspace.selectBookmark(profile.id) }
                                Button("Delete Connection", role: .destructive) { deletingProfile = profile }
                            }
                        }
                    }
                }
            }.listStyle(.sidebar).font(.system(size: 13))
            Divider()
            HStack {
                Menu {
                    Button("Add Connection") { workspace.createBookmark() }
                    Button("Import Connection String…") { workspace.createBookmark() }
                    Button("New SQLite Database") { createsSQLite = true }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 28)
                Spacer()
                Button("New SQLite Database") { createsSQLite = true }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 8).frame(height: 36)
        }
    }

    private var console: some View {
        VSplitView {
            Group {
                if workspace.isDocumentDatabase { DesktopMongoEditor() }
                else if workspace.selectedBookmark?.engine == .elasticsearch { ScrollView { ElasticsearchQueryEditorCard().padding(10) } }
                else { DesktopSQLEditor() }
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
            DesktopResultsView().frame(minHeight: 180, idealHeight: 440, maxHeight: .infinity)
        }
    }
}

private struct DesktopConsoleTabs: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(consoles.consoles) { console in
                        let selected = consoles.selectedID == console.id
                        HStack(spacing: 6) {
                            Button { consoles.select(console.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: console.workspace.isRunning ? "bolt.fill" : "terminal")
                                        .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                                        .symbolEffect(.pulse, isActive: console.workspace.isRunning)
                                    Text(console.title).lineLimit(1)
                                        .fontWeight(selected ? .semibold : .regular)
                                        .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                                    if console.workspace.hasOpenTransaction { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                                }.frame(height: 30).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { close(console.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close Console")
                                .opacity(selected || consoles.consoles.count > 1 ? 1 : 0)
                        }.padding(.horizontal, 10)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(PortSQLPalette.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                            }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 2)
                        .contextMenu {
                            Button("Rename") { title = console.title; renamingID = console.id }
                            Button("Close") { close(console.id) }
                        }
                    }
                }.font(.system(size: 13)).padding(.horizontal, 6)
            }
            Button("New Console", systemImage: "plus") { consoles.add() }.labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 30, height: 30)
            Menu {
                if let closed = consoles.closed.first { Button("Reopen Closed Console") { consoles.add(restoring: closed) } }
                Button("Close Console") { close(consoles.selectedID) }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }.background(PortSQLPalette.canvasAccent)
        .confirmationDialog("Roll Back and Close Console?", isPresented: Binding(get: { closingID != nil }, set: { if !$0 { closingID = nil } })) {
            Button("Rollback and Close", role: .destructive) { if let closingID { consoles.close(closingID, rollback: true) }; closingID = nil }
            Button("Cancel", role: .cancel) { closingID = nil }
        }
        .alert("Rename Console", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Name", text: $title)
            Button("Save") { if let id = renamingID { consoles.rename(id, title: title) }; renamingID = nil }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
    }
    private func close(_ id: UUID) {
        if consoles.consoles.first(where: { $0.id == id })?.workspace.hasOpenTransaction == true { closingID = id }
        else { consoles.close(id) }
    }
}

private struct DesktopSQLEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsGoToLine = false
    @State private var line = "1"
    private var isSQL: Bool { !workspace.isDocumentDatabase && workspace.selectedBookmark?.engine != .redis && workspace.selectedBookmark?.engine != .elasticsearch }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if workspace.isRunning { workspace.cancelQuery() } else { workspace.runQuery() }
                } label: {
                    Label(workspace.isRunning ? L10n.text("Cancel") : (workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run Query")),
                          systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(workspace.isRunning ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(PortSQLPalette.accentGradient),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(workspace.selectedBookmark == nil ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(workspace.selectedBookmark == nil)
                if isSQL {
                    Button("Run All", systemImage: "play.rectangle") { workspace.runQuery(entireBuffer: true) }.disabled(workspace.isRunning || workspace.selectedBookmark == nil)
                    Divider().frame(height: 14)
                    Button("Format", systemImage: "text.alignleft") { workspace.formatQuery() }
                    Button("Explain", systemImage: "waveform.path.ecg") { workspace.runExplain() }.disabled(workspace.selectedBookmark == nil || workspace.isRunning)
                    SQLTemplateMenu(compact: false).menuStyle(.borderlessButton).fixedSize()
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Save Query") { workspace.saveSnippet() }
                    Button("Go to Line") { showsGoToLine = true }.keyboardShortcut("l")
                    if workspace.selectedBookmark?.engine == .redis {
                        Menu("Redis command reference") {
                            ForEach(RedisCommandService.help) { command in
                                Button { workspace.queryText = command.syntax } label: { Text(verbatim: command.syntax) }
                            }
                        }
                    }
                } label: { Label("Editor", systemImage: "ellipsis") }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                DesktopTransactions()
            }.buttonStyle(.borderless).font(.system(size: 13)).padding(.horizontal, 10).frame(height: 40).background(PortSQLPalette.panel)
            Divider()
            HighlightedQueryEditor(text: $workspace.queryText, cursorOffset: $workspace.queryCursorOffset,
                                   selectionLength: $workspace.querySelectionLength, colorScheme: colorScheme, isJSON: workspace.usesJSONEditor,
                                   allowsSQLComments: isSQL, suggestions: workspace.suggestions, errorRange: workspace.queryErrorRange)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().layoutPriority(1)
            HStack(spacing: 8) {
                Text(workspace.editorPositionLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if let error = workspace.errorMessage {
                    Label(ConnectionIssue.isConnectionProblem(error) ? ConnectionIssue.classify(error).title : error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(error)
                        .layoutPriority(-1)
                }
                if let execution = workspace.lastExecution { ExecutionStatusChip(entry: execution) }
                PortbaseChip(title: isSQL ? "SQL" : workspace.usesJSONEditor ? "JSON" : "Redis", tint: .secondary)
            }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 30).background(PortSQLPalette.panel)
        }
        .alert("Go to Line", isPresented: $showsGoToLine) {
            TextField("Line", text: $line)
            Button("Go") {
                let starts = SQLEditingService.lineStarts(in: workspace.queryText)
                if let value = Int(line), starts.indices.contains(value - 1) { workspace.queryCursorOffset = starts[value - 1]; workspace.querySelectionLength = 0 }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct DesktopTransactions: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var body: some View {
        if workspace.selectedBookmark?.engine.supportsConsoleTransactions == true {
            Menu {
                Button("Auto-commit") { workspace.setManualCommit(false) }.disabled(workspace.hasOpenTransaction)
                Button("Manual Commit") { workspace.setManualCommit(true) }
            } label: { Text(L10n.text(workspace.manualCommit ? "Manual Commit" : "Auto-commit")) }.fixedSize()
            if workspace.manualCommit {
                Button("Commit", systemImage: "checkmark") { workspace.finishTransaction(commit: true) }.disabled(!workspace.hasOpenTransaction || workspace.isRunning)
                Button("Rollback", systemImage: "arrow.uturn.backward") { workspace.finishTransaction(commit: false) }.disabled(!workspace.hasOpenTransaction || workspace.isRunning)
            }
        }
    }
}

private struct DesktopTableBrowser: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(workspace.selectedExplorerTable?.displayName ?? L10n.text("Tables")).font(.system(size: 13, weight: .semibold))
                if let table = workspace.selectedExplorerTable {
                    PortbaseChip(title: L10n.plural("column_count_short", count: table.columns.count), tint: .secondary)
                    if let estimate = table.rowCountEstimate { PortbaseChip(title: L10n.plural("row_count", count: estimate), tint: .secondary) }
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { workspace.restartBrowse() }.disabled(workspace.isRunning || workspace.selectedExplorerTable == nil)
                if workspace.canInsertIntoCurrentTable && workspace.selectedBookmark?.isReadOnly != true { Button("Insert row", systemImage: "plus") { workspace.prepareInsert() } }
                DataTransferMenu()
            }.font(.system(size: 13)).buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 44).background(PortSQLPalette.panel)
            HStack(spacing: 8) {
                Text(workspace.isDocumentDatabase ? L10n.text("Filter") : "WHERE").font(.system(size: 12, design: .monospaced))
                TextField("Filter", text: $workspace.explorerWhereClause).font(.system(size: 13, design: .monospaced)).onSubmit { workspace.restartBrowse() }
                Text(workspace.isDocumentDatabase ? L10n.text("Sort") : "ORDER BY").font(.system(size: 12, design: .monospaced))
                TextField("Sort", text: $workspace.explorerOrderByClause).font(.system(size: 13, design: .monospaced)).onSubmit { workspace.restartBrowse() }
                Button("Apply") { workspace.restartBrowse() }.disabled(workspace.isRunning)
            }.textFieldStyle(.roundedBorder).padding(8)
            Divider()
            DesktopResultsView()
        }
    }
}

private struct DesktopResultsView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var presentation = "table"
    @State private var composerPreset: SavedVisualizationPreset?
    @State private var selectedDocument: MongoDocumentSelection?
    @State private var exportURL: URL?
    @State private var tableMode = "table"
    private var chartPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result, connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"), databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }
    private var canChart: Bool { VisualizationService.fieldDescriptors(for: workspace.result).contains(where: \.supportsNumeric) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Results").fontWeight(.semibold)
                if !workspace.result.columns.isEmpty && workspace.result.documents == nil {
                    Picker("Results", selection: $tableMode) {
                        Label("Table", systemImage: "tablecells").tag("table")
                        Label("Insights", systemImage: "sparkles").tag("insights")
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                if workspace.resultSets.count > 1 {
                    Picker("Result Set", selection: Binding(get: { workspace.selectedResultIndex }, set: { workspace.selectResult($0) })) {
                        ForEach(workspace.resultSets.indices, id: \.self) { index in Text(L10n.format("Result %d", index + 1)).tag(index) }
                    }.labelsHidden().frame(width: 120)
                }
                if workspace.result.documents != nil {
                    Picker("Results", selection: $presentation) { Text("Table").tag("table"); Text("Documents").tag("documents"); Text("Chart").tag("chart"); Text("Insights").tag("insights") }
                        .labelsHidden().frame(width: 150)
                }
                if workspace.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
                if canChart { Button("Configure Chart", systemImage: "chart.xyaxis.line") { composerPreset = chartPreset } }
                Menu {
                    Button("CSV") { exportURL = workspace.exportResultURL(format: .csv) }
                    Button("JSON") { exportURL = workspace.exportResultURL(format: .json) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(workspace.result.columns.isEmpty && workspace.result.documents == nil)
            }.font(.system(size: 13)).buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 40).background(PortSQLPalette.panel)
            Divider()
            if let error = workspace.errorMessage {
                Group {
                    if ConnectionIssue.isConnectionProblem(error) {
                        ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect)
                    } else {
                        ScrollView {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
            }
            Group {
                if (presentation == "insights" && workspace.result.documents != nil) || (tableMode == "insights" && workspace.result.documents == nil && !workspace.result.columns.isEmpty) {
                    ScrollView { ResultInsightsView(result: workspace.result).padding(14) }
                } else if presentation == "chart" && workspace.result.documents != nil {
                    if canChart { VisualizationChartPreview(preset: chartPreset, result: workspace.result, compact: false).padding(12) }
                    else { Text("Run a query with numeric fields to create a chart.").foregroundStyle(.secondary) }
                } else if presentation == "documents", let documents = workspace.result.documents {
                    ScrollView { MongoDocumentResults(documents: documents, context: MongoDocumentMutationContext.from(workspace: workspace)).padding(12) }
                } else if !workspace.result.columns.isEmpty { grid }
                else { Text(workspace.result.affectedRowCount != nil ? workspace.result.executionSummary : L10n.text("No live rows yet")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if !workspace.result.columns.isEmpty || workspace.result.documents != nil {
                    if workspace.result.isTruncated == true { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(workspace.result.executionSummary).lineLimit(1).foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                }
                Spacer()
                if workspace.isShowingExplorerResult {
                    Button("Previous results page", systemImage: "chevron.left") { workspace.goToPreviousExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToPreviousExplorerPage)
                    Menu { ForEach([10, 25, 50, 100], id: \.self) { size in Button(L10n.plural("row_count", count: size)) { workspace.setExplorerPageSize(size) } } } label: { Text(workspace.explorerPageLabel) }
                    Button("Next results page", systemImage: "chevron.right") { workspace.goToNextExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToNextExplorerPage)
                }
            }.font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 32).background(PortSQLPalette.panel)
        }
        .sheet(item: $composerPreset) { preset in VisualizerComposerSheet(initialPreset: preset).frame(minWidth: 680, minHeight: 520) }
        .sheet(item: $selectedDocument) { selection in MongoDocumentInspector(selection: selection).frame(minWidth: 600, minHeight: 480) }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) { if let url = exportURL { ScriptActivitySheet(url: url) } }
    }
    private var grid: some View {
        ResultGridView(result: workspace.result, fillsAvailableSpace: true,
            primaryKeys: Set(workspace.isShowingExplorerResult ? workspace.selectedExplorerTable?.primaryKeyColumns.map(\.name) ?? [] : []),
            sortedColumn: workspace.isShowingExplorerResult ? workspace.explorerSortColumn : nil, sortDirection: workspace.explorerSortDirection,
            persistenceKey: [workspace.selectedBookmark?.id.uuidString ?? "", workspace.activeDatabaseName ?? "", workspace.result.sourceTableReference ?? "console"].joined(separator: "."),
            onSort: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0) } : nil,
            onOpenRow: workspace.canEditCurrentRows || workspace.result.documents != nil ? { index in
                if let documents = workspace.result.documents, documents.indices.contains(index) { selectedDocument = MongoDocumentSelection(index: index, json: documents[index], context: MongoDocumentMutationContext.from(workspace: workspace)) }
                else if workspace.result.rows.indices.contains(index) { workspace.prepareEdit(row: workspace.result.rows[index]) }
            } : nil,
            actionsForCell: { row, column in
                guard workspace.result.rows.indices.contains(row), workspace.result.columns.indices.contains(column) else { return [] }
                let value = workspace.result.rows[row]
                return workspace.foreignKeys.filter { $0.columns.contains(workspace.result.columns[column].name) }.map { key in
                    ResultGridRowAction(title: L10n.format("Go to %@", key.referencedTable)) { workspace.followForeignKey(key, row: value) }
                }
            })
    }
}

private struct DesktopMongoEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var validation: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Query", selection: $workspace.mongoDraft.mode) { ForEach(MongoEditorMode.allCases) { mode in Text(mode.title).tag(mode) } }.labelsHidden().frame(width: 140)
                Text("Collection").foregroundStyle(.secondary)
                TextField("Collection", text: Binding(get: { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection }, set: { workspace.mongoDraft.collection = $0 })).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button(workspace.isRunning ? "Cancel" : "Run Query", systemImage: workspace.isRunning ? "stop.fill" : "play.fill") {
                    if workspace.isRunning { workspace.cancelQuery() } else { perform { try workspace.runMongoBuilder() } }
                }.disabled(workspace.selectedBookmark == nil)
                Button("Explain") { perform { try workspace.runMongoBuilder(explain: true) } }.disabled(workspace.isRunning)
            }.font(.system(size: 13)).buttonStyle(.borderless).padding(.horizontal, 10).frame(height: 38).background(PortSQLPalette.panel)
            Divider()
            if workspace.mongoDraft.mode == .command { DesktopSQLEditor() }
            else if workspace.mongoDraft.mode == .find {
                HStack(spacing: 10) {
                    Text("Skip").foregroundStyle(.secondary); TextField("Skip", text: $workspace.mongoDraft.skip).frame(width: 70)
                    Text("Limit").foregroundStyle(.secondary); TextField("Limit", text: $workspace.mongoDraft.limit).frame(width: 70)
                    Spacer()
                    Button("Save Query") { perform { let command = try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name); workspace.queryText = command; workspace.saveSnippet() } }
                }.font(.system(size: 13)).textFieldStyle(.roundedBorder).padding(.horizontal, 10).frame(height: 36)
                HSplitView {
                    DesktopJSONField(title: "Filter (JSON)", text: $workspace.mongoDraft.filter)
                    DesktopJSONField(title: "Projection (JSON)", text: $workspace.mongoDraft.projection)
                    DesktopJSONField(title: "Sort (JSON)", text: $workspace.mongoDraft.sort)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($workspace.mongoDraft.stages) { $stage in
                            VStack(spacing: 0) {
                                HStack {
                                    Toggle(isOn: $stage.isEnabled) { Text(verbatim: stage.operation) }.toggleStyle(.checkbox)
                                    Spacer()
                                    Button("Move Up", systemImage: "chevron.up") { move(stage.id, by: -1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.first?.id == stage.id)
                                    Button("Move Down", systemImage: "chevron.down") { move(stage.id, by: 1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.last?.id == stage.id)
                                    Button("Delete", systemImage: "xmark") { workspace.mongoDraft.stages.removeAll { $0.id == stage.id } }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                }.font(.system(size: 13)).padding(8)
                                DesktopJSONField(title: "Stage", text: $stage.body).frame(height: 120).disabled(!stage.isEnabled)
                            }.border(Color(nsColor: .separatorColor))
                        }
                        Menu { ForEach(MongoPipelineStage.operations, id: \.self) { operation in Button(operation) { workspace.mongoDraft.stages.append(MongoPipelineStage(operation: operation, body: MongoPipelineStage.template(for: operation))) } } } label: { Label("Add Stage", systemImage: "plus") }.disabled(workspace.mongoDraft.stages.count >= 64)
                    }.padding(10)
                }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red).padding(6) }
        }
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = workspace.mongoDraft.stages.firstIndex(where: { $0.id == id }), workspace.mongoDraft.stages.indices.contains(index + delta) else { return }
        workspace.mongoDraft.stages.swapAt(index, index + delta)
    }
    private func perform(_ action: () throws -> Void) { do { try action(); validation = nil } catch { validation = error.localizedDescription } }
}

private struct DesktopJSONField: View {
    let title: String
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursor = 0
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text(title)).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 24).background(PortSQLPalette.panel)
            HighlightedQueryEditor(text: $text, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.frame(minWidth: 150)
    }
}

struct DesktopSettingsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @AppStorage("Portbase.editorFontSize") private var editorFontSize = 13.0
    var body: some View {
        TabView {
            NavigationStack {
            Form {
                Section { AboutHeader() }
                Section("iCloud") {
                    LabeledContent("Status", value: FileManager.default.ubiquityIdentityToken == nil ? L10n.text("Sign in to iCloud in System Settings.") : L10n.text("iCloud available"))
                    Text("Connections, saved queries, and chart configurations sync with iCloud. Passwords, keys, query history, results, and SQLite files stay on this device.").font(.footnote).foregroundStyle(.secondary)
                    if let error = bookmarks.cloudSyncError ?? library.cloudSyncError { Text(error).foregroundStyle(.red) }
                    Button("Sync Now") { bookmarks.synchronizeCloud(); library.synchronizeCloud() }
                }
                Section("Library") { NavigationLink("Library Storage") { LibraryStorageView() } }
            }
            .formStyle(.grouped)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                AppearanceSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                EditorThemeSettingsSection()
                Section("Text Size") {
                    Slider(value: $editorFontSize, in: 10...24, step: 1) { Text("Text Size") }
                    LabeledContent("Size", value: L10n.format("%d pt", Int(editorFontSize)))
                    Button("Reset Text Size") { editorFontSize = 13 }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .frame(width: 580, height: 520)
    }
}

private struct DesktopRowEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(workspace.dataEditorDraft?.mode.title ?? L10n.text("Data Editor")).font(.system(size: 14, weight: .semibold))
                    Text(workspace.dataEditorDraft?.table.displayName ?? "").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(16)
            Divider()
            ScrollView {
                if let draft = Binding($workspace.dataEditorDraft) {
                    VStack(spacing: 12) {
                        ForEach(draft.fields) { field in
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(field.wrappedValue.column.name).font(.system(size: 13, weight: .medium))
                                        if field.wrappedValue.column.isPrimaryKey { Image(systemName: "key.fill").font(.system(size: 11)).help("Primary key") }
                                    }
                                    Text(field.wrappedValue.column.type).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                }.frame(width: 140, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    DesktopRowValue(field: field)
                                    if let error = workspace.dataEditorValidation[field.wrappedValue.id] { Text(error).font(.caption).foregroundStyle(.red) }
                                }.frame(maxWidth: .infinity)
                                if field.wrappedValue.column.isNullable && field.wrappedValue.isEditable {
                                    Toggle("NULL", isOn: field.isNull).toggleStyle(.checkbox).frame(width: 62)
                                        .accessibilityHint("Stores a database NULL instead of a value")
                                } else { Spacer().frame(width: 62) }
                            }
                        }
                    }.padding(16)
                }
            }.frame(maxHeight: 600)
            if let error = workspace.dataEditorErrorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10) }
            Divider()
            HStack {
                if workspace.isSavingMutation { ProgressView().controlSize(.small) }
                Spacer()
                Button(workspace.dataEditorDraft?.mode == .view ? "Done" : "Cancel") { workspace.dismissDataEditor(); dismiss() }.keyboardShortcut(.cancelAction).disabled(workspace.isSavingMutation)
                if workspace.dataEditorDraft?.mode != .view { Button("Save") { workspace.saveDataEditor() }.keyboardShortcut(.defaultAction).disabled(workspace.isSavingMutation) }
            }.padding(12)
        }.interactiveDismissDisabled(workspace.isSavingMutation)
        .onChange(of: workspace.dataEditorDraft == nil) { _, empty in if empty { dismiss() } }
    }
}

private struct DesktopRowValue: View {
    @Binding var field: DataEditorField
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursor = 0
    @State private var selection = 0
    var body: some View {
        Group {
            if field.isNull { Text("NULL").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: 24) }
            else if !field.isEditable { Text(field.value.isEmpty ? "\"\"" : field.value).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            else if DataEditorValidationService.isJSONColumn(field.column) {
                VStack(spacing: 0) {
                    HStack {
                        Text("JSON").foregroundStyle(.secondary)
                        Spacer()
                        Button("Format") { if let formatted = DataEditorValidationService.formattedJSON(field.value) { field.value = formatted } }.buttonStyle(.borderless)
                    }.font(.system(size: 12)).padding(5)
                    HighlightedQueryEditor(text: $field.value, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true).frame(height: 120)
                }.border(Color(nsColor: .separatorColor))
            } else {
                TextField(DataEditorValidationService.placeholder(for: field.column), text: $field.value).labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel(field.column.name)
            }
        }.font(.system(size: 13, design: .monospaced))
    }
}

/// A one-line connection problem in the sidebar; the full explanation opens in a popover.
private struct SidebarConnectionIssueRow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let message: String
    @State private var showsIssue = false

    var body: some View {
        let issue = ConnectionIssue.classify(message)
        Button { showsIssue = true } label: {
            HStack(spacing: 6) {
                Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(issue.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue.guidance)
        .accessibilityLabel(issue.title)
        .accessibilityHint(issue.guidance)
        .popover(isPresented: $showsIssue, arrowEdge: .trailing) {
            ConnectionIssueBanner(message: message,
                                  onEdit: { showsIssue = false; workspace.editCurrentConnection() },
                                  onReconnect: { showsIssue = false; workspace.reconnect() })
                .padding(12)
                .frame(width: 420)
        }
    }
}
