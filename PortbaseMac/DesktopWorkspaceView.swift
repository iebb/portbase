import AppKit
import SwiftUI

extension Notification.Name {
    static let portbaseShowCommandPalette = Notification.Name("Portbase.showCommandPalette")
    static let portbaseShowHome = Notification.Name("Portbase.showHome")
    /// The notification's object is a `DesktopWorkspaceView.Destination` raw value.
    static let portbaseShowDestination = Notification.Name("Portbase.showDestination")
    /// The notification's object is the tab offset, 1 for next or -1 for previous.
    static let portbaseSelectAdjacentTab = Notification.Name("Portbase.selectAdjacentTab")
}

struct DesktopWorkspaceView: View {
    enum Destination: String, CaseIterable {
        case home, connections, console, explorer, structure, charts, assistant
        var title: String {
            switch self {
            case .home: "Home"; case .connections: "Connections"; case .console: "Console"; case .explorer: "Explorer"
            case .structure: "Structure"; case .charts: "Charts"; case .assistant: "Ask AI"
            }
        }
        var symbol: String {
            switch self {
            // The same symbols as the iOS destinations.
            case .home: "house"; case .connections: "server.rack"; case .console: "terminal"; case .explorer: "square.stack.3d.up"
            case .structure: "list.bullet.rectangle"; case .charts: "chart.bar.xaxis"; case .assistant: "sparkles"
            }
        }
        /// The views inside a connection tab.
    }

    /// Sections of the home tab, like Termius's Hosts, Keychain, and Snippets.
    enum HomeSection: String, CaseIterable, Identifiable {
        case servers, charts, queries, activity
        var id: String { rawValue }
        var title: String {
            switch self {
            case .servers: L10n.text("Servers"); case .charts: L10n.text("Charts")
            case .queries: L10n.text("Queries"); case .activity: L10n.text("Activity")
            }
        }
        var symbol: String {
            switch self {
            case .servers: "server.rack"; case .charts: "chart.bar.xaxis"
            case .queries: "books.vertical"; case .activity: "clock.arrow.circlepath"
            }
        }
    }

    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var showsHome: Bool
    @State private var homeSection = HomeSection.servers
    /// Each connection tab's own tabs: its console, open tables, chats, and pages.
    @State private var tabSets: [UUID: SessionTabSet] = [:]
    /// The conversation of each chat tab, by tab.
    @State private var chats: [UUID: AssistantSession] = [:]
    @State private var showsSidebar = true
    @State private var search = ""
    @State private var expandedDatabases: Set<String> = []
    @State private var showsPalette = false
    @State private var deletingProfile: ConnectionProfile?
    @State private var createsSQLite = false
    @State private var windowWidth: CGFloat = 1280
    @ObservedObject private var pinnedTables = PinnedTableStore.shared

    init(startsAtHome: Bool = true) {
        _showsHome = State(initialValue: startsAtHome)
    }

    private var tabs: SessionTabSet { tabSets[consoles.selectedID] ?? SessionTabSet() }
    private var selectedTab: SessionTabSet.Tab { tabs.selected }

    @discardableResult
    private func updateTabs<Result>(_ change: (inout SessionTabSet) -> Result) -> Result {
        var set = tabs
        let result = change(&set)
        tabSets[consoles.selectedID] = set
        return result
    }

    /// Redis and Elasticsearch browse keys and indexes in one page rather than a tab per table.
    private var usesKeyBrowser: Bool { [.redis, .elasticsearch].contains(workspace.selectedBookmark?.engine) }

    private var pinScope: String {
        PinnedTableStore.scope(profileID: workspace.selectedBookmarkID, database: workspace.activeDatabaseName)
    }

    /// The current connection's tables matching the search, with pinned tables first.
    private func sidebarTables(for profile: ConnectionProfile) -> [SchemaTableDescriptor] {
        let matches = workspace.schemaCatalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let groups = pinnedTables.partition(matches, in: pinScope)
        return groups.pinned + groups.others
    }

    var body: some View {
        withObservers(withSheets(window))
    }

    private var window: some View {
        VStack(spacing: 0) {
            Group {
                if showsHome { home } else { session }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Backgrounds extend under the toolbar by default; keep sidebars and pages out of the title bar
            // so the tab strip sits on one even color.
            .clipped()
            if let error = library.storageError ?? consoles.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.captionText).foregroundStyle(.red).padding(Spacing.s)
            }
        }
        .background(PortSQLPalette.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .navigationTitle(showsHome ? "Portbase" : (workspace.selectedBookmark?.displayTitle ?? "Portbase"))
        .toolbar(removing: .title)
        .toolbar { toolbarContent }
        .environment(\.connectionSessionOpener, ConnectionSessionOpener { id, then in openSession(id, then: then) })
    }

    private func show(_ target: Destination) {
        switch target {
        case .home: showsHome = true
        case .connections: homeSection = .servers; showsHome = true
        case .charts:
            // In a connection tab, charts open beside its other tabs.
            if showsHome || workspace.selectedBookmark == nil { homeSection = .charts; showsHome = true }
            else { updateTabs { $0.show(.charts) } }
        case .console: updateTabs { $0.show(.console) }; showsHome = false
        case .structure: updateTabs { $0.show(.structure) }; showsHome = false
        case .assistant: showChat(); showsHome = false
        case .explorer:
            if usesKeyBrowser { updateTabs { $0.show(.explorer) } }
            else if let table = workspace.selectedExplorerTable ?? workspace.schemaCatalog.first { open(table) }
            else { updateTabs { $0.show(.console) } }
            showsHome = false
        }
    }

    /// Shows a table's rows in its tab. A single click previews it in place of the last table previewed.
    private func open(_ table: SchemaTableDescriptor, keeps: Bool = false) {
        if usesKeyBrowser {
            updateTabs { $0.show(.explorer) }
        } else {
            updateTabs { $0.openTable(table.displayName, keeps: keeps) }
        }
        if workspace.selectedExplorerTableID != table.id { workspace.selectExplorerTable(table) }
    }

    private func newChat() {
        // The console's own conversation goes to its first chat, so a chat started elsewhere carries on here.
        let inUse = Set(tabs.chatIDs.compactMap { chats[$0].map(ObjectIdentifier.init) })
        let session = inUse.contains(ObjectIdentifier(workspace.assistant)) ? AssistantSession() : workspace.assistant
        let id = updateTabs { $0.addChat() }
        chats[id] = session
    }

    private func showChat() {
        if tabs.chatIDs.isEmpty { newChat() } else { updateTabs { $0.showChat() } }
    }

    private func closeTab(_ id: UUID) {
        if let session = chats.removeValue(forKey: id) {
            if session === workspace.assistant { session.reset() } else { session.cancel() }
        }
        updateTabs { $0.close(id) }
    }

    private func closeTabs(otherThan id: UUID) {
        for other in tabs.tabs where other.id != id && tabs.canClose(other.id) { closeTab(other.id) }
    }

    /// Opens a connection the way Termius opens a host: in its existing tab, in the current tab when
    /// that tab is still empty, or in a new tab.
    private func openSession(_ id: UUID, then: ((WorkspaceViewModel) -> Void)?) {
        if let existing = consoles.consoles.first(where: { $0.workspace.selectedBookmarkID == id }) {
            consoles.select(existing.id)
        } else if consoles.active.workspace.selectedBookmarkID == nil,
                  consoles.active.workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consoles.active.workspace.selectBookmark(id)
        } else {
            consoles.add()
            consoles.active.workspace.selectBookmark(id)
        }
        then?(consoles.active.workspace)
        showsHome = false
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $showsPalette) { CommandPaletteView(onNavigate: navigate, onCreateSQLite: { createsSQLite = true }) }
        .sheet(isPresented: $workspace.isShowingSchemaDiagram) {
            SchemaDiagramView { table in open(table, keeps: true) }.portbaseDesktopSheetSize(width: 1100, height: 760)
        }
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { show(.console) }
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
                    for console in consoles.consoles where console.workspace.selectedBookmarkID == profile.id { console.workspace.selectBookmark(nil) }
                }
                deletingProfile = nil
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: { Text("Pending transactions on this connection will be rolled back.") }
    }

    private func withObservers<Content: View>(_ content: Content) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowCommandPalette)) { _ in showsPalette = true }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowHome)) { _ in showsHome = true }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseShowDestination)) { note in
            if let raw = note.object as? String, let target = Destination(rawValue: raw) { show(target) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .portbaseSelectAdjacentTab)) { note in
            selectAdjacentTab(by: note.object as? Int ?? 1)
        }
        // Secrets changed on another device arrive through iCloud Keychain without a notification.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in bookmarks.refreshSecrets() }
        .onChange(of: consoles.selectedID) { _, _ in showsHome = false }
        // Ask AI from the menu, the console, or the toolbar opens the tab's Ask AI page.
        .onChange(of: workspace.isShowingAssistant) { _, showing in
            guard showing else { return }
            workspace.isShowingAssistant = false
            show(.assistant)
        }
        .onChange(of: workspace.activeDatabaseName, initial: true) { _, database in
            // The active database opens in the sidebar; switching databases keeps the current view.
            if let id = workspace.selectedBookmarkID, let database { expandedDatabases.insert(databaseKey(id, database)) }
        }
        // Table tabs belong to the schema they were opened in, so another connection or database closes them.
        .onChange(of: SessionScope(console: consoles.selectedID, bookmark: workspace.selectedBookmarkID, database: workspace.activeDatabaseName)) { old, new in
            guard old.console == new.console else { return }
            updateTabs { $0.closeTables() }
        }
        // A table tab shows its table's rows: the explorer follows the tab, and the tab follows the
        // explorer when something else, like Structure, opens a table.
        .onChange(of: TableSyncKey(console: consoles.selectedID, tab: selectedTab, tables: workspace.schemaCatalog.count), initial: true) { _, _ in
            guard case .table(let name) = selectedTab.kind, workspace.selectedExplorerTable?.displayName != name,
                  let table = workspace.schemaCatalog.first(where: { $0.displayName == name }) else { return }
            workspace.selectExplorerTable(table)
        }
        .onChange(of: workspace.selectedExplorerTableID) { _, _ in
            guard case .table(let name) = selectedTab.kind, let table = workspace.selectedExplorerTable,
                  table.displayName != name else { return }
            updateTabs { $0.openTable(table.displayName) }
        }
        .onChange(of: consoles.consoles.map(\.id)) { _, open in
            tabSets = tabSets.filter { open.contains($0.key) }
            let openChats = Set(tabSets.values.flatMap(\.chatIDs))
            chats = chats.filter { openChats.contains($0.key) }
        }
    }

    private struct SessionScope: Equatable {
        let console: UUID
        let bookmark: UUID?
        let database: String?
    }

    private struct TableSyncKey: Equatable {
        let console: UUID
        let tab: SessionTabSet.Tab
        let tables: Int
    }

    /// Steps through the home tab and the connection tabs, wrapping around.
    private func selectAdjacentTab(by offset: Int) {
        let order: [UUID?] = [nil] + consoles.consoles.map(\.id)
        let current = showsHome ? 0 : (order.firstIndex(of: consoles.selectedID) ?? 0)
        let next = (current + offset + order.count) % order.count
        if let id = order[next] { consoles.select(id); showsHome = false } else { showsHome = true }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // macOS 26 wraps toolbar items in a Liquid Glass capsule; the tab strip draws its own tabs.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { tabStrip }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { tabStrip }
        }
        // One flat group in Portbase's own button style, rather than a glass circle around each button.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { windowActions }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { windowActions }
        }
    }

    private var windowActions: some View {
        HStack(spacing: Spacing.xxs) {
            // Works from any tab: it asks about the current connection tab's schema.
            Button("Ask AI", systemImage: "sparkles") { show(.assistant) }
                .disabled(workspace.selectedBookmark == nil)
                .help(L10n.text("Ask an AI model to write a query or design a chart") + " (⇧⌘A)")
            Button("Search", systemImage: "magnifyingglass") { showsPalette = true }
                .help(L10n.text("Search actions, tables, and queries") + " (⌘K)")
            Button("Settings", systemImage: "gearshape") { openSettings() }
                .help(L10n.text("Settings"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.portbaseToolbar)
        .font(.bodyText)
        .fixedSize()
    }

    /// The tab strip takes the toolbar's width beside the window controls and trailing buttons.
    private var tabStrip: some View {
        DesktopTabStrip(showsHome: $showsHome, onOpen: { openSession($0, then: nil) },
                        onNewConsole: { consoles.add(); consoles.active.workspace.selectBookmark(nil); showsHome = false },
                        onNewConnection: { workspace.createBookmark() })
            // The window controls and the three trailing buttons keep their room, so none overflow into a menu.
            .frame(width: max(280, windowWidth - 240), alignment: .leading)
    }

    private func navigate(_ target: PortbaseDestination) {
        switch target {
        case .home: homeSection = .activity; showsHome = true
        case .servers: show(.connections)
        case .explorer: show(.explorer)
        case .console: show(.console)
        case .charts: show(.charts)
        case .library: homeSection = .queries; showsHome = true
        case .settings: openSettings()
        }
    }

    // MARK: Home tab

    private var home: some View {
        HStack(spacing: 0) {
            homeSidebar.frame(width: 220)
            Divider()
            Group {
                switch homeSection {
                case .servers:
                    ConnectionsHubView(onOpenConsole: { show(.console) }, onCreateSQLite: { createsSQLite = true },
                                       onDelete: { deletingProfile = $0 })
                case .charts: NavigationStack { VisualizerView() }
                case .queries: LibrarySheetView(onOpened: { show(.console) })
                case .activity: HomeView(onNavigate: navigate)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var homeSidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            ForEach(HomeSection.allCases) { section in
                let selected = homeSection == section
                Button { homeSection = section } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: section.symbol)
                            .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.muted)
                            .frame(width: Sizes.symbolColumn)
                        Text(section.title)
                            .foregroundStyle(PortSQLPalette.ink)
                            .fontWeight(selected ? .semibold : .regular)
                        Spacer(minLength: Spacing.xs)
                        if let count = count(for: section), count > 0 {
                            Text(count.formatted()).font(.captionText.monospacedDigit()).foregroundStyle(PortSQLPalette.muted)
                        }
                    }
                    .font(.bodyText)
                    .padding(.horizontal, Spacing.s)
                    .frame(height: Sizes.control + Spacing.xs)
                    .background(selected ? PortSQLPalette.surface : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        if selected { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: Spacing.m)
            Menu {
                Button("Add Connection") { workspace.createBookmark() }
                Button("Import Connection String…") { workspace.createBookmark() }
                Divider()
                Button("New SQLite Database") { createsSQLite = true }
            } label: {
                Label("New Connection", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(.portbaseSecondary)
            .menuIndicator(.hidden)
        }
        .padding(Spacing.s)
        .padding(.top, Spacing.xs)
        .background(PortSQLPalette.sunken)
    }

    private func count(for section: HomeSection) -> Int? {
        switch section {
        case .servers: bookmarks.bookmarks.count
        case .charts: library.visualizations.count
        case .queries: library.snippets.count
        case .activity: nil
        }
    }

    // MARK: Connection tab

    private var session: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                sessionSidebar.frame(width: 260)
                Divider()
            }
            VStack(spacing: 0) {
                sessionHeader
                Divider()
                ConnectionStatusLine()
                if let error = workspace.schemaErrorMessage, workspace.selectedBookmark != nil {
                    ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                          onReviewCertificate: { workspace.reviewServerCertificate() })
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs)
                }
                sessionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: Spacing.s) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsSidebar.toggle() } } label: {
                Image(systemName: "sidebar.left").frame(width: Sizes.tool, height: Sizes.tool)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PortSQLPalette.muted)
            .help(showsSidebar ? L10n.text("Hide Sidebar") : L10n.text("Show Sidebar"))
            if workspace.selectedBookmark != nil {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(tabs.tabs) { tab in subTab(tab).id(tab.id) }
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: tabs.selectedID) { _, id in withAnimation { proxy.scrollTo(id) } }
                }
                .layoutPriority(1)
                newTabMenu
            }
            Spacer(minLength: Spacing.s)
            if workspace.selectedBookmark != nil {
                DatabasePicker().labelsHidden().fixedSize()
                    .help(workspace.selectedBookmark?.endpointSummary ?? "")
                Button("Refresh Schema", systemImage: "arrow.clockwise") { workspace.refreshSchemaCatalog() }
                    .labelStyle(.iconOnly)
                    .disabled(workspace.isLoadingSchema)
                    .help(L10n.text("Refresh Schema"))
            }
        }
        .buttonStyle(.portbaseToolbar)
        .font(.bodyText)
        .padding(.horizontal, Spacing.s)
        .frame(height: Sizes.toolbar + Spacing.s)
        .background(PortSQLPalette.panel)
    }

    @ViewBuilder private var sessionContent: some View {
        if workspace.selectedBookmark == nil {
            DesktopServerPicker(onOpen: { id in workspace.selectBookmark(id) }, onNewConnection: { workspace.createBookmark() })
        } else {
            switch selectedTab.kind {
            case .console: console
            case .table(let name): tablePage(name)
            case .explorer:
                if workspace.selectedBookmark?.engine == .redis { RedisExplorerView() }
                else if workspace.selectedBookmark?.engine == .elasticsearch { ElasticsearchExplorerView() }
                else { DesktopTableBrowser() }
            case .structure:
                if workspace.isDocumentDatabase {
                    NavigationStack {
                        if let profile = workspace.selectedBookmark, let database = workspace.activeDatabaseName,
                           let collection = workspace.selectedExplorerTable?.name {
                            MongoIndexesView(context: MongoIndexContext(profile: profile, database: database, collection: collection))
                        } else { Text("Choose a collection").foregroundStyle(.secondary) }
                    }
                } else {
                    DesktopStructureView(
                        onOpenData: { table in open(table, keeps: true) },
                        onQuery: { table in workspace.queryText = workspace.defaultQuery(for: table); show(.console) },
                        onOpenSQL: { sql in workspace.applyAssistantQuery(sql, replacing: false); show(.console) }
                    )
                }
            case .chat:
                AssistantChatView(session: chats[selectedTab.id] ?? workspace.assistant, onShowConsole: { show(.console) })
                    .id(selectedTab.id)
            case .charts:
                NavigationStack { VisualizerView() }
            }
        }
    }

    @ViewBuilder private func tablePage(_ name: String) -> some View {
        if workspace.schemaCatalog.contains(where: { $0.displayName == name }) {
            DesktopTableBrowser()
        } else if workspace.isLoadingSchema {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PortbaseEmptyState(title: L10n.text("Table not found"),
                               message: L10n.format("%@ isn't in this database anymore.", name),
                               systemImage: "tablecells",
                               actionTitle: L10n.text("Close Tab"),
                               action: { closeTab(selectedTab.id) })
        }
    }

    // MARK: Connection tab's tabs

    private func subTab(_ tab: SessionTabSet.Tab) -> some View {
        DesktopSubTab(
            tab: tab,
            title: subTabTitle(tab),
            symbol: subTabSymbol(tab),
            chat: chats[tab.id],
            isSelected: tab.id == tabs.selectedID,
            canClose: tabs.canClose(tab.id),
            onSelect: { updateTabs { $0.select(tab.id) } },
            onKeep: { updateTabs { $0.keep(tab.id) } },
            onClose: { closeTab(tab.id) },
            onCloseOthers: { closeTabs(otherThan: tab.id) }
        )
    }

    private func subTabTitle(_ tab: SessionTabSet.Tab) -> String {
        switch tab.kind {
        case .console: L10n.text("Console")
        case .table(let name): workspace.schemaCatalog.first { $0.displayName == name }?.name ?? name
        case .explorer: L10n.text("Explorer")
        case .structure: L10n.text("Structure")
        case .chat: L10n.text("New Chat")
        case .charts: L10n.text("Charts")
        }
    }

    private func subTabSymbol(_ tab: SessionTabSet.Tab) -> String {
        switch tab.kind {
        case .console: "terminal"
        case .table(let name):
            workspace.isDocumentDatabase ? "doc.on.doc"
                : workspace.schemaCatalog.first { $0.displayName == name }?.objectKind?.symbol ?? "tablecells"
        case .explorer: "square.stack.3d.up"
        case .structure: "list.bullet.rectangle"
        case .chat: "sparkles"
        case .charts: "chart.bar.xaxis"
        }
    }

    private var newTabMenu: some View {
        Menu {
            Button("New Chat", systemImage: "sparkles") { newChat() }
            if usesKeyBrowser {
                Button("Explorer", systemImage: "square.stack.3d.up") { updateTabs { $0.show(.explorer) } }
            } else if let table = workspace.selectedExplorerTable ?? workspace.schemaCatalog.first {
                Button(L10n.format("Open %@", table.name), systemImage: "tablecells") { open(table, keeps: true) }
            }
            Button("Structure", systemImage: "list.bullet.rectangle") { updateTabs { $0.show(.structure) } }
            Button("Charts", systemImage: "chart.bar.xaxis") { updateTabs { $0.show(.charts) } }
        } label: {
            Image(systemName: "plus").frame(width: Sizes.tool, height: Sizes.tool)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("Open a Tab"))
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            if let profile = workspace.selectedBookmark {
                sessionSidebarHeader(profile)
                Divider()
                PortbaseSearchField(prompt: L10n.text("Search tables"), text: $search)
                    .font(.bodyText)
                    .portbaseFieldChrome()
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.s)
                List {
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
                }
                .listStyle(.sidebar)
                .font(.bodyText)
                .scrollContentBackground(.hidden)
            } else {
                Text("Choose a server for this tab")
                    .font(.rowDetail)
                    .foregroundStyle(PortSQLPalette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PortSQLPalette.sunken)
    }

    private func sessionSidebarHeader(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: Spacing.s) {
            BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                HStack(spacing: Spacing.xxs) {
                    Text(profile.displayTitle).font(.rowTitle.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    if profile.environment != .none {
                        Circle().fill(profile.environment.color).frame(width: Sizes.dot, height: Sizes.dot).help(profile.environment.title)
                    }
                }
                Text(profile.engine.isLocal ? profile.engine.rawValue : profile.endpointSummary)
                    .font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.xxs)
            Menu {
                Button("Edit Connection") { workspace.selectedProfileForEdit = profile }
                Button("Refresh Database List") { workspace.refreshDatabaseList() }
                Button("New Console") { consoles.add(); showsHome = false }
                Divider()
                Button("Delete Connection", role: .destructive) { deletingProfile = profile }
            } label: {
                Image(systemName: "ellipsis").frame(width: Sizes.tool, height: Sizes.tool)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
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
        let selected: Bool = switch selectedTab.kind {
        case .table(let name): name == table.displayName
        case .structure, .explorer: workspace.selectedExplorerTableID == table.id
        default: false
        }
        let pinned = pinnedTables.isPinned(table.displayName, in: pinScope)
        return Button {
            // Choosing a table shows its rows, or its structure when that's open.
            if selectedTab.kind == .structure { workspace.selectExplorerTable(table) } else { open(table) }
        } label: {
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
        // A double click keeps the table's tab open rather than previewing it.
        .simultaneousGesture(TapGesture(count: 2).onEnded { if selectedTab.kind != .structure { open(table, keeps: true) } })
        .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.ink)
        .fontWeight(selected ? .semibold : .regular)
        .contextMenu {
            if !usesKeyBrowser { Button("Open in New Tab") { open(table, keeps: true) } }
            Button("Query") { workspace.queryText = workspace.defaultQuery(for: table); show(.console) }
            Button("Structure") { workspace.selectExplorerTable(table); show(.structure) }
            Button("Copy") { PortbaseClipboard.copy(table.displayName) }
            Divider()
            Button(pinned ? L10n.text("Unpin") : L10n.text("Pin")) {
                withAnimation { pinnedTables.toggle(table.displayName, in: pinScope) }
            }
        }
    }

    private var console: some View {
        VSplitView {
            Group {
                if workspace.isDocumentDatabase { DesktopMongoEditor() }
                else if workspace.selectedBookmark?.engine == .elasticsearch { ScrollView { ElasticsearchQueryEditorCard().environment(\.workspaceIsFlat, true) } }
                else { DesktopSQLEditor() }
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
            DesktopResultsView().frame(minHeight: 180, idealHeight: 440, maxHeight: .infinity)
        }
    }
}
