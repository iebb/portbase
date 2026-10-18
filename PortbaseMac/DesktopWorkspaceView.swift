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
        case home, connections, console, explorer, structure, charts
        var title: String {
            switch self {
            case .home: "Home"; case .connections: "Connections"; case .console: "Console"; case .explorer: "Explorer"
            case .structure: "Structure"; case .charts: "Charts"
            }
        }
        var symbol: String {
            switch self {
            // The same symbols as the iOS destinations.
            case .home: "house"; case .connections: "server.rack"; case .console: "terminal"; case .explorer: "square.stack.3d.up"
            case .structure: "list.bullet.rectangle"; case .charts: "chart.bar.xaxis"
            }
        }
        /// Destinations in the switcher above the workspace; Connections lives in the sidebar.
        static let switcherCases: [Destination] = [.home, .console, .explorer, .structure, .charts]
        /// Pages that aren't about the active connection, so connection banners and auto-navigation stay out of them.
        var isOverview: Bool { self == .home || self == .connections }
    }
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var destination = Destination.home
    @State private var search = ""
    @State private var expandedConnections: Set<UUID> = []
    @State private var expandedDatabases: Set<String> = []
    @State private var showsLibrary = false
    @State private var showsPalette = false
    @State private var deletingProfile: ConnectionProfile?
    @State private var createsSQLite = false
    @ObservedObject private var pinnedTables = PinnedTableStore.shared

    private var pinScope: String {
        PinnedTableStore.scope(profileID: workspace.selectedBookmarkID, database: workspace.activeDatabaseName)
    }

    /// The current connection's tables matching the search, with pinned tables first.
    private func sidebarTables(for profile: ConnectionProfile) -> [SchemaTableDescriptor] {
        let matches = workspace.schemaCatalog.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || profile.name.localizedCaseInsensitiveContains(search)
        }
        let groups = pinnedTables.partition(matches, in: pinScope)
        return groups.pinned + groups.others
    }

    var body: some View {
        withObservers(withSheets(window))
    }

    private var window: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                // The tab strip appears once there's more than one console.
                if consoles.consoles.count > 1 { DesktopConsoleTabs() }
                ConnectionStatusLine()
                if let error = workspace.schemaErrorMessage, workspace.selectedBookmark != nil, !destination.isOverview {
                    ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                }
                Group {
                    switch destination {
                    case .home:
                        HomeView(onNavigate: navigate, onSearch: { showsPalette = true })
                    case .connections:
                        ConnectionsHubView(onOpenConsole: { destination = .console }, onCreateSQLite: { createsSQLite = true },
                                           onDelete: { deletingProfile = $0 })
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
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.captionText).foregroundStyle(.red).padding(Spacing.s)
                }
            }.background(PortSQLPalette.surface)
        }
        .navigationTitle(workspace.selectedBookmark?.displayTitle ?? "Portbase")
        .navigationSubtitle(workspace.selectedBookmark == nil ? "" : (workspace.activeDatabaseName ?? ""))
        .toolbar { toolbarContent }
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showsLibrary) { LibrarySheetView().frame(minWidth: 680, minHeight: 480) }
        .sheet(isPresented: $workspace.isShowingAssistant) {
            AssistantSheet(session: workspace.assistant, onShowConsole: { destination = .console })
                .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 720)
        }
        .sheet(isPresented: $showsPalette) { CommandPaletteView(onNavigate: navigate, onCreateSQLite: { createsSQLite = true }) }
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { destination = .console }
        .sheet(item: $workspace.dataEditorDraft) { _ in DesktopRowEditor().frame(minWidth: 620, minHeight: 360) }
        .sheet(item: $workspace.parameterDraft) { draft in QueryParameterSheet(draft: draft).frame(minWidth: 480, minHeight: 320) }
        .sheet(item: $workspace.selectedProfileForEdit) { profile in BookmarkEditorView(profile: profile).frame(width: 640, height: 600) }
        .pendingEditsDiscardPrompt(workspace)
        .sqlSafetyConfirmation(workspace)
        .focusedSceneObject(workspace)
        .certificateTrustPrompt(workspace)
        .confirmationDialog("Delete Connection?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }), titleVisibility: .visible) {
            Button("Delete Connection", role: .destructive) {
                if let profile = deletingProfile, let index = bookmarks.bookmarks.firstIndex(where: { $0.id == profile.id }) {
                    for console in consoles.consoles where console.workspace.selectedBookmarkID == profile.id { console.workspace.disconnectConsole() }
                    bookmarks.delete(at: IndexSet(integer: index))
                    pinnedTables.removeAll(for: profile.id)
                    ClauseHistoryStore.shared.removeAll(for: profile.id)
                    for console in consoles.consoles where console.workspace.selectedBookmarkID == profile.id { console.workspace.selectBookmark(bookmarks.bookmarks.first?.id) }
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: { Text("Pending transactions on this connection will be rolled back.") }
    }

    private func withObservers<Content: View>(_ content: Content) -> some View {
        content
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
            if !destination.isOverview { destination = .console }
        }
        .onAppear { if let id = workspace.selectedBookmarkID { expandedConnections.insert(id) } }
        .onChange(of: workspace.activeDatabaseName, initial: true) { _, database in
            // The active database opens in the sidebar; switching databases keeps the current destination.
            if let id = workspace.selectedBookmarkID, let database { expandedDatabases.insert(databaseKey(id, database)) }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // macOS 26 wraps toolbar items in a Liquid Glass capsule; the switcher draws its own outline.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                DestinationSwitcher(selection: $destination)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                DestinationSwitcher(selection: $destination)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if workspace.selectedBookmark != nil {
                DatabasePicker().labelsHidden().fixedSize()
                    .help(workspace.selectedBookmark?.endpointSummary ?? "")
            }
            Button("New Console", systemImage: "plus.rectangle.on.rectangle") { consoles.add(); destination = .console }
                .help(L10n.text("New Console"))
            if workspace.selectedBookmark != nil {
                Button("Refresh Schema", systemImage: "arrow.clockwise") { workspace.refreshSchemaCatalog() }
                    .disabled(workspace.isLoadingSchema)
            }
            Button("Query Library", systemImage: "books.vertical") { showsLibrary = true }
            Button("Search", systemImage: "magnifyingglass") { showsPalette = true }
                .help(L10n.text("Search actions, tables, and queries") + " (⌘K)")
        }
    }

    private func navigate(_ target: PortbaseDestination) {
        switch target {
        case .home: destination = .home
        case .servers: destination = .connections
        case .explorer: destination = .explorer
        case .console: destination = .console
        case .charts: destination = .charts
        case .library: showsLibrary = true
        case .settings: openSettings()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PortSQLPalette.muted) }.buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.bodyText)
            .portbaseFieldChrome()
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            List {
                sidebarLink("Home", systemImage: "house.fill", isSelected: destination == .home) { destination = .home }
                sidebarLink("Connections", systemImage: "server.rack", isSelected: destination == .connections) { destination = .connections }
                sidebarLink("Query Library", systemImage: "books.vertical.fill", isSelected: false) { showsLibrary = true }
                Section {
                    ForEach(bookmarks.bookmarks.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id == workspace.selectedBookmarkID }) { profile in
                        DisclosureGroup(isExpanded: Binding(get: { expandedConnections.contains(profile.id) }, set: { if $0 { expandedConnections.insert(profile.id) } else { expandedConnections.remove(profile.id) } })) {
                            if profile.id == workspace.selectedBookmarkID {
                                // Each database is its own collapsible group; the expanded one is active and lists its tables.
                                ForEach(sidebarDatabases, id: \.self) { database in
                                    DisclosureGroup(isExpanded: databaseExpansion(profile.id, database)) {
                                        if database == workspace.activeDatabaseName {
                                            if workspace.isLoadingSchema { ProgressView().controlSize(.small) }
                                            if let error = workspace.schemaErrorMessage {
                                                SidebarConnectionIssueRow(message: error)
                                            }
                                            ForEach(sidebarTables(for: profile)) { table in tableRow(table) }
                                        }
                                    } label: {
                                        databaseRow(profile.id, database)
                                    }
                                }
                            } else {
                                Button("Connect") { workspace.selectBookmark(profile.id); destination = .console }
                            }
                        } label: {
                            Button { workspace.selectBookmark(profile.id); destination = .console } label: {
                                HStack(spacing: Spacing.xs) {
                                    BookmarkAvatar(profile: profile, size: Sizes.avatarSmall, cornerRadius: Radius.s)
                                    Text(profile.displayTitle).lineLimit(1)
                                        .fontWeight(workspace.selectedBookmarkID == profile.id ? .semibold : .regular)
                                    if profile.environment != .none {
                                        Circle().fill(profile.environment.color).frame(width: Sizes.dot, height: Sizes.dot)
                                            .help(profile.environment.title)
                                    }
                                    Spacer(minLength: Spacing.xxs)
                                    if profile.isReadOnly { Image(systemName: "lock.fill").font(.captionText).foregroundStyle(PortSQLPalette.muted) }
                                    if profile.transportSecurityMode == .plaintext && !profile.engine.isLocal {
                                        Image(systemName: "lock.open.fill").foregroundStyle(Color(red: 0.90, green: 0.25, blue: 0.24)).help(L10n.text("Unencrypted"))
                                    }
                                    if workspace.selectedBookmarkID == profile.id, let error = workspace.schemaErrorMessage {
                                        let issue = ConnectionIssue.classify(error)
                                        Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                                            .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04)).help(issue.title)
                                    }
                                    if workspace.selectedBookmarkID == profile.id { Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.35)).frame(width: Sizes.dot, height: Sizes.dot) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .foregroundStyle(workspace.selectedBookmarkID == profile.id ? PortSQLPalette.accent : PortSQLPalette.ink)
                            .contextMenu {
                                Button("Edit Connection") { workspace.selectedProfileForEdit = profile }
                                Button("Duplicate Connection") { workspace.selectedProfileForEdit = profile.duplicate() }
                                Button("New Console") { consoles.add(); consoles.active.workspace.selectBookmark(profile.id) }
                                Button("Refresh Database List") {
                                    if workspace.selectedBookmarkID != profile.id { workspace.selectBookmark(profile.id) }
                                    // Switching can wait on the unsubmitted-edits prompt; refresh only once it's this server.
                                    guard workspace.selectedBookmarkID == profile.id else { return }
                                    expandedConnections.insert(profile.id)
                                    workspace.refreshDatabaseList()
                                }
                                Divider()
                                Button("Delete Connection", role: .destructive) { deletingProfile = profile }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Servers").foregroundStyle(PortSQLPalette.muted)
                        Spacer()
                        Menu {
                            Button("Add Connection") { workspace.createBookmark() }
                            Button("Import Connection String…") { workspace.createBookmark() }
                            Divider()
                            Button("New SQLite Database") { createsSQLite = true }
                        } label: { Image(systemName: "plus").foregroundStyle(PortSQLPalette.muted) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(L10n.text("Add Connection"))
                    }
                }
            }.listStyle(.sidebar).font(.bodyText)
            .scrollContentBackground(.hidden)
        }
        .background(PortSQLPalette.sunken)
    }

    private var sidebarDatabases: [String] {
        var names = workspace.availableDatabases
        if let active = workspace.activeDatabaseName, !names.contains(active) { names.insert(active, at: 0) }
        return names
    }

    private func databaseKey(_ profileID: UUID, _ database: String) -> String { profileID.uuidString + "/" + database }

    /// Expanding a database makes it the active one (only the active database's tables are loaded) and
    /// collapses the server's other databases.
    private func databaseExpansion(_ profileID: UUID, _ database: String) -> Binding<Bool> {
        Binding(get: { expandedDatabases.contains(databaseKey(profileID, database)) }, set: { expanded in
            if expanded {
                expandedDatabases = expandedDatabases.filter { !$0.hasPrefix(profileID.uuidString + "/") }
                expandedDatabases.insert(databaseKey(profileID, database))
                if database != workspace.activeDatabaseName { workspace.selectDatabase(database) }
            } else {
                expandedDatabases.remove(databaseKey(profileID, database))
            }
        })
    }

    private func databaseRow(_ profileID: UUID, _ database: String) -> some View {
        let active = database == workspace.activeDatabaseName
        return Button {
            databaseExpansion(profileID, database).wrappedValue = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: active ? "cylinder.fill" : "cylinder")
                    .foregroundStyle(active ? PortSQLPalette.accent : PortSQLPalette.muted)
                    .frame(width: Sizes.symbolColumn)
                Text(database).lineLimit(1)
                    .foregroundStyle(active ? PortSQLPalette.ink : PortSQLPalette.muted)
                    .fontWeight(active ? .semibold : .medium)
                Spacer(minLength: Spacing.xxs)
                if active, !workspace.schemaCatalog.isEmpty {
                    Text(workspace.schemaCatalog.count.formatted())
                        .font(.captionText.monospacedDigit()).foregroundStyle(PortSQLPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("Database %@", database))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func tableRow(_ table: SchemaTableDescriptor) -> some View {
        let selected = workspace.selectedExplorerTableID == table.id && destination == .explorer
        let pinned = pinnedTables.isPinned(table.displayName, in: pinScope)
        return Button { workspace.selectExplorerTable(table); destination = .explorer } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: workspace.isDocumentDatabase ? "doc.on.doc" : table.objectKind?.symbol ?? "tablecells")
                    .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.muted)
                    .frame(width: Sizes.symbolColumn)
                Text(table.name).lineLimit(1)
                if pinned {
                    Image(systemName: "pin.fill").font(.badgeText).foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                        .accessibilityLabel(L10n.text("Pinned"))
                }
                Spacer(minLength: Spacing.xxs)
                if let estimate = table.rowCountEstimate {
                    Text(estimate.formatted(.number.notation(.compactName)))
                        .font(.captionText.monospacedDigit()).foregroundStyle(PortSQLPalette.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.ink)
        .fontWeight(selected ? .semibold : .regular)
        .contextMenu {
            Button("Query") { workspace.queryText = workspace.defaultQuery(for: table); destination = .console }
            Button("Structure") { workspace.selectedExplorerTableID = table.id; destination = .structure }
            Button("Copy") { PortbaseClipboard.copy(table.displayName) }
            Divider()
            Button(pinned ? L10n.text("Unpin") : L10n.text("Pin")) {
                withAnimation { pinnedTables.toggle(table.displayName, in: pinScope) }
            }
        }
    }

    private func sidebarLink(_ title: LocalizedStringKey, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).foregroundStyle(isSelected ? PortSQLPalette.accent : PortSQLPalette.ink)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(isSelected ? PortSQLPalette.accent : PortSQLPalette.muted)
            }
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var console: some View {
        VSplitView {
            Group {
                if workspace.isDocumentDatabase { DesktopMongoEditor() }
                else if workspace.selectedBookmark?.engine == .elasticsearch { ScrollView { ElasticsearchQueryEditorCard().padding(Spacing.m) } }
                else { DesktopSQLEditor() }
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
            DesktopResultsView().frame(minHeight: 180, idealHeight: 440, maxHeight: .infinity)
        }
    }
}

/// The destination switcher in the window toolbar, with the same symbols as the iOS destinations.
struct DestinationSwitcher: View {
    @Binding var selection: DesktopWorkspaceView.Destination

    var body: some View {
        PortbasePillTabs(selection: $selection, options: DesktopWorkspaceView.Destination.switcherCases.map {
            PortbaseChoice(value: $0, title: L10n.text($0.title), systemImage: $0.symbol)
        })
    }
}

private struct DesktopConsoleTabs: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?
    @State private var discardingID: UUID?
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(consoles.consoles) { console in
                        let selected = consoles.selectedID == console.id
                        HStack(spacing: Spacing.xs) {
                            Button { consoles.select(console.id) } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: console.workspace.isRunning ? "bolt.fill" : "terminal")
                                        .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                                        .symbolEffect(.pulse, isActive: console.workspace.isRunning)
                                    Text(console.title).lineLimit(1)
                                        .fontWeight(selected ? .semibold : .regular)
                                        .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                                    if console.workspace.hasOpenTransaction { Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot) }
                                }.frame(height: Sizes.control).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { close(console.id) } label: { Image(systemName: "xmark").font(.badgeText).frame(width: Sizes.symbolColumn, height: Sizes.symbolColumn) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close Console")
                                .opacity(selected || consoles.consoles.count > 1 ? 1 : 0)
                        }.padding(.horizontal, Spacing.m)
                        .portbaseSelectedSegment(selected)
                        .padding(.vertical, Spacing.xxs).padding(.horizontal, Spacing.xxxs)
                        .contextMenu {
                            Button("Rename") { title = console.title; renamingID = console.id }
                            Button("Close") { close(console.id) }
                        }
                    }
                }.font(.bodyText).padding(.horizontal, Spacing.xs)
            }
            Button("New Console", systemImage: "plus") { consoles.add() }.labelStyle(.iconOnly).buttonStyle(.plain).frame(width: Sizes.tool, height: Sizes.tool)
            Menu {
                if let closed = consoles.closed.first { Button("Reopen Closed Console") { consoles.add(restoring: closed) } }
                Button("Close Console") { close(consoles.selectedID) }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: Sizes.iconTileSmall)
        }.background(PortSQLPalette.canvasAccent)
        .confirmationDialog("Discard Changes and Close Console?", isPresented: Binding(get: { discardingID != nil }, set: { if !$0 { discardingID = nil } })) {
            Button("Discard Changes", role: .destructive) { if let discardingID { close(discardingID, discardingEdits: true) }; discardingID = nil }
            Button("Keep Editing", role: .cancel) { discardingID = nil }
        } message: {
            Text("Cell edits in this console haven't been submitted.")
        }
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
    /// Asks before closing a console with unsubmitted cell edits, then before rolling back an open transaction.
    private func close(_ id: UUID, discardingEdits: Bool = false) {
        let workspace = consoles.consoles.first(where: { $0.id == id })?.workspace
        if !discardingEdits, workspace?.pendingCellEdits.isEmpty == false { discardingID = id }
        else if workspace?.hasOpenTransaction == true { closingID = id }
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
            HStack(spacing: Spacing.m) {
                Button {
                    if workspace.isRunning { workspace.cancelQuery() } else { workspace.runQuery() }
                } label: {
                    Label(workspace.isRunning ? L10n.text("Cancel") : (workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run Query")),
                          systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                        .font(.cardTitle)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.m).frame(height: Sizes.control)
                        .background(workspace.isRunning ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(PortSQLPalette.accentGradient),
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .opacity(workspace.selectedBookmark == nil ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(workspace.selectedBookmark == nil)
                if isSQL {
                    Button("Run All", systemImage: "play.rectangle") { workspace.runQuery(entireBuffer: true) }.disabled(workspace.isRunning || workspace.selectedBookmark == nil)
                    Divider().frame(height: Spacing.l)
                    Button("Format", systemImage: "text.alignleft") { workspace.formatQuery() }
                    Button("Explain", systemImage: "waveform.path.ecg") { workspace.runExplain() }.disabled(workspace.selectedBookmark == nil || workspace.isRunning)
                    SQLTemplateMenu(compact: false).portbaseToolbarMenu()
                    Button("Ask AI", systemImage: "sparkles") { workspace.isShowingAssistant = true }
                        .help(L10n.text("Ask an AI model to write a query or design a chart"))
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
                } label: { Label("Editor", systemImage: "ellipsis") }.labelStyle(.iconOnly).portbaseToolbarMenu()
                DesktopTransactions()
            }.buttonStyle(.portbaseToolbar).font(.bodyText).portbaseBar(Sizes.toolbar)
            Divider()
            HighlightedQueryEditor(text: $workspace.queryText, cursorOffset: $workspace.queryCursorOffset,
                                   selectionLength: $workspace.querySelectionLength, colorScheme: colorScheme, isJSON: workspace.usesJSONEditor,
                                   allowsSQLComments: isSQL, suggestions: workspace.suggestions, errorRange: workspace.queryErrorRange)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().layoutPriority(1)
            HStack(spacing: Spacing.s) {
                Text(workspace.editorPositionLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if let error = workspace.errorMessage {
                    Label(ConnectionIssue.isConnectionProblem(error) ? ConnectionIssue.classify(error).title : error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).lineLimit(1).truncationMode(.tail).help(error)
                        .layoutPriority(-1)
                }
                if let execution = workspace.lastExecution { ExecutionStatusChip(entry: execution) }
                PortbaseChip(title: isSQL ? "SQL" : workspace.usesJSONEditor ? "JSON" : "Redis", tint: .secondary)
            }.font(.rowDetail).portbaseBar(Sizes.statusBar)
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
            // One bar: the table, its filter and sort (Return applies them), and its actions.
            HStack(spacing: Spacing.s) {
                Text(workspace.selectedExplorerTable?.name ?? L10n.text("Tables")).font(.cardTitle).lineLimit(1)
                    .help(workspace.selectedExplorerTable.map { table in
                        [table.displayName, L10n.plural("column_count_short", count: table.columns.count),
                         table.rowCountEstimate.map { L10n.plural("row_count", count: $0) }].compactMap { $0 }.joined(separator: " · ")
                    } ?? "")
                    .layoutPriority(1)
                clauseField(workspace.isDocumentDatabase ? L10n.text("Filter") : "WHERE", text: $workspace.explorerWhereClause, prompt: L10n.text("Filter"), kind: .filter)
                clauseField(workspace.isDocumentDatabase ? L10n.text("Sort") : "ORDER BY", text: $workspace.explorerOrderByClause, prompt: L10n.text("Sort"), kind: .sort)
                    .frame(maxWidth: 260)
                Button("Refresh", systemImage: "arrow.clockwise") { workspace.restartBrowse() }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Refresh"))
                    .disabled(workspace.isRunning || workspace.selectedExplorerTable == nil)
                if workspace.canInsertIntoCurrentTable && workspace.selectedBookmark?.isReadOnly != true {
                    Button("Insert row", systemImage: "plus") { workspace.prepareInsert() }
                        .labelStyle(.iconOnly)
                        .help(L10n.text("Insert row"))
                }
                DataTransferMenu()
            }.font(.bodyText).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.toolbar)
            Divider()
            DesktopResultsView()
        }
        .autoBrowsesSelectedTable(workspace)
    }
}

extension DesktopTableBrowser {
    /// A clause keyword and its field, styled like the sidebar's search field.
    func clauseField(_ keyword: String, text: Binding<String>, prompt: String, kind: ClauseHistoryStore.Kind) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(keyword).font(.codeCaption.weight(.semibold)).foregroundStyle(PortSQLPalette.muted).fixedSize()
            TextField(prompt, text: text).textFieldStyle(.plain).font(.codeDetail).onSubmit { workspace.restartBrowse() }
            ClauseHistoryMenu(kind: kind, text: text)
        }
        .portbaseFieldChrome()
    }
}

private struct DesktopResultsView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var presentation = "table"
    @State private var composerPreset: SavedVisualizationPreset?
    @State private var selectedDocument: MongoDocumentSelection?
    @State private var exportURL: URL?
    @State private var tableMode = "table"
    @AppStorage("Portbase.showsRowDetails") private var showsRowDetails = false
    @State private var focusedRow: Int?
    private var queryPlan: QueryPlan? {
        guard QueryPlanService.isExplainResult(workspace.result) else { return nil }
        return QueryPlanService.plan(from: workspace.result, engine: workspace.selectedBookmark?.engine ?? .postgresql)
    }
    private var chartPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result, connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"), databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }
    private var canChart: Bool { VisualizationService.fieldDescriptors(for: workspace.result).contains(where: \.supportsNumeric) }
    /// Whether the grid is showing; its tool row then carries the result controls, so there's one bar, not two.
    private var showsGrid: Bool {
        guard !workspace.result.columns.isEmpty else { return false }
        if workspace.result.documents != nil { return presentation == "table" }
        if tableMode == "plan" && queryPlan != nil { return false }
        return tableMode != "insights"
    }

    /// Whether the bar above non-grid results has anything to offer; with no result it would hold only a
    /// disabled Export button.
    private var showsResultBar: Bool {
        !workspace.result.columns.isEmpty || workspace.result.documents != nil || workspace.isRunning
            || workspace.isDocumentDatabase || workspace.resultSets.count > 1
    }

    @ViewBuilder private var modeControls: some View {
        HStack(spacing: Spacing.s) {
            if !workspace.result.columns.isEmpty && workspace.result.documents == nil {
                PortbaseSegmentedPicker(selection: $tableMode, options:
                    (queryPlan != nil ? [PortbaseChoice(value: "plan", title: L10n.text("Plan"))] : [])
                    + [PortbaseChoice(value: "table", title: L10n.text("Table")), PortbaseChoice(value: "insights", title: L10n.text("Insights"))])
                    .accessibilityLabel("Results")
            }
            if workspace.result.documents != nil {
                PortbaseSegmentedPicker(selection: $presentation, options: [
                    PortbaseChoice(value: "table", title: L10n.text("Table")), PortbaseChoice(value: "documents", title: L10n.text("Documents")),
                    PortbaseChoice(value: "chart", title: L10n.text("Chart")), PortbaseChoice(value: "insights", title: L10n.text("Insights")),
                ])
                .accessibilityLabel("Results")
            }
            if workspace.resultSets.count > 1 {
                Picker("Result Set", selection: Binding(get: { workspace.selectedResultIndex }, set: { workspace.selectResult($0) })) {
                    ForEach(workspace.resultSets.indices, id: \.self) { index in Text(L10n.format("Result %d", index + 1)).tag(index) }
                }.labelsHidden().fixedSize()
            }
            if workspace.isRunning { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var resultActions: some View {
        HStack(spacing: Spacing.s) {
            if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
            if !workspace.result.columns.isEmpty && workspace.result.documents == nil {
                Toggle(isOn: $showsRowDetails) { Label("Row Details", systemImage: "sidebar.right") }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Show the selected row’s fields"))
            }
            if canChart {
                Button("Configure Chart", systemImage: "chart.xyaxis.line") { composerPreset = chartPreset }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Configure Chart"))
            }
            Menu {
                Button("CSV") { exportURL = workspace.exportResultURL(format: .csv) }
                Button("JSON") { exportURL = workspace.exportResultURL(format: .json) }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.text("Export"))
                .disabled(workspace.result.columns.isEmpty && workspace.result.documents == nil)
        }
        .buttonStyle(.portbaseToolbar)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !showsGrid && showsResultBar {
                HStack(spacing: Spacing.s) {
                    modeControls
                    Spacer()
                    resultActions
                }.font(.bodyText).portbaseBar(Sizes.toolbar)
                Divider()
            }
            if let error = workspace.errorMessage {
                Group {
                    if ConnectionIssue.isConnectionProblem(error) {
                        ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                    } else {
                        ScrollView {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .font(.captionText).foregroundStyle(.red).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Spacing.m)
            }
            Group {
                if tableMode == "plan", workspace.result.documents == nil, let queryPlan {
                    ScrollView { QueryPlanView(plan: queryPlan).padding(Spacing.l) }
                } else if (presentation == "insights" && workspace.result.documents != nil) || (tableMode == "insights" && workspace.result.documents == nil && !workspace.result.columns.isEmpty) {
                    ScrollView { ResultInsightsView(result: workspace.result).padding(Spacing.l) }
                } else if presentation == "chart" && workspace.result.documents != nil {
                    if canChart { VisualizationChartPreview(preset: chartPreset, result: workspace.result, compact: false).padding(Spacing.m) }
                    else { Text("Run a query with numeric fields to create a chart.").foregroundStyle(.secondary) }
                } else if presentation == "documents", let documents = workspace.result.documents {
                    ScrollView { MongoDocumentResults(documents: documents, context: MongoDocumentMutationContext.from(workspace: workspace)).padding(Spacing.m) }
                } else if !workspace.result.columns.isEmpty {
                    if showsRowDetails {
                        HSplitView {
                            grid.frame(minWidth: 320)
                            RowDetailsPanel(result: workspace.result, rowIndex: focusedRow)
                                .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
                        }
                    } else { grid }
                }
                else if workspace.result.affectedRowCount != nil {
                    PortbaseEmptyState(title: L10n.text("Statement executed"), message: workspace.result.executionSummary, systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PortbaseEmptyState(title: L10n.text("No live rows yet"), message: L10n.text("Choose a table or run a query to see rows here."), systemImage: "tablecells")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Spacing.s) {
                if !workspace.result.columns.isEmpty || workspace.result.documents != nil {
                    if workspace.result.isTruncated == true { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(workspace.result.executionSummary).lineLimit(1).foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                }
                Spacer()
                if workspace.isShowingExplorerResult {
                    Button("Previous results page", systemImage: "chevron.left") { workspace.goToPreviousExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToPreviousExplorerPage)
                    Menu { ForEach(WorkspaceViewModel.explorerPageSizes, id: \.self) { size in Button(L10n.plural("row_count", count: size)) { workspace.setExplorerPageSize(size) } } } label: { Text(workspace.explorerPageLabel) }
                    Button("Next results page", systemImage: "chevron.right") { workspace.goToNextExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToNextExplorerPage)
                }
            }.font(.rowDetail).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.statusBar)
        }
        .onChange(of: queryPlan != nil, initial: true) { _, hasPlan in
            if hasPlan { tableMode = "plan" } else if tableMode == "plan" { tableMode = "table" }
        }
        .sheet(item: $composerPreset) { preset in VisualizerComposerSheet(initialPreset: preset).frame(minWidth: 680, minHeight: 520) }
        // A chart the assistant proposed opens in the chart editor once its query has run.
        .onChange(of: workspace.isRunning) { _, running in
            if !running, let preset = workspace.consumeAssistantChart() { composerPreset = preset }
        }
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
                var actions = workspace.foreignKeys.filter { $0.columns.contains(workspace.result.columns[column].name) }.map { key in
                    ResultGridRowAction(title: L10n.format("Go to %@", key.referencedTable)) { workspace.followForeignKey(key, row: value) }
                }
                if workspace.canInsertIntoCurrentTable, workspace.selectedBookmark?.isReadOnly != true, workspace.result.documents == nil {
                    actions.insert(ResultGridRowAction(title: L10n.text("Duplicate Row"), symbolName: "plus.square.on.square") {
                        workspace.prepareDuplicate(row: value)
                    }, at: 0)
                }
                return actions
            },
            copyEngine: workspace.selectedBookmark?.engine,
            copyTableName: workspace.result.sourceTableReference ?? workspace.selectedExplorerTable?.displayName,
            onSelectRow: { focusedRow = $0 },
            leadingAccessory: AnyView(modeControls.font(.bodyText)),
            trailingAccessory: AnyView(resultActions.font(.bodyText)),
            onSortDirection: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0, descending: $1) } : nil,
            editCell: { workspace.cellEdit(rowIndex: $0, columnIndex: $1) },
            pendingCells: workspace.pendingGridCells,
            onEditCellText: { workspace.stageCellText(rowIndex: $0, columnIndex: $1, text: $2) },
            onSetCellNull: { workspace.stageCellNull(rowIndex: $0, columnIndex: $1) },
            onRevertCell: { workspace.revertPendingCell(rowIndex: $0, columnIndex: $1) },
            editsBar: AnyView(PendingEditsBar()))
    }
}

private struct DesktopMongoEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var validation: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Picker("Query", selection: $workspace.mongoDraft.mode) { ForEach(MongoEditorMode.allCases) { mode in Text(mode.title).tag(mode) } }.labelsHidden().frame(width: 140)
                Text("Collection").foregroundStyle(.secondary)
                TextField("Collection", text: Binding(get: { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection }, set: { workspace.mongoDraft.collection = $0 })).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button(L10n.text(workspace.isRunning ? "Cancel" : "Run Query"), systemImage: workspace.isRunning ? "stop.fill" : "play.fill") {
                    if workspace.isRunning { workspace.cancelQuery() } else { perform { try workspace.runMongoBuilder() } }
                }.disabled(workspace.selectedBookmark == nil)
                Button("Explain") { perform { try workspace.runMongoBuilder(explain: true) } }.disabled(workspace.isRunning)
            }.font(.bodyText).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.toolbar)
            Divider()
            if workspace.mongoDraft.mode == .command { DesktopSQLEditor() }
            else if workspace.mongoDraft.mode == .find {
                HStack(spacing: Spacing.s) {
                    Text("Skip").foregroundStyle(.secondary); TextField("Skip", text: $workspace.mongoDraft.skip).frame(width: 70)
                    Text("Limit").foregroundStyle(.secondary); TextField("Limit", text: $workspace.mongoDraft.limit).frame(width: 70)
                    Spacer()
                    Button("Save Query") { perform { let command = try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name); workspace.queryText = command; workspace.saveSnippet() } }
                }.font(.bodyText).textFieldStyle(.roundedBorder).padding(.horizontal, Spacing.m).frame(height: Sizes.toolbar)
                HSplitView {
                    DesktopJSONField(title: "Filter (JSON)", text: $workspace.mongoDraft.filter)
                    DesktopJSONField(title: "Projection (JSON)", text: $workspace.mongoDraft.projection)
                    DesktopJSONField(title: "Sort (JSON)", text: $workspace.mongoDraft.sort)
                }
            } else {
                ScrollView {
                    VStack(spacing: Spacing.s) {
                        ForEach($workspace.mongoDraft.stages) { $stage in
                            VStack(spacing: 0) {
                                HStack {
                                    Toggle(isOn: $stage.isEnabled) { Text(verbatim: stage.operation) }.toggleStyle(.checkbox)
                                    Spacer()
                                    Button("Move Up", systemImage: "chevron.up") { move(stage.id, by: -1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.first?.id == stage.id)
                                    Button("Move Down", systemImage: "chevron.down") { move(stage.id, by: 1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.last?.id == stage.id)
                                    Button("Delete", systemImage: "xmark") { workspace.mongoDraft.stages.removeAll { $0.id == stage.id } }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                }.font(.bodyText).padding(Spacing.s)
                                DesktopJSONField(title: "Stage", text: $stage.body).frame(height: 120).disabled(!stage.isEnabled)
                            }.border(Color(nsColor: .separatorColor))
                        }
                        Menu { ForEach(MongoPipelineStage.operations, id: \.self) { operation in Button(operation) { workspace.mongoDraft.stages.append(MongoPipelineStage(operation: operation, body: MongoPipelineStage.template(for: operation))) } } } label: { Label("Add Stage", systemImage: "plus") }.disabled(workspace.mongoDraft.stages.count >= 64)
                    }.padding(Spacing.m)
                }
            }
            if let validation { Text(validation).font(.captionText).foregroundStyle(.red).padding(Spacing.xs) }
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
            Text(L10n.text(title)).font(.rowDetail).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).portbaseBar(Sizes.control)
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
                    Text("Connections, saved queries, and chart configurations sync with iCloud. Passwords, keys, query history, results, and SQLite files stay on this device.").font(.footnoteText).foregroundStyle(.secondary)
                    if let error = bookmarks.cloudSyncError ?? library.cloudSyncError { Text(error).foregroundStyle(.red) }
                    Button("Sync Now") { bookmarks.synchronizeCloud(); library.synchronizeCloud() }
                }
                Section("Library") { NavigationLink("Library Storage") { LibraryStorageView() } }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                AppearanceSettingsSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
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
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
            .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }

            AssistantSettingsView()
                .background(PortSQLPalette.canvasTop)
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .frame(width: 580, height: 520)
    }
}

private struct DesktopRowEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    private func close() { workspace.dismissDataEditor(); dismiss() }

    var body: some View {
        PortbaseSheet(workspace.dataEditorDraft?.mode.title ?? L10n.text("Data Editor"),
                      subtitle: workspace.dataEditorDraft?.table.displayName, onClose: close) {
            ScrollView {
                if let draft = Binding($workspace.dataEditorDraft) {
                    VStack(spacing: Spacing.m) {
                        ForEach(draft.fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                    HStack(spacing: Spacing.xxs) {
                                        Text(verbatim: field.wrappedValue.column.name).font(.codeDetail).foregroundStyle(PortSQLPalette.ink)
                                        if field.wrappedValue.column.isPrimaryKey {
                                            Image(systemName: "key.fill").font(.microText).foregroundStyle(PortSQLPalette.accent).help("Primary key")
                                        }
                                    }
                                    Text(field.wrappedValue.column.type.lowercased()).font(.codeCaption).foregroundStyle(PortSQLPalette.muted)
                                }
                                .frame(width: 160, alignment: .leading)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    DesktopRowValue(field: field)
                                    if let error = workspace.dataEditorValidation[field.wrappedValue.id] {
                                        Label(error, systemImage: "exclamationmark.circle").font(.captionText).foregroundStyle(.red)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                if field.wrappedValue.column.isNullable && field.wrappedValue.isEditable {
                                    Toggle("NULL", isOn: field.isNull).toggleStyle(.checkbox).font(.captionText).frame(width: 62)
                                        .accessibilityHint("Stores a database NULL instead of a value")
                                } else { Spacer().frame(width: 62) }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.l)
                }
            }
            .frame(maxHeight: 600)
            if let error = workspace.dataEditorErrorMessage {
                StatusBanner(title: L10n.text("Save failed"), message: error, tint: .red)
                    .padding(.horizontal, Spacing.xl).padding(.bottom, Spacing.m)
            }
        } footer: {
            if workspace.isSavingMutation { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            if workspace.dataEditorDraft?.mode == .view {
                Button("Done", action: close).buttonStyle(.portbasePrimary).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close).buttonStyle(.portbaseSecondary).disabled(workspace.isSavingMutation)
                Button("Save") { workspace.saveDataEditor() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.isSavingMutation)
            }
        }
        .interactiveDismissDisabled(workspace.isSavingMutation)
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
            if field.isNull { Text("NULL").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: Sizes.control) }
            else if !field.isEditable { Text(field.value.isEmpty ? "\"\"" : field.value).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            else if DataEditorValidationService.isJSONColumn(field.column) {
                VStack(spacing: 0) {
                    HStack {
                        Text("JSON").foregroundStyle(.secondary)
                        Spacer()
                        Button("Format") { if let formatted = DataEditorValidationService.formattedJSON(field.value) { field.value = formatted } }.buttonStyle(.borderless)
                    }.font(.rowDetail).padding(Spacing.xxs)
                    HighlightedQueryEditor(text: $field.value, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true).frame(height: 120)
                }
                .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
            } else {
                TextField(DataEditorValidationService.placeholder(for: field.column), text: $field.value).labelsHidden().textFieldStyle(.plain).autocorrectionDisabled()
                    .portbaseFieldChrome()
                    .accessibilityLabel(field.column.name)
            }
        }.font(.codeText)
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
            HStack(spacing: Spacing.xs) {
                Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                Text(issue.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xxs)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .font(.rowDetail.weight(.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue.guidance)
        .accessibilityLabel(issue.title)
        .accessibilityHint(issue.guidance)
        .popover(isPresented: $showsIssue, arrowEdge: .trailing) {
            ConnectionIssueBanner(message: message,
                                  onEdit: { showsIssue = false; workspace.editCurrentConnection() },
                                  onReconnect: { showsIssue = false; workspace.reconnect() },
                                  onReviewCertificate: { showsIssue = false; workspace.reviewServerCertificate() })
                .padding(Spacing.m)
                .frame(width: 420)
        }
    }
}

/// The fields of one loaded row, listed vertically with their types.
private struct RowDetailsPanel: View {
    let result: QueryResultTable
    let rowIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Row Details").font(.cardTitle)
                Spacer()
                if let rowIndex { Text(L10n.format("Row %d", rowIndex + 1)).font(.captionText).foregroundStyle(.secondary) }
            }
            .portbaseBar()
            Divider()
            if let rowIndex, result.rows.indices.contains(rowIndex) {
                let row = result.rows[rowIndex]
                List {
                    ForEach(result.columns.indices, id: \.self) { index in
                        let cell = row.cells.indices.contains(index) ? row.cells[index] : .null
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack(spacing: Spacing.xs) {
                                Text(result.columns[index].name).font(.captionStrong).foregroundStyle(.secondary)
                                Text(result.columns[index].type.lowercased()).font(.microText).foregroundStyle(.tertiary)
                                Spacer(minLength: Spacing.xxs)
                                Button { PortbaseClipboard.copy(cell.displayValue) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .disabled(cell.isNull)
                                    .help(L10n.text("Copy"))
                            }
                            Group {
                                if cell.isNull {
                                    Text(verbatim: "NULL").italic().foregroundStyle(.tertiary)
                                } else if cell.displayValue.isEmpty {
                                    Text(verbatim: "\"\"").foregroundStyle(.tertiary).help(L10n.text("Empty text"))
                                } else {
                                    Text(cell.displayValue).textSelection(.enabled).lineLimit(12)
                                }
                            }
                            .font(.codeText)
                        }
                        .padding(.vertical, Spacing.xxxs)
                    }
                }
                .listStyle(.inset)
            } else {
                Text("Select a cell to see its row.")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PortSQLPalette.surface)
    }
}
