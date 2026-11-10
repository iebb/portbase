import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

enum PortSQLPalette {
    static var accent: Color { PortbaseAccent.current.color }
    /// A flat fill for prominent controls; kept as a gradient type so call sites stay uniform.
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    }
    static var accentSoft: Color { accent.opacity(0.12) }
    // Surfaces and text come from the selected theme (Navy by default).
    private static var theme: PortbaseTheme.Palette { PortbaseTheme.current.palette }
    static var ink: Color { theme.ink }
    /// Secondary text and icons as a fixed color, for places such as the Mac sidebar where
    /// vibrancy would otherwise darken the system secondary style.
    static var muted: Color { theme.muted }
    static var panel: Color { theme.panel }
    static var surface: Color { theme.surface }
    static var tertiarySurface: Color { theme.tertiarySurface }
    static var sunken: Color { theme.sunken }
    static var stroke: Color { theme.stroke }
    static var canvasTop: Color { theme.canvas }
    static var canvasAccent: Color { theme.canvasAccent }
    static let shadow = Color.black.opacity(0.12)

    static func editorBackground(for colorScheme: ColorScheme) -> Color {
        EditorTheme.current.background(for: colorScheme)
    }

    static func editorBorder(for colorScheme: ColorScheme) -> Color {
        stroke
    }

    static func editorPlaceholder(for colorScheme: ColorScheme) -> Color {
        EditorTheme.current.placeholder(for: colorScheme)
    }
}

#if os(iOS)
struct RootView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var selectedTab: RootTab
    @State private var showsPalette = false
    @State private var showsLibrary = false
    @State private var showsSettings = false
    @State private var createsSQLite = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// `initialTab` names the tab to open on, as the -portsql-tab launch argument does.
    init(initialTab: String? = nil) {
        _selectedTab = State(initialValue: initialTab.map(RootTab.init(name:)) ?? RootTab.launchSelection)
    }

    private var hasConnectionProblem: Bool {
        workspace.selectedBookmark != nil
            && (workspace.errorMessage != nil || workspace.schemaErrorMessage != nil)
    }

    var body: some View {
        // The Liquid Glass tab bar sits at the bottom on iPad too: the floating bar iPadOS puts at the
        // top covers each page's navigation bar and its controls. A compact width for the tab view
        // alone moves the bar down; each page gets the real width back.
        let pageSizeClass = horizontalSizeClass
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                NavigationStack {
                    HomeView(onNavigate: navigate)
                        .navigationTitle("Home")
                        .portbaseTitleDisplayMode(.large)
                        .toolbar {
                            ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                                searchButton
                                Button { navigate(.settings) } label: {
                                    Image(systemName: "gearshape").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                                }
                                .accessibilityLabel("Settings")
                            }
                        }
                }
                .environment(\.horizontalSizeClass, pageSizeClass)
            }

            Tab("Explorer", systemImage: "square.stack.3d.up.fill", value: RootTab.explorer) {
                ExplorerWorkspaceView()
                    .environment(\.horizontalSizeClass, pageSizeClass)
            }

            Tab("Console", systemImage: "terminal.fill", value: RootTab.studio) {
                ExplorerWorkspaceView(showsConsole: true)
                    .environment(\.horizontalSizeClass, pageSizeClass)
            }

            Tab("Charts", systemImage: "chart.bar.xaxis", value: RootTab.charts) {
                NavigationStack {
                    VisualizerView()
                }
                .environment(\.horizontalSizeClass, pageSizeClass)
            }

            Tab("Servers", systemImage: "server.rack", value: RootTab.servers) {
                NavigationStack {
                    BookmarksView(onOpenConsole: { navigate(.console) })
                }
                .environment(\.horizontalSizeClass, pageSizeClass)
            }
            .badge(hasConnectionProblem ? Text(verbatim: "!") : nil)

        }
        .tabViewStyle(.tabBarOnly)
        .environment(\.horizontalSizeClass, .compact)
        .portbaseMinimizingTabBar()
        .certificateTrustPrompt(workspace)
        .portbaseTheme()
        .background {
            // Hardware keyboard shortcuts; the buttons themselves are invisible.
            Group {
                Button("Search") { showsPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Home") { selectedTab = .home }.keyboardShortcut("1", modifiers: .command)
                Button("Explorer") { selectedTab = .explorer }.keyboardShortcut("2", modifiers: .command)
                Button("Console") { selectedTab = .studio }.keyboardShortcut("3", modifiers: .command)
                Button("Charts") { selectedTab = .charts }.keyboardShortcut("4", modifiers: .command)
                Button("Servers") { selectedTab = .servers }.keyboardShortcut("5", modifiers: .command)
                Button("Settings") { showsSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom) {
            if let error = library.storageError ?? consoles.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnoteText)
                    .foregroundStyle(.red)
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity)
                    .background(PortSQLPalette.panel)
            }
        }
        .sheet(isPresented: $showsPalette) {
            CommandPaletteView(onNavigate: navigate, onCreateSQLite: { createsSQLite = true })
        }
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { selectedTab = .studio }
        .sheet(isPresented: $showsLibrary) {
            LibrarySheetView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $workspace.isShowingSchemaDiagram) {
            SchemaDiagramView { table in workspace.selectExplorerTable(table); navigate(.explorer) }
        }
        .sheet(isPresented: $workspace.isShowingAssistant) {
            AssistantSheet(session: workspace.assistant, onShowConsole: { selectedTab = .studio })
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showsSettings) {
            PortbaseSheet(L10n.text("Settings"), onClose: { showsSettings = false }) {
                SettingsView().portbaseForm()
            }
            .portbaseSheetNavigation()
            .portbaseTheme()
        }
        .sheet(item: $workspace.dataEditorDraft) { _ in
            DataEditorSheet()
        }
        .sheet(item: $workspace.parameterDraft) { draft in
            QueryParameterSheet(draft: draft)
        }
        .sheet(item: $workspace.selectedProfileForEdit) { profile in
            BookmarkEditorView(profile: profile)
        }
        .pendingEditsDiscardPrompt(workspace)
        .sqlSafetyConfirmation(workspace)
    }

    private var searchButton: some View {
        Button { showsPalette = true } label: {
            Image(systemName: "magnifyingglass").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
        }
        .accessibilityLabel("Search")
        .accessibilityHint("Find actions, tables, and saved queries")
    }

    private func navigate(_ destination: PortbaseDestination) {
        switch destination {
        case .home: selectedTab = .home
        case .explorer: selectedTab = .explorer
        case .console: selectedTab = .studio
        case .charts: selectedTab = .charts
        case .servers: selectedTab = .servers
        case .library: showsLibrary = true
        case .settings: showsSettings = true
        }
    }
}

private extension View {
    @ViewBuilder func portbaseMinimizingTabBar() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

private enum RootTab: Hashable {
    case home
    case explorer
    case studio
    case charts
    case servers

    static var launchSelection: RootTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-portsql-tab"),
              arguments.indices.contains(index + 1) else {
            return .home
        }

        return RootTab(name: arguments[index + 1])
    }

    init(name: String) {
        switch name.lowercased() {
        case "explorer": self = .explorer
        case "studio", "console": self = .studio
        case "charts": self = .charts
        case "servers": self = .servers
        default: self = .home
        }
    }
}
#endif

struct QueryLibraryButton: View {
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
        }
        .accessibilityLabel("Open query library")
        .sheet(isPresented: $presented) { LibrarySheetView() }
    }
}

struct WorkbenchView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isPhone: Bool { horizontalSizeClass == .compact }
#else
    private let isPhone = false
#endif

    var body: some View {
        AdaptiveWorkspaceView(showsTrailing: workspace.hasResultsToShow) {
            if workspace.isDocumentDatabase { MongoQueryEditorCard() }
            else if workspace.selectedBookmark?.engine == .redis { RedisQueryEditorCard() }
            else if workspace.selectedBookmark?.engine == .elasticsearch { ElasticsearchQueryEditorCard() }
            else { QueryEditorCard() }
        } trailing: {
            ResultsCard()
        }
        .background(WorkbenchBackground().ignoresSafeArea())
        // On phones the connection's badges share the console tabs' row rather than taking one of their own.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ConsoleTabBar(showsConnectionBadges: isPhone)
                ConnectionStatusLine(showsBadges: isPhone ? false : nil)
            }
        }
        .navigationTitle("Console")
        .portbaseTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: PortbaseToolbar.leading) {
                ConnectionSwitcherButton()
            }
            ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                SchemaRefreshButton()
                DatabaseSwitcherButton()
            }
        }
#if os(iOS)
        .sensoryFeedback(trigger: workspace.lastExecution?.id) { _, _ in
            switch workspace.lastExecution?.outcome {
            case .succeeded?: .success
            case .failed?: .error
            default: nil
            }
        }
#endif
    }
}

struct ConnectionSwitcherButton: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        Group {
            if bookmarks.bookmarks.isEmpty {
                Button {
                    workspace.createBookmark()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.tileSymbol)
                        .foregroundStyle(PortSQLPalette.accent)
                        .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add database connection")
            } else {
                Menu {
                    Section("Servers") {
                        ForEach(bookmarks.bookmarks) { bookmark in
                            Button {
                                workspace.selectBookmark(bookmark.id)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                        Text(bookmark.name.isEmpty ? bookmark.host : bookmark.name)
                                        Text(bookmark.engine.isLocal ? "SQLite • " + (bookmark.sqliteFileName ?? L10n.text("File unavailable")) : "\(bookmark.engine.rawValue) • \(bookmark.host):\(String(bookmark.port))")
                                            .font(.microText)
                                    }
                                } icon: {
                                    HStack(spacing: Spacing.xs) {
                                        BookmarkAvatar(profile: bookmark, size: Sizes.avatarSmall, cornerRadius: Radius.s)
                                        if workspace.selectedBookmarkID == bookmark.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        workspace.createBookmark()
                    } label: {
                        Label("New Connection", systemImage: "plus.circle")
                    }
                } label: {
                    HStack(spacing: Spacing.s) {
                        if let bookmark = workspace.selectedBookmark {
                            BookmarkAvatar(profile: bookmark, size: Sizes.avatarSmall, cornerRadius: Radius.chip)
                        } else {
                            Image(systemName: "server.rack")
                                .font(.toolSymbol)
                                .foregroundStyle(PortSQLPalette.ink)
                        }

                        Image(systemName: "chevron.down")
                            .font(.captionStrong)
                            .foregroundStyle(PortSQLPalette.ink.opacity(0.65))
                        // On iPad the connection's badges ride along here rather than in a row of their own.
                        if horizontalSizeClass == .regular, let bookmark = workspace.selectedBookmark,
                           ConnectionStatusBadges.hasBadges(bookmark) {
                            ConnectionStatusBadges(profile: bookmark)
                        }
                    }
                    .frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                }
                .accessibilityLabel("Choose database connection")
                .accessibilityValue(workspace.selectedBookmark.map { $0.name.isEmpty ? $0.host : $0.name } ?? "No connection selected")
            }
        }
    }
}

struct DatabaseSwitcherButton: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if workspace.selectedBookmark != nil {
            Menu {
                if workspace.availableDatabases.isEmpty {
                    Text("No databases found")
                } else {
                    Section("Databases") {
                        ForEach(workspace.availableDatabases, id: \.self) { database in
                            Button {
                                workspace.selectDatabase(database)
                            } label: {
                                Label(
                                    database,
                                    systemImage: workspace.activeDatabaseName?.caseInsensitiveCompare(database) == .orderedSame
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                        }
                    }
                }
                Divider()
                Button("Refresh Database List", systemImage: "arrow.clockwise") { workspace.refreshDatabaseList() }
                    .disabled(workspace.isRefreshingDatabases)
            } label: {
                HStack(spacing: Spacing.xs) {
                    if workspace.isLoadingSchema || workspace.isRefreshingDatabases {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(workspace.activeDatabaseName ?? "DB")
                        .font(.captionStrong)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.captionStrong)
                }
                .foregroundStyle(PortSQLPalette.ink)
                .frame(minHeight: Sizes.touchTarget)
            }
            // Stays open with no databases listed, so the list can be refreshed.
            .disabled(workspace.isLoadingSchema)
        }
    }
}

struct SchemaRefreshButton: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        if workspace.isSchemaCachingEnabled {
            Button {
                workspace.refreshSchemaCatalog()
            } label: {
                Image(systemName: workspace.isLoadingSchema ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.toolSymbol)
                    .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(workspace.isLoadingSchema ? .secondary : PortSQLPalette.accent)
            .disabled(workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.isLoadingSchema)
            .accessibilityLabel("Refresh cached table list")
        }
    }
}
