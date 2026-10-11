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
    static let accentSoft = Color.adaptive(light: 0xEEF0FF, dark: 0x1E2133)
#if canImport(UIKit)
    static let ink = Color(uiColor: .label)
#else
    static let ink = Color.primary
#endif
    static let panel = Color.adaptive(light: 0xF1F3F8, dark: 0x1A1E29)
    static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x151922)
    static let tertiarySurface = Color.adaptive(light: 0xF7F8FB, dark: 0x1C212D)
    static let sunken = Color.adaptive(light: 0xF3F5F9, dark: 0x0F131B)
    static let stroke = Color.adaptive(light: 0x0F172A, dark: 0xFFFFFF, lightOpacity: 0.08, darkOpacity: 0.08)
    static let canvasTop = Color.adaptive(light: 0xF4F5F9, dark: 0x0A0C12)
    static let canvasAccent = Color.adaptive(light: 0xEBEEF5, dark: 0x11141C)
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
    @State private var selectedTab = RootTab.launchSelection
    @State private var showsPalette = false
    @State private var showsLibrary = false
    @State private var showsSettings = false
    @State private var createsSQLite = false

    private var hasConnectionProblem: Bool {
        workspace.selectedBookmark != nil
            && (workspace.errorMessage != nil || workspace.schemaErrorMessage != nil)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                NavigationStack {
                    HomeView(onNavigate: navigate, onSearch: { showsPalette = true })
                        .navigationTitle("Home")
                        .portbaseTitleDisplayMode(.large)
                        .toolbar {
                            ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                                searchButton
                                Button { navigate(.settings) } label: {
                                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Settings")
                            }
                        }
                }
            }

            Tab("Explorer", systemImage: "square.stack.3d.up.fill", value: RootTab.explorer) {
                ExplorerWorkspaceView()
            }

            Tab("Console", systemImage: "terminal.fill", value: RootTab.studio) {
                ExplorerWorkspaceView(showsConsole: true)
            }

            Tab("Charts", systemImage: "chart.bar.xaxis", value: RootTab.charts) {
                NavigationStack {
                    VisualizerView()
                }
            }

            Tab("Servers", systemImage: "server.rack", value: RootTab.servers) {
                NavigationStack {
                    BookmarksView()
                }
            }
            .badge(hasConnectionProblem ? Text(verbatim: "!") : nil)

        }
        .tabViewStyle(.sidebarAdaptable)
        .portbaseMinimizingTabBar()
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
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
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
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSettings = false } }
                    }
            }
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
        .alert(item: $workspace.pendingSafetyConfirmation) { pending in
            Alert(
                title: Text(pending.assessment.title),
                message: Text(pending.assessment.message),
                primaryButton: .destructive(Text("Run Anyway")) {
                    workspace.runPendingSafetyConfirmation()
                },
                secondaryButton: .cancel {
                    workspace.cancelPendingSafetyConfirmation()
                }
            )
        }
    }

    private var searchButton: some View {
        Button { showsPalette = true } label: {
            Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
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

        switch arguments[index + 1].lowercased() {
        case "explorer":
            return .explorer
        case "studio", "console":
            return .studio
        case "charts":
            return .charts
        case "servers":
            return .servers
        default:
            return .home
        }
    }
}
#endif

struct QueryLibraryButton: View {
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Open query library")
        .sheet(isPresented: $presented) { LibrarySheetView() }
    }
}

struct WorkbenchView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        AdaptiveWorkspaceView {
            if workspace.isDocumentDatabase { MongoQueryEditorCard() }
            else if workspace.selectedBookmark?.engine == .redis { RedisQueryEditorCard() }
            else if workspace.selectedBookmark?.engine == .elasticsearch { ElasticsearchQueryEditorCard() }
            else { QueryEditorCard() }
        } trailing: {
            ResultsCard()
        }
        .background(WorkbenchBackground().ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { ConsoleTabBar(); ConnectionStatusLine() } }
        .navigationTitle("Console")
        .portbaseTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: PortbaseToolbar.leading) {
                ConnectionSwitcherButton(toolbarMode: true)
            }
            ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                SchemaRefreshButton()
                DatabaseSwitcherButton()
            }
        }
        .onChange(of: workspace.queryText) { _, _ in
            workspace.refreshAssist()
        }
        .onChange(of: workspace.queryCursorOffset) { _, _ in
            workspace.refreshAssist()
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
    var toolbarMode = false

    var body: some View {
        Group {
            if bookmarks.bookmarks.isEmpty {
                Button {
                    workspace.createBookmark()
                } label: {
                    Image(systemName: toolbarMode ? "plus.circle.fill" : "plus")
                        .font(.system(size: toolbarMode ? 18 : 16, weight: .bold))
                        .foregroundStyle(toolbarMode ? PortSQLPalette.accent : .white)
                        .frame(width: 44, height: 44)
                        .background(toolbarMode ? Color.clear : Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.name.isEmpty ? bookmark.host : bookmark.name)
                                        Text(bookmark.engine.isLocal ? "SQLite • " + (bookmark.sqliteFileName ?? L10n.text("File unavailable")) : "\(bookmark.engine.rawValue) • \(bookmark.host):\(String(bookmark.port))")
                                            .font(.caption2)
                                    }
                                } icon: {
                                    HStack(spacing: 6) {
                                        BookmarkAvatar(profile: bookmark, size: 22, cornerRadius: 7)
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
                    HStack(spacing: 8) {
                        if let bookmark = workspace.selectedBookmark {
                            BookmarkAvatar(profile: bookmark, size: 24, cornerRadius: 8)
                        } else {
                            Image(systemName: "server.rack")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(toolbarMode ? PortSQLPalette.ink.opacity(0.65) : .white.opacity(0.85))
                    }
                    .padding(.horizontal, toolbarMode ? 0 : 12)
                    .padding(.vertical, toolbarMode ? 0 : 10)
                    .background(toolbarMode ? Color.clear : Color.white.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(minWidth: 44, minHeight: 44)
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
            } label: {
                HStack(spacing: 6) {
                    if workspace.isLoadingSchema {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(workspace.activeDatabaseName ?? "DB")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(PortSQLPalette.ink)
                .frame(minHeight: 44)
            }
            .disabled(workspace.availableDatabases.isEmpty || workspace.isLoadingSchema)
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
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(workspace.isLoadingSchema ? .secondary : PortSQLPalette.accent)
            .disabled(workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.isLoadingSchema)
            .accessibilityLabel("Refresh cached table list")
        }
    }
}

struct QueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var editorMinimumHeight: CGFloat = 220
    @State private var isShowingExpandedEditor = false
    @State private var isShowingLibrarySheet = false

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    if let bookmark = workspace.selectedBookmark {
                        BookmarkAvatar(profile: bookmark, size: 36, cornerRadius: 10)
                    }
                    SectionHeader(title: L10n.text("Query"), subtitle: querySubtitle)
                    Spacer(minLength: 12)
                    Button {
                        isShowingLibrarySheet = true
                    } label: {
                        Image(systemName: "books.vertical").toolIconChrome()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open query library")
                    Button {
                        isShowingExpandedEditor = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").toolIconChrome()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(workspace.usesJSONEditor ? "Open JSON editor" : "Open full screen SQL editor")
                }

                if bookmarks.bookmarks.isEmpty {
                    connectionSection
                }
                actionSection
                editorSection
                statusLine
                if workspace.isDocumentDatabase {
                    Menu {
                        Button("Browse documents") { workspace.useMongoTemplate("find") }
                        Button("Aggregation") { workspace.useMongoTemplate("aggregate") }
                        Button("Indexes") { workspace.useMongoTemplate("listIndexes") }
                        if workspace.selectedBookmark?.isReadOnly != true {
                            Button("Insert document") { workspace.useMongoTemplate("insert") }
                            Button("Update documents") { workspace.useMongoTemplate("update") }
                            Button("Delete documents") { workspace.useMongoTemplate("delete") }
                        }
                    } label: {
                        Label("Query templates", systemImage: "curlybraces").frame(minHeight: 44)
                    }
                    .disabled(workspace.selectedExplorerTable == nil)
                }
                if !trimmedQuery.isEmpty && !workspace.suggestions.isEmpty {
                    suggestionSection
                }

                feedbackSection
            }
        }
        .portbaseEditorPresentation(isPresented: $isShowingExpandedEditor) {
            ExpandedQueryEditorSheet()
        }
        .sheet(isPresented: $isShowingLibrarySheet) {
            LibrarySheetView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Button {
            workspace.createBookmark()
        } label: {
            Label("Add Connection", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            runButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if workspace.isSQLDatabase {
                        actionButton("Run All", systemImage: "play.rectangle", disabled: workspace.isRunning || workspace.selectedBookmark == nil) {
                            workspace.runQuery(entireBuffer: true)
                        }
                    }
                    actionButton("FORMAT", systemImage: "text.alignleft", disabled: trimmedQuery.isEmpty) {
                        workspace.formatQuery()
                    }
                    if workspace.isSQLDatabase || workspace.isDocumentDatabase {
                        actionButton("EXPLAIN", systemImage: "waveform.path.ecg", disabled: workspace.selectedBookmark == nil || trimmedQuery.isEmpty) {
                            workspace.runExplain()
                        }
                    }
                    if workspace.isSQLDatabase { SQLTemplateMenu() }
                    actionButton("SAVE", systemImage: "bookmark", disabled: trimmedQuery.isEmpty) {
                        workspace.saveSnippet()
                    }
                    exportButton
                    DataTransferMenu()
                    ScriptFilesButton()
                    if workspace.isDocumentDatabase { MongoIndexesButton() }
                    ConsoleTransactionControls()
                    if workspace.isSchemaCachingEnabled {
                        actionButton("SCHEMA", systemImage: "arrow.clockwise", disabled: workspace.activeDatabaseName == nil || workspace.isLoadingSchema) {
                            workspace.refreshSchemaCatalog()
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollClipDisabled()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(workspace.editorPositionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if workspace.hasQuerySelection {
                PortbaseChip(title: L10n.text("Selection"), systemImage: "selection.pin.in.out", tint: PortSQLPalette.accent)
            }
            Spacer(minLength: 0)
            PortbaseChip(title: workspace.usesJSONEditor ? "JSON" : workspace.isSQLDatabase ? "SQL" : "Redis", tint: .secondary)
        }
    }

    private var exportButton: some View {
        Menu {
            if let csvURL = workspace.exportResultURL(format: .csv) {
                ShareLink(item: csvURL) {
                    Label("CSV", systemImage: "tablecells")
                }
            }
            if let jsonURL = workspace.exportResultURL(format: .json) {
                ShareLink(item: jsonURL) {
                    Label("JSON", systemImage: "curlybraces")
                }
            }
        } label: {
            Label("EXPORT", systemImage: "square.and.arrow.up")
                .labelStyle(.iconOnly)
                .toolIconChrome()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(workspace.result.columns.isEmpty && workspace.result.documents == nil)
    }

    private var editorSection: some View {
        ZStack(alignment: .topLeading) {
            HighlightedQueryEditor(
                text: $workspace.queryText,
                cursorOffset: $workspace.queryCursorOffset,
                selectionLength: $workspace.querySelectionLength,
                colorScheme: colorScheme,
                isJSON: workspace.usesJSONEditor,
                allowsSQLComments: workspace.isSQLDatabase,
                errorRange: workspace.queryErrorRange
            )
                .frame(minHeight: min(max(editorMinimumHeight, 220), 440))

            if workspace.queryText.isEmpty {
                Text(verbatim: workspace.editorPlaceholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                    .padding(.leading, 52)
                    .padding(.trailing, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(editorBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(workspace.queryErrorRange == nil ? editorBorderColor : Color.red.opacity(0.5), lineWidth: 1)
        }
    }

    private var suggestionSection: some View {
        InlineSuggestionMenu(
            suggestions: visibleSuggestions.map { InlineSuggestionItem(title: $0, subtitle: nil) },
            onSelect: { item in
                workspace.applySuggestion(item.title)
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleSuggestions: [String] {
        Array(workspace.suggestions.prefix(6))
    }

    private var editorBackgroundColor: Color {
        PortSQLPalette.editorBackground(for: colorScheme)
    }

    private var editorBorderColor: Color {
        PortSQLPalette.editorBorder(for: colorScheme)
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let schemaErrorMessage = workspace.schemaErrorMessage {
            ConnectionIssueBanner(message: schemaErrorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect)
        }

        ForEach(workspace.hints) { hint in
            StatusBanner(
                title: hint.title,
                message: hint.message,
                tint: hint.severity.tint
            )
        }
    }

    private var trimmedQuery: String {
        workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var querySubtitle: String {
        guard let bookmark = workspace.selectedBookmark else {
            return ""
        }

        let serverName = bookmark.displayTitle
        if let database = workspace.activeDatabaseName {
            return "\(serverName) • \(database)"
        }
        return serverName
    }

    private var runButton: some View {
        Button {
            if workspace.isRunning { workspace.cancelQuery() }
            else { workspace.runQuery() }
        } label: {
            HStack(spacing: 8) {
                if workspace.isRunning {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Stop")
                } else {
                    Image(systemName: "play.fill")
                    Text(workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run"))
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background {
                Capsule().fill(workspace.isRunning ? Color.red : PortSQLPalette.accent)
            }
            .opacity(runDisabled ? 0.45 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(runDisabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(workspace.isRunning ? L10n.text("Cancel Query") : (workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run Query")))
    }

    private var runDisabled: Bool {
        !workspace.isRunning && (workspace.selectedBookmark == nil || trimmedQuery.isEmpty)
    }

    private func actionButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.text(title), systemImage: systemImage)
                .labelStyle(.iconOnly)
                .toolIconChrome()
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(L10n.text(title))
    }

}

/// The duration and outcome of the most recent console execution.
struct ExecutionStatusChip: View {
    let entry: QueryHistoryEntry

    var body: some View {
        let outcome = entry.outcome ?? .succeeded
        PortbaseChip(
            title: [outcome.title, entry.duration.map { WorkspaceActivityService.durationLabel($0) }].compactMap { $0 }.joined(separator: " · "),
            systemImage: outcome == .succeeded ? "checkmark.circle.fill" : outcome == .failed ? "xmark.octagon.fill" : "stop.circle.fill",
            tint: outcome == .succeeded ? .green : outcome == .failed ? .red : .secondary
        )
        .accessibilityLabel(L10n.format("Last run: %@", outcome.title))
    }
}

private struct ExpandedQueryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                WorkbenchBackground()
                    .ignoresSafeArea()

                ZStack(alignment: .topLeading) {
                    HighlightedQueryEditor(
                        text: $workspace.queryText,
                        cursorOffset: $workspace.queryCursorOffset,
                        selectionLength: $workspace.querySelectionLength,
                        colorScheme: colorScheme,
                        isJSON: workspace.usesJSONEditor,
                        allowsSQLComments: workspace.isSQLDatabase,
                        errorRange: workspace.queryErrorRange
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if workspace.queryText.isEmpty {
                        Text(verbatim: workspace.editorPlaceholder)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.leading, 52)
                            .padding(.trailing, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(PortSQLPalette.editorBackground(for: colorScheme))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                }
                .padding(16)
            }
            .navigationTitle(workspace.usesJSONEditor ? L10n.text("JSON Editor") : workspace.isSQLDatabase ? L10n.text("SQL Editor") : L10n.text("Command Editor"))
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusLine() }
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: PortbaseToolbar.leading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: PortbaseToolbar.trailing) {
                    Button {
                        if workspace.isRunning { workspace.cancelQuery() }
                        else { workspace.runQuery() }
                    } label: {
                        if workspace.isRunning {
                            Label("Cancel Query", systemImage: "stop.fill")
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .disabled(!workspace.isRunning && (workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}

struct ResultsCard: View {
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var isShowingSchemaSheet = false
    @State private var composerPreset: SavedVisualizationPreset?
    @State private var schemaColumnDraft: SchemaColumnDraft?
    @State private var pendingSchemaColumnDeletion: SchemaColumnDeletionTarget?
    @State private var mongoResultView = "documents"
    @State private var tableResultView = "table"
    @State private var selectedDocument: MongoDocumentSelection?
    private let pagerControlHeight: CGFloat = 44

    private var hasTabularResult: Bool { !workspace.result.columns.isEmpty }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Results")
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        if let resultsMetadataSubtitle {
                            Text(resultsMetadataSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
                        if canCreateVisualization {
                            visualizerButton
                        }
                        if workspace.selectedExplorerTable != nil && workspace.selectedBookmark?.engine.supportsSchemaEditing == true {
                            schemaButton
                        }
                    }
                }

                if hasTabularResult || workspace.result.documents != nil {
                    resultChips
                }

                if workspace.resultSets.count > 1 {
                    Picker("Result Set", selection: Binding(get: { workspace.selectedResultIndex }, set: { workspace.selectResult($0) })) {
                        ForEach(workspace.resultSets.indices, id: \.self) { index in
                            Text(L10n.format("Result %d", index + 1)).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: 44)
                }

                if workspace.result.documents != nil {
                    Picker("Results", selection: $mongoResultView) {
                        Text("Documents").tag("documents")
                        Text("Table").tag("table")
                        Text("Chart").tag("chart")
                        Text("Insights").tag("insights")
                    }
                    .pickerStyle(.segmented)
                } else if hasTabularResult && !workspace.isRunning {
                    Picker("Results", selection: $tableResultView) {
                        Label("Table", systemImage: "tablecells").tag("table")
                        Label("Insights", systemImage: "sparkles").tag("insights")
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage = workspace.errorMessage {
                    if ConnectionIssue.isConnectionProblem(errorMessage) {
                        ConnectionIssueBanner(message: errorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect)
                    } else {
                        StatusBanner(
                            title: "Execution failed",
                            message: errorMessage,
                            tint: .red
                        )
                    }
                }

                if workspace.result.documents != nil || workspace.result.affectedRowCount != nil || workspace.result.isTruncated == true {
                    Text(workspace.result.executionSummary)
                        .font(.caption)
                        .foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                        .textSelection(.enabled)
                }

                if let sql = workspace.result.generatedMutation {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Generated mutation", systemImage: "pencil.and.list.clipboard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(sql)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if !workspace.isRunning && workspace.selectedBookmark?.isReadOnly != true && workspace.canInsertIntoCurrentTable {
                    Button {
                        workspace.prepareInsert()
                    } label: {
                        Label("Insert row", systemImage: "plus").frame(minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Insert row")
                }

                if !workspace.isRunning && workspace.isShowingExplorerResult {
                    HStack(spacing: 8) {
                        Button {
                            workspace.goToPreviousExplorerPage()
                        } label: {
                            Image(systemName: "chevron.left").toolIconChrome()
                        }
                        .buttonStyle(.plain)
                        .disabled(!workspace.canGoToPreviousExplorerPage)
                        .accessibilityLabel("Previous results page")
                        .accessibilityHint("Loads the preceding page of rows")

                        Spacer(minLength: 0)

                        pageStatusMenu

                        Spacer(minLength: 0)

                        Button {
                            workspace.goToNextExplorerPage()
                        } label: {
                            Image(systemName: "chevron.right").toolIconChrome()
                        }
                        .buttonStyle(.plain)
                        .disabled(!workspace.canGoToNextExplorerPage)
                        .accessibilityLabel("Next results page")
                        .accessibilityHint("Loads the following page of rows")
                    }
                }

                if workspace.isRunning {
                    LoadingStateView(
                        title: "Loading results",
                        message: "Fetching rows for the current request."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else if workspace.result.documents != nil && mongoResultView == "chart" {
                    if canCreateVisualization {
                        VisualizationChartPreview(preset: resultChartPreset, result: workspace.result, compact: false)
                        Button("Configure Chart") { composerPreset = resultChartPreset }.frame(minHeight: 44)
                    } else {
                        Text("Run a query with numeric fields to create a chart.").foregroundStyle(.secondary)
                    }
                } else if workspace.result.documents != nil && mongoResultView == "insights" {
                    ResultInsightsView(result: workspace.result)
                } else if let documents = workspace.result.documents, mongoResultView == "documents" || workspace.result.columns.isEmpty {
                    MongoDocumentResults(documents: documents, context: MongoDocumentMutationContext.from(workspace: workspace))
                } else if workspace.result.columns.isEmpty {
                    PortbaseEmptyState(
                        title: L10n.text("No live rows yet"),
                        message: workspace.result.affectedRowCount == nil ? L10n.text("Run a query to see results here.") : workspace.result.executionSummary,
                        systemImage: "tablecells"
                    )
                } else if workspace.result.documents == nil && tableResultView == "insights" {
                    ResultInsightsView(result: workspace.result)
                } else {
                    resultTable
                }
            }
        }
        .sheet(isPresented: $isShowingSchemaSheet) {
            schemaSheet
        }
        .sheet(item: $schemaColumnDraft) { draft in
            SchemaColumnEditorSheet(draft: draft)
        }
        .sheet(item: $composerPreset) { preset in
            VisualizerComposerSheet(initialPreset: preset)
        }
        .sheet(item: $selectedDocument) { selection in
            MongoDocumentInspector(selection: selection)
        }
        .alert(item: $pendingSchemaColumnDeletion) { target in
            let engine = workspace.selectedBookmark?.engine ?? .postgresql
            let plan = DatabaseService.dropColumnPlan(target.column, from: target.table, engine: engine)
            return Alert(
                title: Text("Delete Column"),
                message: Text(
                    L10n.format("Delete `%@` from `%@`? This will alter the live schema.", target.column.name, target.table.name)
                    + "\n\n" + plan.previewSQL
                ),
                primaryButton: .destructive(Text("Delete")) {
                    Task {
                        do {
                            try await workspace.deleteSchemaColumn(target.column, from: target.table)
                        } catch {
                            await MainActor.run {
                                workspace.errorMessage = error.localizedDescription
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var resultChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let documents = workspace.result.documents {
                    PortbaseChip(title: L10n.format("Documents: %d", documents.count), systemImage: "doc.on.doc", tint: PortSQLPalette.accent)
                } else {
                    PortbaseChip(title: L10n.plural("row_count", count: workspace.result.rows.count), systemImage: "list.number", tint: PortSQLPalette.accent)
                }
                if hasTabularResult {
                    PortbaseChip(title: L10n.plural("column_count_short", count: workspace.result.columns.count), systemImage: "tablecells", tint: .teal)
                }
                if workspace.result.isTruncated == true {
                    PortbaseChip(title: L10n.text("Result truncated"), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                if let execution = workspace.lastExecution, !workspace.isShowingExplorerResult {
                    ExecutionStatusChip(entry: execution)
                }
                if workspace.canEditCurrentRows {
                    PortbaseChip(title: L10n.text("Editable"), systemImage: "pencil", tint: .green)
                } else if workspace.selectedBookmark?.isReadOnly == true {
                    PortbaseChip(title: L10n.text("Read-only"), systemImage: "lock.fill", tint: .secondary)
                }
            }
        }
    }

    private var resultTable: some View {
        ResultGridView(
            result: workspace.result,
            primaryKeys: Set(workspace.isShowingExplorerResult ? (workspace.selectedExplorerTable?.primaryKeyColumns.map(\.name) ?? []) : []),
            sortedColumn: workspace.isShowingExplorerResult ? workspace.explorerSortColumn : nil,
            sortDirection: workspace.explorerSortDirection,
            persistenceKey: [workspace.selectedBookmark?.id.uuidString ?? "", workspace.activeDatabaseName ?? "", workspace.result.sourceTableReference ?? "console"].joined(separator: "."),
            onSort: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0) } : nil,
            onOpenRow: { offset in
                if let documents = workspace.result.documents, documents.indices.contains(offset) {
                    selectedDocument = MongoDocumentSelection(index: offset, json: documents[offset], context: MongoDocumentMutationContext.from(workspace: workspace))
                } else if workspace.result.rows.indices.contains(offset) {
                    workspace.prepareEdit(row: workspace.result.rows[offset])
                }
            },
            actionsForCell: { rowIndex, columnIndex in
                guard workspace.result.rows.indices.contains(rowIndex), workspace.result.columns.indices.contains(columnIndex) else { return [] }
                let row = workspace.result.rows[rowIndex]
                return workspace.foreignKeys.filter { $0.columns.contains(workspace.result.columns[columnIndex].name) }.map { key in
                    ResultGridRowAction(title: L10n.format("Go to %@", key.referencedTable)) {
                        guard workspace.result.rows.contains(where: { $0.id == row.id }) else { return }
                        workspace.followForeignKey(key, row: row)
                    }
                }
            },
            copyEngine: workspace.selectedBookmark?.engine,
            copyTableName: workspace.result.sourceTableReference ?? workspace.selectedExplorerTable?.displayName
        )
    }

    private var pageStatusMenu: some View {
        Menu {
            ForEach([10, 25, 50, 100], id: \.self) { size in
                Button {
                    workspace.setExplorerPageSize(size)
                } label: {
                    Label(
                        L10n.plural("row_count", count: size),
                        systemImage: workspace.explorerPageSize == size ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
            }
        } label: {
            VStack(spacing: 1) {
                Text(workspace.explorerPageLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PortSQLPalette.ink)
                Text(workspace.explorerResultRangeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 116, minHeight: 44)
            .padding(.horizontal, 12)
            .background(PortSQLPalette.sunken, in: Capsule())
            .overlay { Capsule().strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var schemaButton: some View {
        Button {
            isShowingSchemaSheet = true
        } label: {
            Image(systemName: "list.bullet.rectangle").toolIconChrome()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show schema")
    }

    private var resultChartPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result,
            connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }

    private var visualizerButton: some View {
        Button {
            composerPreset = VisualizationService.reconciledPreset(
                nil,
                for: workspace.result,
                connectionProfileID: workspace.selectedBookmark?.id,
                connectionName: workspace.selectedBookmark?.name ?? "Current Result",
                databaseName: workspace.activeDatabaseName,
                sourceTableReference: workspace.result.sourceTableReference
            )
        } label: {
            Image(systemName: "chart.bar.xaxis").toolIconChrome()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to visualizer")
        .accessibilityHint("Opens chart configuration for these results")
    }

    private var resultsMetadataSubtitle: String? {
        guard workspace.isShowingExplorerResult,
              let selectedTable = workspace.selectedExplorerTable else {
            return nil
        }

        var parts = [L10n.plural("column_count_short", count: workspace.isDocumentDatabase ? workspace.result.columns.count : selectedTable.columns.count)]
        if let rowCountEstimate = selectedTable.rowCountEstimate {
            parts.append(L10n.plural("row_count", count: rowCountEstimate))
        }
        return parts.joined(separator: " • ")
    }

    private var canCreateVisualization: Bool {
        !workspace.result.columns.isEmpty
            && VisualizationService.fieldDescriptors(for: workspace.result).contains(where: \.supportsNumeric)
    }

    private var rowInteractionLabel: String {
        workspace.canEditCurrentRows ? L10n.text("Tap a row to view or edit") : L10n.text("Tap a row to view")
    }

    private var schemaSheet: some View {
        NavigationStack {
            Group {
                if let selectedTable = workspace.selectedExplorerTable {
                    List(selectedTable.columns) { column in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(column.name)
                                        .font(.body.weight(.semibold))
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(PortSQLPalette.accent)
                                    }
                                }
                                Text(column.type)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(column.isNullable ? "NULL" : "NOT NULL")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(column.isNullable ? .secondary : PortSQLPalette.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.08), in: Capsule())

                            Button {
                                schemaColumnDraft = .edit(column, in: selectedTable)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PortSQLPalette.accent)
                                    .frame(width: 44, height: 44)
                                    .background(Color.secondary.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                            .accessibilityLabel("Edit column \(column.name)")
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingSchemaColumnDeletion = SchemaColumnDeletionTarget(table: selectedTable, column: column)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                        }
                    }
                    .listStyle(.portbaseGrouped)
                    .navigationTitle(selectedTable.name)
                    .portbaseTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: PortbaseToolbar.leading) {
                            Button {
                                schemaColumnDraft = .add(to: selectedTable)
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                        }
                        ToolbarItem(placement: PortbaseToolbar.trailing) {
                            Button("Done") {
                                isShowingSchemaSheet = false
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No table selected",
                        systemImage: "tablecells",
                        description: Text("Choose a table to inspect its schema.")
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var controlBackground: Color {
        PortSQLPalette.surface
    }
}

private struct SchemaColumnEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var draft: SchemaColumnDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var pendingPlan: SchemaMutationPlan?
    @State private var isConfirmingSchemaChange = false

    init(draft: SchemaColumnDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.table.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PortSQLPalette.ink)
                        if let originalName = draft.originalName, draft.mode == .edit {
                            Text(L10n.format("Editing `%@`", originalName))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Add a new column to the live table schema.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Column") {
                    TextField("Column name", text: $draft.name)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Column type", text: $draft.type)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Nullable", isOn: $draft.isNullable)
                }

                Section {
                    Text("Examples: `VARCHAR(255)`, `INT`, `TIMESTAMP`, `DECIMAL(10,2)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("SQL Preview") {
                    if let plan = try? currentPlan() {
                        Text(plan.previewSQL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("Enter a supported column definition to preview the exact schema change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        StatusBanner(
                            title: "Schema change failed",
                            message: errorMessage,
                            tint: .red
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(draft.mode.title)
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.mode.confirmationTitle) {
                        reviewSchemaChange()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Apply schema change?", isPresented: $isConfirmingSchemaChange, presenting: pendingPlan) { _ in
            Button("Apply Change", role: .destructive) {
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.previewSQL)
        }
    }

    private func currentPlan() throws -> SchemaMutationPlan {
        guard let engine = workspace.selectedBookmark?.engine else {
            throw DatabaseServiceError.notConfigured
        }
        var normalized = draft
        normalized.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.type = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        return try DatabaseService.schemaColumnChangePlan(for: normalized, engine: engine)
    }

    private func reviewSchemaChange() {
        errorMessage = nil
        do {
            pendingPlan = try currentPlan()
            isConfirmingSchemaChange = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await workspace.saveSchemaColumn(draft)
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct BookmarksView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var pendingDeletionIDs: [UUID] = []
    @State private var search = ""
    @State private var engineFilter: DatabaseEngine?
    @State private var onlyReadOnly = false
    @State private var isConfirmingDeletion = false

    var body: some View {
        List {
            if bookmarks.bookmarks.isEmpty {
                Section {
                    PortbaseEmptyState(
                        title: L10n.text("No servers saved"),
                        message: L10n.text("Add a connection to browse tables, run queries, and build charts."),
                        systemImage: "server.rack",
                        actionTitle: L10n.text("Add Connection"),
                        action: { workspace.createBookmark() }
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    serverSummary
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("Servers") {
                    if filteredBookmarks.isEmpty { Text("No matching servers").foregroundStyle(.secondary) }
                    ForEach(filteredBookmarks) { bookmark in
                        serverRow(bookmark)
                            .listRowBackground(workspace.selectedBookmarkID == bookmark.id ? PortSQLPalette.accent.opacity(0.08) : PortSQLPalette.surface)
                    }
                    .onDelete { offsets in
                        pendingDeletionIDs = offsets.compactMap { filteredBookmarks.indices.contains($0) ? filteredBookmarks[$0].id : nil }
                        isConfirmingDeletion = true
                    }
                }
            }

            Section("Sync") {
                Label("Server settings sync through iCloud. Passwords stay in this device’s Keychain.", systemImage: "icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(PortbaseBackdrop().ignoresSafeArea())
        .navigationTitle("Servers")
        .searchable(text: $search, prompt: L10n.text("Search servers"))
        .toolbar {
            Menu {
                Picker("Engine", selection: $engineFilter) {
                    Text("All Engines").tag(Optional<DatabaseEngine>.none)
                    ForEach(DatabaseEngine.allCases) { engine in Text(engine.rawValue).tag(Optional(engine)) }
                }
                Toggle("Read-only connections", isOn: $onlyReadOnly)
                Button("Reset Filters") { engineFilter = nil; onlyReadOnly = false; search = "" }
            } label: {
                Image(systemName: engineFilter != nil || onlyReadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Filter servers")
            Button {
                workspace.createBookmark()
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .accessibilityHint("Opens the server connection form")
        }
        .alert("Delete Server?", isPresented: $isConfirmingDeletion) {
            Button("Delete", role: .destructive) {
                let offsets = IndexSet(bookmarks.bookmarks.indices.filter { pendingDeletionIDs.contains(bookmarks.bookmarks[$0].id) })
                bookmarks.delete(at: offsets)
                pendingDeletionIDs.forEach { PinnedTableStore.shared.removeAll(for: $0) }
                pendingDeletionIDs = []
            }
            Button("Cancel", role: .cancel) {
                pendingDeletionIDs = []
            }
        } message: {
            Text("Deleting a server also removes its saved credentials from this device.")
        }
    }

    private var serverSummary: some View {
        HStack(spacing: 10) {
            PortbaseMetricTile(title: L10n.text("Connections"), value: bookmarks.bookmarks.count.formatted(), systemImage: "server.rack", tint: Color(hex: 0x6366F1))
            PortbaseMetricTile(title: L10n.text("Engines"), value: Set(bookmarks.bookmarks.map(\.engine)).count.formatted(), systemImage: "cylinder.split.1x2.fill", tint: Color(hex: 0x0EA5E9))
            PortbaseMetricTile(title: L10n.text("Encrypted"), value: bookmarks.bookmarks.filter { $0.engine.isLocal || $0.transportSecurityMode == .systemCA || $0.transportSecurityMode == .privateCA }.count.formatted(),
                               systemImage: "lock.shield.fill", tint: Color(hex: 0x10B981))
        }
        .padding(.vertical, 4)
    }

    private func serverRow(_ bookmark: ConnectionProfile) -> some View {
        let isActive = workspace.selectedBookmarkID == bookmark.id
        return HStack(spacing: 14) {
            BookmarkAvatar(profile: bookmark, size: 48, cornerRadius: 14)
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Circle().fill(Color.green)
                            .frame(width: 13, height: 13)
                            .overlay { Circle().strokeBorder(PortSQLPalette.surface, lineWidth: 2) }
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(bookmark.displayTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if isActive {
                        PortbaseChip(title: L10n.text("Active"), tint: .green)
                    }
                }
                Text(bookmark.endpointSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ConnectionSecurityChips(profile: bookmark)
                        PortbaseChip(title: bookmark.schemaCachingEnabled ? L10n.format("Cache %@", bookmark.schemaCacheDurationLabel) : L10n.text("Table list caching off"),
                                     systemImage: "clock.arrow.2.circlepath", tint: .secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                workspace.selectedProfileForEdit = bookmark
            } label: {
                Image(systemName: "slider.horizontal.3").toolIconChrome()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Edit %@", bookmark.displayTitle))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { workspace.selectBookmark(bookmark.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Edit")) { workspace.selectedProfileForEdit = bookmark }
        .contextMenu {
            Button("Connect", systemImage: "bolt.horizontal.fill") { workspace.selectBookmark(bookmark.id) }
            Button("Duplicate Connection", systemImage: "plus.square.on.square") {
                workspace.selectedProfileForEdit = bookmark.duplicate()
            }
            Button("Edit", systemImage: "pencil") { workspace.selectedProfileForEdit = bookmark }
        }
    }

    private var filteredBookmarks: [ConnectionProfile] {
        bookmarks.bookmarks.filter { profile in
            (engineFilter == nil || profile.engine == engineFilter)
                && (!onlyReadOnly || profile.isReadOnly)
                && (search.isEmpty || [profile.name, profile.host, profile.defaultDatabase, profile.username, profile.notes, profile.engine.rawValue]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
}

enum TransportSecurityEditorState {
    static let maximumCertificateSize = 1_048_576

    static func canSave(
        host: String,
        mode: TransportSecurityMode,
        privateCACertificate: String
    ) -> Bool {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return mode != .privateCA || isValidPrivateCACertificate(privateCACertificate)
    }

    static func isValidPrivateCACertificate(_ pem: String) -> Bool {
        let normalized = pem
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= maximumCertificateSize else { return false }

        let uppercase = normalized.uppercased()
        guard !uppercase.contains("PRIVATE KEY"),
              let certificates = certificateData(in: normalized),
              !certificates.isEmpty else {
            return false
        }

        return certificates.allSatisfy { certificate in
            SecCertificateCreateWithData(nil, certificate as CFData) != nil
        }
    }

    static func pemEncodedCertificate(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumCertificateSize else { return nil }

        if let text = String(data: data, encoding: .utf8) {
            let normalized = text
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidPrivateCACertificate(normalized) {
                return normalized + "\n"
            }
        }

        guard SecCertificateCreateWithData(nil, data as CFData) != nil else { return nil }
        let encoded = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----"
        return isValidPrivateCACertificate(pem) ? pem + "\n" : nil
    }

    private static func certificateData(in pem: String) -> [Data]? {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        let sections = pem.components(separatedBy: beginMarker)
        guard sections.count > 1,
              sections.count - 1 == pem.components(separatedBy: endMarker).count - 1 else {
            return nil
        }

        var certificates: [Data] = []
        for section in sections.dropFirst() {
            guard let end = section.range(of: endMarker) else { return nil }
            let encoded = section[..<end.lowerBound].filter { !$0.isWhitespace }
            guard let certificate = Data(base64Encoded: String(encoded)), !certificate.isEmpty else {
                return nil
            }
            certificates.append(certificate)
        }
        return certificates
    }
}

private extension TransportSecurityMode {
    var localizedTitle: String {
        switch self {
        case .systemCA:
            L10n.text("TLS Required (System CAs)")
        case .privateCA:
            L10n.text("TLS Required (Private CA)")
        case .preferTLS:
            L10n.text("Prefer TLS")
        case .plaintext:
            L10n.text("Plaintext Only")
        }
    }
}

struct BookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State var profile: ConnectionProfile
    @State private var isShowingIconPicker = false
    @State private var isImportingPrivateCA = false
    @State private var privateCAImportError: String?
    @State private var saveError: String?
    /// Set when a connection string import changes the engine, so its imported port is kept.
    @State private var keepsImportedEndpoint = false
    @State private var testTask: Task<Void, Never>?
    @State private var testResult: Result<ConnectionTester.Success, Error>?

    private static let certificateContentTypes: [UTType] = {
        let filenameTypes = ["pem", "crt", "cer"].compactMap { UTType(filenameExtension: $0) }
        return Array(Set([UTType.x509Certificate, .plainText] + filenameTypes))
    }()

    private var canSave: Bool {
        if profile.engine.isLocal { return profile.sqliteFileName != nil }
        if profile.engine == .redis, !profile.trimmedDefaultDatabase.isEmpty,
           Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true { return false }
        return (1...65_535).contains(profile.port) && MongoConnectionURI.isValidProfile(profile) && TransportSecurityEditorState.canSave(
            host: profile.host,
            mode: profile.transportSecurityMode,
            privateCACertificate: profile.privateCACertificate
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                ConnectionStringImportSection(profile: $profile, willChangeEngine: { keepsImportedEndpoint = true })

                Section("Engine") {
                    EngineChooser(selection: $profile.engine)
                    .onChange(of: profile.engine) { oldValue, engine in
                        if keepsImportedEndpoint { keepsImportedEndpoint = false; return }
                        profile.port = engine == .clickhouse && profile.transportSecurityMode == .plaintext ? 8123 : engine.defaultPort
                        if engine == .clickhouse, profile.httpAuthentication == .apiKey { profile.httpAuthentication = .basic }
                        if engine == .redis, Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true { profile.defaultDatabase = "0" }
                        if profile.iconName == BookmarkIconCatalog.defaultName(for: oldValue) {
                            profile.iconName = nil
                        }
                    }
                }

                if profile.engine == .mongodb { MongoConnectionURISection(profile: $profile) }

                Section("Server") {
                    TextField("Name", text: $profile.name)
#if !os(macOS)
                    Button {
                        isShowingIconPicker = true
                    } label: {
                        HStack {
                            Text("Icon")
                            Spacer()
                            BookmarkAvatar(profile: profile, size: 32, cornerRadius: 10)
                            Text(profile.resolvedIconName ?? profile.initials)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
#endif
                    if !profile.engine.isLocal {
                    TextField("Host", text: $profile.host)
                        .portbaseTextCapitalization(.never)
                    TextField("Port", text: Binding(
                        get: { String(profile.port) },
                        set: { input in
                            let digits = input.filter(\.isNumber)
                            profile.port = Int(digits) ?? 0
                        }
                    ))
                        .portbaseKeyboardType(.numberPad)
                    TextField(profile.engine == .redis ? L10n.text("Database number") : L10n.text("Default Database"), text: $profile.defaultDatabase)
                        .portbaseKeyboardType(profile.engine == .redis ? .numberPad : .default)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                    if profile.engine == .mongodb {
                        TextField("Authentication database", text: $profile.authenticationDatabase)
                            .onChange(of: profile.authenticationDatabase) { _, _ in profile.mongoConnection.authenticationSourceIsExplicit = true }
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    }
                    Toggle("Read-only mode", isOn: $profile.isReadOnly)
                }

                Section {
                    EnvironmentPicker(selection: $profile.environment)
                } header: {
                    Text("Environment")
                } footer: {
                    Text("A labeled environment shows a colored stripe and badge wherever this connection is open.")
                }

                if profile.engine.isLocal { SQLiteConnectionSection(profile: $profile) }
                if !profile.engine.isLocal {
                Section("Transport Security") {
                    Picker("Security Mode", selection: $profile.transportSecurityMode) {
                        ForEach(TransportSecurityMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.portbaseNavigation)
                    .onChange(of: profile.transportSecurityMode) { previous, next in
                        privateCAImportError = nil
                        if profile.engine == .clickhouse, profile.port == (previous == .plaintext ? 8123 : 8443) {
                            profile.port = next == .plaintext ? 8123 : 8443
                        }
                    }

                    transportSecurityDetails
                    if !profile.engine.canNegotiateTLS && profile.transportSecurityMode == .preferTLS {
                        Text("This engine requires TLS in Prefer TLS mode because its protocol cannot safely negotiate a plaintext fallback.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("SSH Tunnel") {
                    Toggle("Connect through SSH", isOn: $profile.usesSSHTunnel)

                    if profile.usesSSHTunnel {
                        TextField("SSH Host", text: $profile.sshHost)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("SSH Port", text: Binding(
                            get: { String(profile.sshPort) },
                            set: { input in
                                let digits = input.filter(\.isNumber)
                                profile.sshPort = Int(digits) ?? 22
                            }
                        ))
                        .portbaseKeyboardType(.numberPad)
                        TextField("SSH Username", text: $profile.sshUsername)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("SSH Password", text: $profile.sshPassword)
                        TextField("Private Key", text: $profile.sshPrivateKey, axis: .vertical)
                            .font(.system(.caption, design: .monospaced))
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        Text("SSH credentials are stored in Keychain on this device. Portbase opens a local loopback forward and verifies the SSH host key after first trust. Password login and unencrypted OpenSSH Ed25519/ECDSA private keys are supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                }
                Section("Caching") {
                    Toggle("Cache table lists", isOn: $profile.schemaCachingEnabled)

                    if profile.schemaCachingEnabled {
                        Stepper(
                            "Duration: \(profile.schemaCacheDurationLabel)",
                            value: $profile.schemaCacheDurationHours,
                            in: 1...168,
                            step: 1
                        )

                        Text("Table and column metadata is reused until this duration expires. The refresh button bypasses the cache.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When caching is off, Portbase always reloads table lists from the database and hides manual refresh controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if profile.engine == .clickhouse || profile.engine == .elasticsearch {
                    HTTPDatabaseAuthenticationSection(profile: $profile)
                } else if !profile.engine.isLocal {
                Section("Credentials") {
                    TextField("Username", text: $profile.username)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $profile.password)
#if !os(macOS)
                    Text("Database passwords are stored in Keychain on this device and are no longer written to iCloud bookmark data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
                }

                }
                Section {
                    Button {
                        runConnectionTest()
                    } label: {
                        HStack(spacing: 8) {
                            if testTask != nil { ProgressView().controlSize(.small) }
                            else { Image(systemName: "bolt.horizontal.circle") }
                            Text(testTask != nil ? L10n.text("Testing…") : L10n.text("Test Connection"))
                        }
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
                    }
                    .disabled(!canSave || testTask != nil)
                    switch testResult {
                    case .success(let success):
                        Label(ConnectionTester.summary(success), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        ConnectionIssueBanner(message: DatabaseErrorFormatter.message(for: error))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    case nil:
                        EmptyView()
                    }
                } footer: {
                    Text("Testing uses read-only requests and doesn’t save the connection.")
                }
                .onChange(of: profile) { _, _ in testResult = nil }

                if let saveError { Section { Text(saveError).foregroundStyle(.red).textSelection(.enabled) } }
                Section("Notes") {
                    TextField("Notes", text: $profile.notes, axis: .vertical)
                }
            }
#if os(macOS)
            .formStyle(.grouped)
            .navigationTitle("Connection")
#else
            .navigationTitle("Connection")
            .portbaseTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if workspace.saveBookmark(profile) { dismiss() }
                        else { saveError = workspace.errorMessage }
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $isShowingIconPicker) {
                BookmarkIconPicker(profile: $profile)
            }
            .onDisappear { testTask?.cancel() }
            .fileImporter(
                isPresented: $isImportingPrivateCA,
                allowedContentTypes: Self.certificateContentTypes,
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessedSecurityScopedResource {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard let pem = TransportSecurityEditorState.pemEncodedCertificate(from: data) else {
                        privateCAImportError = L10n.text("The selected file does not contain a valid X.509 certificate.")
                        return
                    }
                    profile.privateCACertificate = pem
                    privateCAImportError = nil
                } catch {
                    privateCAImportError = L10n.text("Portbase could not read this certificate file.")
                }
            }
        }
    }

    private func runConnectionTest() {
        testTask?.cancel()
        testResult = nil
        let candidate = profile
        testTask = Task {
            do {
                let success = try await ConnectionTester.test(candidate)
                if !Task.isCancelled { testResult = .success(success) }
            } catch {
                if !Task.isCancelled { testResult = .failure(error) }
            }
            testTask = nil
        }
    }

    @ViewBuilder
    private var transportSecurityDetails: some View {
        switch profile.transportSecurityMode {
        case .systemCA:
#if !os(macOS)
            Label("Recommended secure default", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
#endif
            Text("Encrypts the connection and verifies the server certificate using trusted system certificate authorities.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .privateCA:
            Text("TLS remains required. The private CA is added to the trusted system certificate authorities.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "Paste PEM certificate",
                text: $profile.privateCACertificate,
                axis: .vertical
            )
            .lineLimit(6...12)
            .font(.system(.caption, design: .monospaced))
            .portbaseTextCapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Private CA Certificate")
            .onChange(of: profile.privateCACertificate) { _, _ in
                privateCAImportError = nil
            }

            Button {
                isImportingPrivateCA = true
            } label: {
                Label(
                    profile.privateCACertificate.isEmpty
                        ? L10n.text("Import Certificate")
                        : L10n.text("Replace Certificate"),
                    systemImage: "doc.badge.plus"
                )
            }

            if !profile.privateCACertificate.isEmpty {
                Button(role: .destructive) {
                    profile.privateCACertificate = ""
                    privateCAImportError = nil
                } label: {
                    Label("Clear Certificate", systemImage: "trash")
                }
            }

            if let privateCAImportError {
                StatusBanner(
                    title: L10n.text("Certificate Import Failed"),
                    message: privateCAImportError,
                    tint: .red
                )
            } else if TransportSecurityEditorState.isValidPrivateCACertificate(profile.privateCACertificate) {
                Label("Certificate ready", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else if profile.privateCACertificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                StatusBanner(
                    title: L10n.text("Certificate Required"),
                    message: L10n.text("Paste a PEM certificate or import a .pem, .crt, or .cer file. Save remains unavailable until the certificate is valid."),
                    tint: .orange
                )
            } else {
                StatusBanner(
                    title: L10n.text("Invalid Certificate"),
                    message: L10n.text("The private CA must contain valid PEM certificate blocks and must not include a private key."),
                    tint: .red
                )
            }

            Label(
                "Private CA certificates are stored in this device’s Keychain and do not sync through iCloud.",
                systemImage: "iphone.and.arrow.forward"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .preferTLS:
            StatusBanner(
                title: L10n.text("Security Warning"),
                message: L10n.text("Prefer TLS can fall back to plaintext only when the server does not support TLS. Certificate errors never trigger a downgrade."),
                tint: .orange
            )

        case .plaintext:
            StatusBanner(
                title: L10n.text("Unencrypted Connection"),
                message: L10n.text("Plaintext sends database credentials and data without encryption. Use it only for legacy servers on a trusted network."),
                tint: .red
            )
        }
    }
}

/// Engine tiles with brand colors, replacing a plain menu picker.
private struct EngineChooser: View {
    @Binding var selection: DatabaseEngine

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
            ForEach(DatabaseEngine.allCases) { engine in
                let selected = selection == engine
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = engine } } label: {
                    VStack(spacing: 6) {
                        Image(systemName: engine.symbolName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(LinearGradient(colors: engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        Text(engine.rawValue)
                            .font(.caption2.weight(selected ? .bold : .medium))
                            .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(selected ? PortSQLPalette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.rawValue)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BookmarkIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: ConnectionProfile
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 68, maximum: 92), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Label("Search", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("server, chart, folder", text: $searchText)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(PortSQLPalette.stroke, lineWidth: 1)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredIcons, id: \.self) { iconName in
                            Button {
                                profile.iconName = iconName
                            } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            iconName == profile.resolvedIconName
                                                ? AnyShapeStyle(profile.engine.gradient)
                                                : AnyShapeStyle(PortSQLPalette.surface)
                                        )
                                        .frame(height: 68)
                                        .overlay {
                                            Image(systemName: iconName)
                                                .font(.title2.weight(.semibold))
                                                .foregroundStyle(iconName == profile.resolvedIconName ? .white : PortSQLPalette.ink)
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .stroke(iconName == profile.resolvedIconName ? Color.clear : PortSQLPalette.stroke, lineWidth: 1)
                                        }

                                    Text(iconName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
            }
            .background(WorkbenchBackground().ignoresSafeArea())
            .navigationTitle("Choose Icon")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Initials") {
                        profile.iconName = nil
                    }
                }
            }
        }
    }

    private var filteredIcons: [String] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return BookmarkIconCatalog.names }
        return BookmarkIconCatalog.names.filter { $0.lowercased().contains(needle) }
    }
}

struct QueryParameterSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QueryParameterDraft

    init(draft: QueryParameterDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Parameters") {
                    ForEach(draft.names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(name, text: Binding(
                                get: { draft.values[name] ?? "" },
                                set: { draft.values[name] = $0 }
                            ))
                            .disabled(draft.nullParameters.contains(name))
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()

                            Toggle("NULL", isOn: Binding(
                                get: { draft.nullParameters.contains(name) },
                                set: { enabled in
                                    if enabled { draft.nullParameters.insert(name) }
                                    else { draft.nullParameters.remove(name) }
                                }
                            ))
                        }
                    }
                }

                if let parameterErrorMessage = workspace.parameterErrorMessage {
                    Section {
                        Text(parameterErrorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Preview") {
                    Text(QueryParameterService.render(
                        sql: draft.sourceSQL,
                        values: draft.values,
                        nullParameters: draft.nullParameters,
                        engine: workspace.selectedBookmark?.engine ?? .postgresql
                    ))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Query Parameters")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        workspace.cancelParameters()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if workspace.applyParameters(draft) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct DataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let binding = Binding($workspace.dataEditorDraft) {
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(binding.wrappedValue.table.displayName)
                                    .font(.headline)
                                Text(editorSubtitle(for: binding.wrappedValue.mode))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("Columns") {
                            ForEach(binding.fields) { fieldBinding in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Text(fieldBinding.wrappedValue.column.name)
                                            .font(.subheadline.weight(.semibold))
                                        if fieldBinding.wrappedValue.column.isPrimaryKey {
                                            Text("PK")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(PortSQLPalette.accent, in: Capsule())
                                        }
                                        Spacer()
                                        Text(L10n.format(
                                            "%@ • %@",
                                            fieldBinding.wrappedValue.column.type,
                                            L10n.text(fieldBinding.wrappedValue.column.isNullable ? "nullable" : "required")
                                        ))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    fieldValueEditor(fieldBinding)

                                    if fieldBinding.wrappedValue.column.isNullable,
                                       fieldBinding.wrappedValue.isEditable {
                                        Toggle("NULL", isOn: fieldBinding.isNull)
                                            .accessibilityHint("Stores a database NULL instead of a value")
                                    }

                                    if let validationMessage = workspace.dataEditorValidation[fieldBinding.wrappedValue.id] {
                                        Text(validationMessage)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }

                        if let errorMessage = workspace.dataEditorErrorMessage {
                            Section {
                                StatusBanner(
                                    title: "Save failed",
                                    message: errorMessage,
                                    tint: .red
                                )
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(workspace.dataEditorDraft?.mode.title ?? "Data Editor")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        workspace.dismissDataEditor()
                        dismiss()
                    }
                    .disabled(workspace.isSavingMutation)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if workspace.dataEditorDraft?.mode == .view {
                        Button("Done") {
                            workspace.dismissDataEditor()
                            dismiss()
                        }
                    } else {
                        Button("Save") {
                            workspace.saveDataEditor()
                        }
                        .disabled(workspace.isSavingMutation)
                    }
                }
            }
        }
        .interactiveDismissDisabled(workspace.isSavingMutation)
        .onChange(of: workspace.dataEditorDraft == nil) { _, isNil in
            if isNil {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func fieldValueEditor(_ fieldBinding: Binding<DataEditorField>) -> some View {
        if fieldBinding.wrappedValue.isNull {
            Text("NULL")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .italic()
        } else if DataEditorValidationService.isJSONColumn(fieldBinding.wrappedValue.column) {
            JSONFieldEditor(
                value: fieldBinding.value,
                isEditable: fieldBinding.wrappedValue.isEditable,
                placeholder: DataEditorValidationService.placeholder(for: fieldBinding.wrappedValue.column),
                colorScheme: colorScheme
            )
        } else if fieldBinding.wrappedValue.isEditable {
            TextField(
                DataEditorValidationService.placeholder(for: fieldBinding.wrappedValue.column),
                text: fieldBinding.value
            )
            .portbaseTextCapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .portbaseKeyboardType(DataEditorValidationService.keyboardType(for: fieldBinding.wrappedValue.column))
        } else {
            Text(fieldBinding.wrappedValue.value.isEmpty ? "\"\"" : fieldBinding.wrappedValue.value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func editorSubtitle(for mode: DataEditorMode) -> String {
        switch mode {
        case .view:
            return L10n.text("Inspect the selected row. This result isn’t currently writable, so fields are shown read-only.")
        case .insert:
            return L10n.text("Insert a new row with schema-aware validation.")
        case .update:
            return L10n.text("Update the selected row and write the mutation back to the database.")
        }
    }
}

private struct JSONFieldEditor: View {
    @Binding var value: String
    let isEditable: Bool
    let placeholder: String
    let colorScheme: ColorScheme

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidJSON: Bool {
        trimmedValue.isEmpty || DataEditorValidationService.formattedJSON(trimmedValue) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditable {
                HStack(spacing: 8) {
                    Label(isValidJSON ? "JSON" : "Invalid JSON", systemImage: isValidJSON ? "curlybraces" : "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isValidJSON ? Color.secondary : Color.red)

                    Spacer()

                    Button("Format") {
                        applyJSONFormatting(prettyPrinted: true)
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(!canFormatJSON)

                    Button("Minify") {
                        applyJSONFormatting(prettyPrinted: false)
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(!canFormatJSON)
                }

                ZStack(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(placeholder)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $value)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                }
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isValidJSON ? PortSQLPalette.editorBorder(for: colorScheme) : Color.red.opacity(0.55), lineWidth: 1)
                }
            } else {
                ScrollView {
                    Text(value.isEmpty ? "NULL" : value)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 180)
                .padding(10)
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                }
            }
        }
    }

    private var canFormatJSON: Bool {
        DataEditorValidationService.formattedJSON(trimmedValue) != nil
    }

    private func applyJSONFormatting(prettyPrinted: Bool) {
        guard let formatted = DataEditorValidationService.formattedJSON(trimmedValue, prettyPrinted: prettyPrinted) else {
            return
        }
        value = formatted
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(PortSQLPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PortbaseMetrics.cardPadding)
        .portbaseCardSurface()
    }
}

struct LoadingStateView: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(PortSQLPalette.accent)
                .frame(width: 36, height: 36)
                .background(PortSQLPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PortSQLPalette.ink)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PortSQLPalette.stroke, lineWidth: 1)
        }
    }
}

struct StatusBanner: View {
    let title: String
    let message: String
    let tint: Color
    var titleColor: Color = PortSQLPalette.ink
    var messageColor: Color = .secondary
    var backgroundColor: Color? = nil

    private var symbol: String {
        switch tint {
        case .red: "xmark.octagon.fill"
        case .orange, .yellow: "exclamationmark.triangle.fill"
        case .green: "checkmark.circle.fill"
        default: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageColor)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background((backgroundColor ?? tint.opacity(0.10)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous)
                .fill(tint)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct InlineSuggestionItem: Hashable {
    let title: String
    let subtitle: String?
}

struct InlineSuggestionMenu: View {
    let suggestions: [InlineSuggestionItem]
    let onSelect: (InlineSuggestionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(PortSQLPalette.ink)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: PortbaseControlSize.minimumHeight)
                            .background(PortSQLPalette.sunken, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Insert %@", item.title))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchBackground: View {
    var body: some View {
        PortbaseBackdrop()
    }
}

private extension Binding {
    init?(_ source: Binding<Value?>) {
        guard let wrapped = source.wrappedValue else { return nil }
        self.init(
            get: { source.wrappedValue ?? wrapped },
            set: { source.wrappedValue = $0 }
        )
    }
}

private extension Binding where Value == DataEditorDraft {
    var fields: [Binding<DataEditorField>] {
        wrappedValue.fields.indices.map { index in
            Binding<DataEditorField>(
                get: { wrappedValue.fields[index] },
                set: { wrappedValue.fields[index] = $0 }
            )
        }
    }
}

private extension Binding where Value == DataEditorField {
    var value: Binding<String> {
        Binding<String>(
            get: { wrappedValue.value },
            set: { wrappedValue.value = $0 }
        )
    }
}
