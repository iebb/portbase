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
        /// The views inside a connection tab.
        static let sessionCases: [Destination] = [.console, .explorer, .structure]
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
    /// Each connection tab remembers whether it shows the console, data, or structure.
    @State private var destinations: [UUID: Destination] = [:]
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

    private var sessionDestination: Destination { destinations[consoles.selectedID] ?? .console }
    private var destination: Destination { showsHome ? .home : sessionDestination }

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
        case .charts: homeSection = .charts; showsHome = true
        case .console, .explorer, .structure:
            destinations[consoles.selectedID] = target
            showsHome = false
        }
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
        if destinations[consoles.selectedID] == nil { destinations[consoles.selectedID] = .console }
        showsHome = false
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(isPresented: $workspace.isShowingAssistant) {
            AssistantSheet(session: workspace.assistant, onShowConsole: { show(.console) })
                .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 720)
        }
        .sheet(isPresented: $showsPalette) { CommandPaletteView(onNavigate: navigate, onCreateSQLite: { createsSQLite = true }) }
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
        .onChange(of: workspace.queryText) { _, _ in workspace.refreshAssist() }
        .onChange(of: workspace.queryCursorOffset) { _, _ in workspace.refreshAssist() }
        .onChange(of: consoles.selectedID) { _, _ in showsHome = false }
        .onChange(of: workspace.activeDatabaseName, initial: true) { _, database in
            // The active database opens in the sidebar; switching databases keeps the current view.
            if let id = workspace.selectedBookmarkID, let database { expandedDatabases.insert(databaseKey(id, database)) }
        }
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Search", systemImage: "magnifyingglass") { showsPalette = true }
                .help(L10n.text("Search actions, tables, and queries") + " (⌘K)")
            Button("Settings", systemImage: "gearshape") { openSettings() }
                .help(L10n.text("Settings"))
        }
    }

    /// The tab strip takes the toolbar's width beside the window controls and trailing buttons.
    private var tabStrip: some View {
        DesktopTabStrip(showsHome: $showsHome, onOpen: { openSession($0, then: nil) },
                        onNewConsole: { consoles.add(); consoles.active.workspace.selectBookmark(nil); showsHome = false },
                        onNewConnection: { workspace.createBookmark() })
            .frame(width: max(280, windowWidth - 200), alignment: .leading)
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
                case .activity: HomeView(onNavigate: navigate, onSearch: { showsPalette = true })
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
            PortbasePillTabs(selection: Binding(get: { sessionDestination }, set: { show($0) }),
                             options: Destination.sessionCases.map { PortbaseChoice(value: $0, title: L10n.text($0.title), systemImage: $0.symbol) })
                .fixedSize()
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
            switch sessionDestination {
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
                        onOpenData: { table in workspace.selectExplorerTable(table); show(.explorer) },
                        onQuery: { table in workspace.queryText = workspace.defaultQuery(for: table); show(.console) },
                        onOpenSQL: { sql in workspace.applyAssistantQuery(sql, replacing: false); show(.console) }
                    )
                }
            default: console
            }
        }
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
        let selected = workspace.selectedExplorerTableID == table.id && sessionDestination != .console
        let pinned = pinnedTables.isPinned(table.displayName, in: pinScope)
        return Button {
            workspace.selectExplorerTable(table)
            // Choosing a table shows its data, or its structure when that's open.
            if sessionDestination != .structure { show(.explorer) }
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
        .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.ink)
        .fontWeight(selected ? .semibold : .regular)
        .contextMenu {
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
                else if workspace.selectedBookmark?.engine == .elasticsearch { ScrollView { ElasticsearchQueryEditorCard().padding(Spacing.m) } }
                else { DesktopSQLEditor() }
            }.frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
            DesktopResultsView().frame(minHeight: 180, idealHeight: 440, maxHeight: .infinity)
        }
    }
}

// MARK: - Tabs

/// The window's tab strip, in the title bar like Termius: a home tab, a tab per open connection,
/// and a button that opens a server in a new tab.
struct DesktopTabStrip: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @Binding var showsHome: Bool
    let onOpen: (UUID) -> Void
    let onNewConsole: () -> Void
    let onNewConnection: () -> Void
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?
    @State private var discardingID: UUID?
    @State private var showsPicker = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xxs) {
                    homeTab
                    Divider().frame(height: Spacing.l).padding(.horizontal, Spacing.xxs)
                    ForEach(consoles.consoles) { console in
                        DesktopSessionTab(console: console, workspace: console.workspace,
                                          isSelected: !showsHome && consoles.selectedID == console.id,
                                          onSelect: { consoles.select(console.id); showsHome = false },
                                          onClose: { close(console.id) },
                                          onRename: { title = console.title; renamingID = console.id },
                                          onCloseOthers: { for other in consoles.consoles where other.id != console.id { close(other.id) } })
                            .id(console.id)
                    }
                    Button { showsPicker = true } label: {
                        Image(systemName: "plus").font(.captionStrong).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PortSQLPalette.muted)
                    .help(L10n.text("Open a server in a new tab"))
                    .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                        DesktopServerPicker(compact: true, onOpen: { id in showsPicker = false; onOpen(id) },
                                            onNewConnection: { showsPicker = false; onNewConnection() },
                                            onEmptyConsole: { showsPicker = false; onNewConsole() })
                            .frame(width: 340, height: 420)
                    }
                }
                .padding(.vertical, Spacing.xxxs)
            }
            .onChange(of: consoles.selectedID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
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

    private var homeTab: some View {
        Button { showsHome = true } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(showsHome ? PortSQLPalette.accent : PortSQLPalette.muted)
                Text("Portbase")
                    .fontWeight(showsHome ? .semibold : .medium)
                    .foregroundStyle(showsHome ? PortSQLPalette.ink : PortSQLPalette.muted)
            }
            .font(.bodyText)
            .padding(.horizontal, Spacing.m)
            .frame(height: 28)
            .modifier(DesktopTabChrome(isSelected: showsHome, isHovered: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home")
        .accessibilityAddTraits(showsHome ? [.isButton, .isSelected] : .isButton)
    }

    /// Asks before closing a console with unsubmitted cell edits, then before rolling back an open transaction.
    private func close(_ id: UUID, discardingEdits: Bool = false) {
        let workspace = consoles.consoles.first(where: { $0.id == id })?.workspace
        if !discardingEdits, workspace?.pendingCellEdits.isEmpty == false { discardingID = id }
        else if workspace?.hasOpenTransaction == true { closingID = id }
        else {
            consoles.close(id)
            if consoles.consoles.count == 1, consoles.active.workspace.selectedBookmarkID == nil { showsHome = true }
        }
    }
}

private struct DesktopTabChrome: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(isSelected ? PortSQLPalette.surface : (isHovered ? PortSQLPalette.surface.opacity(0.5) : Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(PortSQLPalette.stroke)
                }
            }
    }
}

/// A connection tab: the server's icon and name, its activity, and a close button.
private struct DesktopSessionTab: View {
    let console: QueryConsole
    /// Observed so the tab follows the connection, running state, and open transaction.
    @ObservedObject var workspace: WorkspaceViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCloseOthers: () -> Void
    @State private var isHovered = false

    private var title: String {
        if console.hasCustomTitle { return console.title }
        return workspace.selectedBookmark?.displayTitle ?? console.title
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Group {
                if let profile = workspace.selectedBookmark {
                    BookmarkAvatar(profile: profile, size: 18, cornerRadius: 5)
                } else {
                    Image(systemName: "terminal").foregroundStyle(PortSQLPalette.muted).frame(width: 18)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if workspace.isRunning {
                    Circle().fill(PortSQLPalette.accent).frame(width: 7, height: 7)
                        .overlay { Circle().strokeBorder(PortSQLPalette.surface, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                        .symbolEffect(.pulse)
                }
            }
            Text(title)
                .lineLimit(1)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? PortSQLPalette.ink : PortSQLPalette.muted)
            if let database = workspace.activeDatabaseName, !database.isEmpty, workspace.selectedBookmark?.engine.isLocal == false {
                Text(database).font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
            }
            if workspace.hasOpenTransaction {
                Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot).help(L10n.text("Open transaction"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PortSQLPalette.muted)
            .opacity(isSelected || isHovered ? 1 : 0)
            .accessibilityLabel("Close Console")
        }
        .font(.bodyText)
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xs)
        .frame(height: 28)
        .frame(maxWidth: 240)
        .modifier(DesktopTabChrome(isSelected: isSelected, isHovered: isHovered))
        .overlay(alignment: .bottom) {
            // The connection's environment color underlines its tab, as Termius colors its hosts.
            if let environment = workspace.selectedBookmark?.environment, environment != .none {
                Capsule().fill(environment.color).frame(height: 2).padding(.horizontal, Spacing.s)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(workspace.selectedBookmark?.endpointSummary ?? title)
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Close", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Saved servers to open, as Termius offers hosts in a new tab.
struct DesktopServerPicker: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    var compact = false
    let onOpen: (UUID) -> Void
    let onNewConnection: () -> Void
    var onEmptyConsole: (() -> Void)?
    @State private var search = ""

    private var matches: [ConnectionProfile] {
        bookmarks.bookmarks.filter {
            search.isEmpty || [$0.displayTitle, $0.host, $0.engine.rawValue].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !compact {
                Text("Choose a server").font(.sectionTitle).foregroundStyle(PortSQLPalette.ink)
                Text("This tab connects to the server you choose.").font(.footnoteText).foregroundStyle(.secondary)
            }
            PortbaseSearchField(prompt: L10n.text("Search servers"), text: $search)
                .font(.bodyText)
                .portbaseFieldChrome()
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    ForEach(matches) { profile in
                        Button { onOpen(profile.id) } label: {
                            HStack(spacing: Spacing.s) {
                                BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
                                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                    Text(profile.displayTitle).font(.rowTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Text(profile.engine.isLocal ? profile.engine.rawValue : profile.endpointSummary)
                                        .font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
                                }
                                Spacer(minLength: Spacing.xs)
                                if profile.environment != .none {
                                    Circle().fill(profile.environment.color).frame(width: Sizes.dot, height: Sizes.dot)
                                }
                            }
                            .padding(.horizontal, Spacing.s)
                            .frame(minHeight: Sizes.row)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DesktopPickerRowStyle())
                    }
                }
            }
            Divider()
            HStack {
                Button("New Connection", systemImage: "plus", action: onNewConnection)
                if let onEmptyConsole {
                    Spacer()
                    Button("Empty Console", systemImage: "terminal", action: onEmptyConsole)
                }
            }
            .buttonStyle(.portbaseToolbar)
            .font(.bodyText)
        }
        .padding(compact ? Spacing.m : Spacing.xl)
        .frame(maxWidth: compact ? .infinity : 520, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }
}

private struct DesktopPickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? PortSQLPalette.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .onHoverBackground()
    }
}

private extension View {
    func onHoverBackground() -> some View { modifier(HoverBackground()) }
}

private struct HoverBackground: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? PortSQLPalette.sunken : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .onHover { hovered = $0 }
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
