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
                                    Image(systemName: "gearshape").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
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
                    BookmarksView(onOpenConsole: { navigate(.console) })
                }
            }
            .badge(hasConnectionProblem ? Text(verbatim: "!") : nil)

        }
        .tabViewStyle(.sidebarAdaptable)
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
            Image(systemName: "line.3.horizontal.decrease.circle").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
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
                ConnectionSwitcherButton()
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
            } label: {
                HStack(spacing: Spacing.xs) {
                    if workspace.isLoadingSchema {
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

struct QueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var editorMinimumHeight: CGFloat = 160
    @State private var isShowingExpandedEditor = false
    @State private var isShowingLibrarySheet = false

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
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
                        Label("Query templates", systemImage: "curlybraces").frame(minHeight: Sizes.touchTarget)
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
                .frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.borderedProminent)
    }

    private var actionSection: some View {
        HStack(spacing: Spacing.s) {
            runButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
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
                .padding(.vertical, Spacing.xxxs)
            }
            .scrollClipDisabled()
            .mask {
                // Fades the scrolling tools under the fixed buttons instead of cutting them off.
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: Spacing.l)
                }
            }
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
    }

    private var statusLine: some View {
        HStack(spacing: Spacing.s) {
            Text(workspace.editorPositionLabel)
                .font(.codeCaption)
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
                .frame(minHeight: min(max(editorMinimumHeight, 160), 360))

            if workspace.queryText.isEmpty {
                Text(verbatim: workspace.editorPlaceholder)
                    .font(.codeText)
                    .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                    .padding(.leading, Sizes.editorGutter + Spacing.s)
                    .padding(.trailing, Spacing.l)
                    .padding(.vertical, Spacing.l)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(editorBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
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
            ConnectionIssueBanner(message: schemaErrorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
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

    private var runButton: some View {
        Button {
            if workspace.isRunning { workspace.cancelQuery() }
            else { workspace.runQuery() }
        } label: {
            HStack(spacing: Spacing.s) {
                if workspace.isRunning {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Stop")
                } else {
                    Image(systemName: "play.fill")
                    Text(workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run"))
                }
            }
            .font(.rowDetail.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: Sizes.touchTarget)
            .background {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(workspace.isRunning ? Color.red : PortSQLPalette.accent)
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
                            .font(.codeText)
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.leading, Sizes.editorGutter + Spacing.s)
                            .padding(.trailing, Spacing.l)
                            .padding(.vertical, Spacing.l)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(PortSQLPalette.editorBackground(for: colorScheme))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                }
                .padding(Spacing.l)
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

    private var hasTabularResult: Bool { !workspace.result.columns.isEmpty }
    private var queryPlan: QueryPlan? {
        guard QueryPlanService.isExplainResult(workspace.result) else { return nil }
        return QueryPlanService.plan(from: workspace.result, engine: workspace.selectedBookmark?.engine ?? .postgresql)
    }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    Text("Results")
                        .font(.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    HStack(spacing: Spacing.s) {
                        if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
                        if !workspace.isRunning && workspace.selectedBookmark?.isReadOnly != true && workspace.canInsertIntoCurrentTable {
                            Button {
                                workspace.prepareInsert()
                            } label: {
                                Image(systemName: "plus").toolIconChrome()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert row")
                            .help(L10n.text("Insert row"))
                        }
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
                    .frame(minHeight: Sizes.touchTarget)
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
                        if queryPlan != nil { Label("Plan", systemImage: "list.bullet.indent").tag("plan") }
                        Label("Table", systemImage: "tablecells").tag("table")
                        Label("Insights", systemImage: "sparkles").tag("insights")
                    }
                    .pickerStyle(.segmented)
                }

                if let errorMessage = workspace.errorMessage {
                    if ConnectionIssue.isConnectionProblem(errorMessage) {
                        ConnectionIssueBanner(message: errorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
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
                        .font(.captionText)
                        .foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                        .textSelection(.enabled)
                }

                if let sql = workspace.result.generatedMutation {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Label("Generated mutation", systemImage: "pencil.and.list.clipboard")
                            .font(.rowTitle)
                            .foregroundStyle(.orange)
                        Text(sql)
                            .font(.codeCaption)
                            .textSelection(.enabled)
                    }
                    .padding(Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }

                if !workspace.isRunning && workspace.isShowingExplorerResult {
                    HStack(spacing: 0) {
                        pageStatusMenu
                        Spacer(minLength: Spacing.s)
                        Button {
                            workspace.goToPreviousExplorerPage()
                        } label: {
                            Image(systemName: "chevron.left").toolIconChrome()
                        }
                        .buttonStyle(.plain)
                        .disabled(!workspace.canGoToPreviousExplorerPage)
                        .accessibilityLabel("Previous results page")
                        .accessibilityHint("Loads the preceding page of rows")
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
                    .padding(.vertical, Spacing.l)
                } else if workspace.result.documents != nil && mongoResultView == "chart" {
                    if canCreateVisualization {
                        VisualizationChartPreview(preset: resultChartPreset, result: workspace.result, compact: false)
                        Button("Configure Chart") { composerPreset = resultChartPreset }.frame(minHeight: Sizes.touchTarget)
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
                } else if workspace.result.documents == nil && tableResultView == "plan", let queryPlan {
                    QueryPlanView(plan: queryPlan)
                } else {
                    resultTable
                }
            }
        }
        .onChange(of: queryPlan != nil, initial: true) { _, hasPlan in
            // Explain results open on their plan; other results return to the table.
            if hasPlan { tableResultView = "plan" } else if tableResultView == "plan" { tableResultView = "table" }
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
            HStack(spacing: Spacing.xs) {
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
                var actions = workspace.foreignKeys.filter { $0.columns.contains(workspace.result.columns[columnIndex].name) }.map { key in
                    ResultGridRowAction(title: L10n.format("Go to %@", key.referencedTable)) {
                        guard workspace.result.rows.contains(where: { $0.id == row.id }) else { return }
                        workspace.followForeignKey(key, row: row)
                    }
                }
                if workspace.canInsertIntoCurrentTable, workspace.selectedBookmark?.isReadOnly != true, workspace.result.documents == nil {
                    actions.insert(ResultGridRowAction(title: L10n.text("Duplicate Row"), symbolName: "plus.square.on.square") {
                        workspace.prepareDuplicate(row: row)
                    }, at: 0)
                }
                return actions
            },
            copyEngine: workspace.selectedBookmark?.engine,
            copyTableName: workspace.result.sourceTableReference ?? workspace.selectedExplorerTable?.displayName
        )
    }

    private var pageStatusMenu: some View {
        Menu {
            ForEach(WorkspaceViewModel.explorerPageSizes, id: \.self) { size in
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
            HStack(spacing: Spacing.xs) {
                Text(workspace.explorerPageLabel)
                    .font(.captionStrong)
                    .foregroundStyle(PortSQLPalette.ink)
                Text(workspace.explorerResultRangeLabel)
                    .font(.captionText.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.microText)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: Sizes.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Chooses how many rows each page loads")
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
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                HStack(spacing: Spacing.xs) {
                                    Text(column.name)
                                        .font(.bodyText.weight(.semibold))
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill")
                                            .font(.captionStrong)
                                            .foregroundStyle(PortSQLPalette.accent)
                                    }
                                }
                                Text(column.type)
                                    .font(.captionText)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(column.isNullable ? "NULL" : "NOT NULL")
                                .font(.badgeText)
                                .foregroundStyle(column.isNullable ? .secondary : PortSQLPalette.ink)
                                .padding(.horizontal, Spacing.s)
                                .padding(.vertical, Spacing.xxs)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))

                            Button {
                                schemaColumnDraft = .edit(column, in: selectedTable)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.captionStrong)
                                    .foregroundStyle(PortSQLPalette.accent)
                                    .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                                    .background(Color.secondary.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                            .accessibilityLabel("Edit column \(column.name)")
                        }
                        .padding(.vertical, Spacing.xxxs)
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
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(draft.table.displayName)
                            .font(.rowTitle)
                            .foregroundStyle(PortSQLPalette.ink)
                        if let originalName = draft.originalName, draft.mode == .edit {
                            Text(L10n.format("Editing `%@`", originalName))
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Add a new column to the live table schema.")
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
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
                        .font(.captionText)
                        .foregroundStyle(.secondary)
                }

                Section("SQL Preview") {
                    if let plan = try? currentPlan() {
                        Text(plan.previewSQL)
                            .font(.codeCaption)
                            .textSelection(.enabled)
                    } else {
                        Text("Enter a supported column definition to preview the exact schema change.")
                            .font(.captionText)
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
    var onOpenConsole: (() -> Void)?
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var pendingDeletion: ConnectionProfile?
    @State private var createsSQLite = false

    var body: some View {
        ConnectionsHubView(onOpenConsole: onOpenConsole, onCreateSQLite: { createsSQLite = true }, onDelete: { pendingDeletion = $0 })
            .navigationTitle("Servers")
            .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { onOpenConsole?() }
            .alert("Delete Server?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                Button("Delete", role: .destructive) {
                    if let profile = pendingDeletion, let index = bookmarks.bookmarks.firstIndex(where: { $0.id == profile.id }) {
                        bookmarks.delete(at: IndexSet(integer: index))
                        PinnedTableStore.shared.removeAll(for: profile.id)
                        ClauseHistoryStore.shared.removeAll(for: profile.id)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("Deleting a server also removes its saved credentials from this device.")
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
            L10n.text("TLS Required (Ask to Trust New CAs)")
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
    @State private var certificateTrustRequest: CertificateTrustRequest?
    @State private var certificateReviewError: String?
    /// Fingerprints already declined in this editor, so a repeated test doesn't ask again.
    @State private var declinedFingerprints: Set<String> = []

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
                            BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
                            Text(profile.resolvedIconName ?? profile.initials)
                                .font(.captionText)
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
                            .font(.captionText).foregroundStyle(.secondary)
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
                            .font(.codeCaption)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        Text("SSH credentials are stored in Keychain on this device. Portbase opens a local loopback forward and verifies the SSH host key after first trust. Password login and unencrypted OpenSSH Ed25519/ECDSA private keys are supported.")
                            .font(.captionText)
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
                            .font(.captionText)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("When caching is off, Portbase always reloads table lists from the database and hides manual refresh controls.")
                            .font(.captionText)
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
                        .font(.captionText)
                        .foregroundStyle(.secondary)
#endif
                }

                }
                Section {
                    Button {
                        runConnectionTest()
                    } label: {
                        HStack(spacing: Spacing.s) {
                            if testTask != nil { ProgressView().controlSize(.small) }
                            else { Image(systemName: "bolt.horizontal.circle") }
                            Text(testTask != nil ? L10n.text("Testing…") : L10n.text("Test Connection"))
                        }
                        .frame(minHeight: Sizes.control)
                    }
                    .disabled(!canSave || testTask != nil)
                    switch testResult {
                    case .success(let success):
                        Label(ConnectionTester.summary(success), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        let message = DatabaseErrorFormatter.message(for: error)
                        ConnectionIssueBanner(message: message,
                                              onReviewCertificate: WorkspaceViewModel.offersCertificateTrust(for: message, profile: profile)
                                                ? { reviewServerCertificate(automatic: false) } : nil)
                            .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.s, bottom: Spacing.s, trailing: Spacing.s))
                        if let certificateReviewError {
                            Label(certificateReviewError, systemImage: "info.circle")
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                        }
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
            .sheet(item: $certificateTrustRequest) { request in
                CertificateTrustSheet(request: request, onTrust: {
                    // The CA joins the unsaved form; saving stores it in the Keychain.
                    profile.privateCACertificate = request.authority.pem
                    profile.transportSecurityMode = .privateCA
                    certificateTrustRequest = nil
                    runConnectionTest()
                }, onCancel: {
                    declinedFingerprints.insert(request.authority.sha256Fingerprint)
                    certificateTrustRequest = nil
                })
#if os(iOS)
                .presentationDetents([.medium, .large])
#endif
                .interactiveDismissDisabled()
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
                if !Task.isCancelled {
                    testResult = .failure(error)
                    // A first connection to a server with its own CA asks to trust it.
                    if WorkspaceViewModel.offersCertificateTrust(for: DatabaseErrorFormatter.message(for: error), profile: candidate) {
                        reviewServerCertificate(automatic: true)
                    }
                }
            }
            testTask = nil
        }
    }

    private func reviewServerCertificate(automatic: Bool) {
        certificateReviewError = nil
        let candidate = profile
        Task {
            do {
                let authority = try await ServerCertificateProbe.authority(for: candidate)
                if automatic, declinedFingerprints.contains(authority.sha256Fingerprint) { return }
                guard let request = CertificateTrustRequest(profile: candidate, authority: authority) else {
                    if !automatic { certificateReviewError = L10n.text("This connection already trusts the server’s certificate authority, so the connection failed for another reason. Check the connection details.") }
                    return
                }
                certificateTrustRequest = request
            } catch {
                certificateReviewError = DatabaseErrorFormatter.message(for: error)
            }
        }
    }

    @ViewBuilder
    private var transportSecurityDetails: some View {
        switch profile.transportSecurityMode {
        case .systemCA:
#if !os(macOS)
            Label("Recommended secure default", systemImage: "checkmark.shield.fill")
                .font(.rowTitle)
                .foregroundStyle(.green)
#endif
            Text("Encrypts the connection and verifies the server certificate using trusted system certificate authorities.")
                .font(.captionText)
                .foregroundStyle(.secondary)
            Text("When a server uses its own certificate authority, as managed databases often do, Portbase shows it on the first connection and asks before trusting it for this connection.")
                .font(.captionText)
                .foregroundStyle(.secondary)

        case .privateCA:
            Text("TLS remains required. The server certificate must chain to this private CA, and the hostname is still verified.")
                .font(.captionText)
                .foregroundStyle(.secondary)

            TextField(
                "Paste PEM certificate",
                text: $profile.privateCACertificate,
                axis: .vertical
            )
            .lineLimit(6...12)
            .font(.codeCaption)
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
                    .font(.captionStrong)
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
            .font(.captionText)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Spacing.s)], spacing: Spacing.s) {
            ForEach(DatabaseEngine.allCases) { engine in
                let selected = selection == engine
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = engine } } label: {
                    VStack(spacing: Spacing.xs) {
                        Image(systemName: engine.symbolName)
                            .font(.tileSymbol)
                            .foregroundStyle(.white)
                            .frame(width: Sizes.avatarLarge, height: Sizes.avatarLarge)
                            .background(LinearGradient(colors: engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        Text(engine.rawValue)
                            .font(.microText.weight(selected ? .bold : .medium))
                            .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(selected ? PortSQLPalette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.rawValue)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

private struct BookmarkIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: ConnectionProfile
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 68, maximum: 92), spacing: Spacing.m)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    HStack(spacing: Spacing.m) {
                        Label("Search", systemImage: "magnifyingglass")
                            .font(.rowTitle)
                            .foregroundStyle(.secondary)
                        TextField("server, chart, folder", text: $searchText)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .stroke(PortSQLPalette.stroke, lineWidth: 1)
                    }

                    LazyVGrid(columns: columns, spacing: Spacing.l) {
                        ForEach(filteredIcons, id: \.self) { iconName in
                            Button {
                                profile.iconName = iconName
                            } label: {
                                VStack(spacing: Spacing.s) {
                                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                        .fill(
                                            iconName == profile.resolvedIconName
                                                ? AnyShapeStyle(profile.engine.gradient)
                                                : AnyShapeStyle(PortSQLPalette.surface)
                                        )
                                        .frame(height: 68)
                                        .overlay {
                                            Image(systemName: iconName)
                                                .font(.pageTitle)
                                                .foregroundStyle(iconName == profile.resolvedIconName ? .white : PortSQLPalette.ink)
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                                .stroke(iconName == profile.resolvedIconName ? Color.clear : PortSQLPalette.stroke, lineWidth: 1)
                                        }

                                    Text(iconName)
                                        .font(.microText)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.l)
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
                        VStack(alignment: .leading, spacing: Spacing.s) {
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
                        .font(.codeCaption)
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
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(binding.wrappedValue.table.displayName)
                                    .font(.cardTitle)
                                Text(editorSubtitle(for: binding.wrappedValue.mode))
                                    .font(.footnoteText)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("Columns") {
                            ForEach(binding.fields) { fieldBinding in
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    HStack(spacing: Spacing.s) {
                                        Text(fieldBinding.wrappedValue.column.name)
                                            .font(.rowTitle)
                                        if fieldBinding.wrappedValue.column.isPrimaryKey {
                                            Text("PK")
                                                .font(.captionStrong)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, Spacing.s)
                                                .padding(.vertical, Spacing.xxs)
                                                .background(PortSQLPalette.accent, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                                        }
                                        Spacer()
                                        Text(L10n.format(
                                            "%@ • %@",
                                            fieldBinding.wrappedValue.column.type,
                                            L10n.text(fieldBinding.wrappedValue.column.isNullable ? "nullable" : "required")
                                        ))
                                            .font(.captionText)
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
                                            .font(.captionText)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.vertical, Spacing.xxs)
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
                .font(.codeText)
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
            .font(.codeText)
            .portbaseKeyboardType(DataEditorValidationService.keyboardType(for: fieldBinding.wrappedValue.column))
        } else {
            Text(fieldBinding.wrappedValue.value.isEmpty ? "\"\"" : fieldBinding.wrappedValue.value)
                .font(.codeText)
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            if isEditable {
                HStack(spacing: Spacing.s) {
                    Label(isValidJSON ? "JSON" : "Invalid JSON", systemImage: isValidJSON ? "curlybraces" : "exclamationmark.triangle.fill")
                        .font(.captionStrong)
                        .foregroundStyle(isValidJSON ? Color.secondary : Color.red)

                    Spacer()

                    Button("Format") {
                        applyJSONFormatting(prettyPrinted: true)
                    }
                    .font(.captionStrong)
                    .disabled(!canFormatJSON)

                    Button("Minify") {
                        applyJSONFormatting(prettyPrinted: false)
                    }
                    .font(.captionStrong)
                    .disabled(!canFormatJSON)
                }

                ZStack(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(placeholder)
                            .font(.codeText)
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.s)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $value)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.codeText)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xxs)
                }
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(isValidJSON ? PortSQLPalette.editorBorder(for: colorScheme) : Color.red.opacity(0.55), lineWidth: 1)
                }
            } else {
                ScrollView {
                    Text(value.isEmpty ? "NULL" : value)
                        .font(.codeText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 180)
                .padding(Spacing.m)
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
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
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(PortSQLPalette.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnoteText)
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
        .padding(Spacing.card)
        .portbaseCardSurface()
    }
}

struct LoadingStateView: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            ProgressView()
                .controlSize(.regular)
                .tint(PortSQLPalette.accent)
                .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                .background(PortSQLPalette.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.rowTitle)
                    .foregroundStyle(PortSQLPalette.ink)
                Text(message)
                    .font(.captionText)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
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
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.tileSymbol)
                .foregroundStyle(tint)
                .padding(.top, Spacing.xxxs)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.rowTitle)
                    .foregroundStyle(titleColor)
                Text(message)
                    .font(.captionText)
                    .foregroundStyle(messageColor)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .background((backgroundColor ?? tint.opacity(0.10)), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Radius.card, bottomLeadingRadius: Radius.card, style: .continuous)
                .fill(tint)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Text(item.title)
                                    .font(.codeCaption)
                                    .foregroundStyle(PortSQLPalette.ink)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.captionText)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
                            // A compact tag that still keeps a full-size touch target.
                            .frame(minHeight: Sizes.control)
                            .contentShape(Rectangle())
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
