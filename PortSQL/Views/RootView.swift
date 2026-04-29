import Charts
import SwiftUI

enum PortSQLPalette {
    static let accent = Color(red: 0.05, green: 0.42, blue: 0.82)
    static let accentSoft = Color(uiColor: .secondarySystemBackground)
    static let ink = Color(uiColor: .label)
    static let panel = Color(uiColor: .secondarySystemBackground).opacity(0.92)
    static let surface = Color(uiColor: .systemBackground).opacity(0.94)
    static let tertiarySurface = Color(uiColor: .tertiarySystemBackground).opacity(0.96)
    static let stroke = Color(uiColor: .separator).opacity(0.45)
    static let canvasTop = Color(uiColor: .systemGroupedBackground)
    static let canvasAccent = Color(uiColor: .secondarySystemGroupedBackground)
    static let shadow = Color.black.opacity(0.16)

    static func editorBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.10, green: 0.12, blue: 0.16) : Color(uiColor: .systemBackground)
    }

    static func editorBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : stroke
    }

    static func editorPlaceholder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.42) : Color.black.opacity(0.34)
    }
}

struct RootView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var selectedTab = RootTab.launchSelection

    private var hasConnectionProblem: Bool {
        workspace.selectedBookmark != nil
            && (workspace.errorMessage != nil || workspace.schemaErrorMessage != nil)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ExplorerView()
            }
            .tag(RootTab.explorer)
            .tabItem {
                Label("Explorer", systemImage: "square.stack.3d.up.fill")
            }

            NavigationStack {
                WorkbenchView()
            }
            .tag(RootTab.studio)
            .tabItem {
                Label("Studio", systemImage: "terminal.fill")
            }

            NavigationStack {
                VisualizerView()
            }
            .tag(RootTab.charts)
            .tabItem {
                Label("Charts", systemImage: "chart.bar.xaxis")
            }

            NavigationStack {
                BookmarksView()
            }
            .tag(RootTab.servers)
            .tabItem {
                Label("Servers", systemImage: "server.rack")
            }
            .badge(hasConnectionProblem ? "!" : nil)
        }
        .tint(PortSQLPalette.accent)
        .sheet(item: $workspace.dataEditorDraft) { _ in
            DataEditorSheet()
        }
    }
}

private enum RootTab: Hashable {
    case explorer
    case studio
    case charts
    case servers

    static var launchSelection: RootTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-portsql-tab"),
              arguments.indices.contains(index + 1) else {
            return .explorer
        }

        switch arguments[index + 1].lowercased() {
        case "studio":
            return .studio
        case "charts":
            return .charts
        case "servers":
            return .servers
        default:
            return .explorer
        }
    }
}

private struct WorkbenchView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if bookmarks.bookmarks.isEmpty {
                        HeroHeader()
                    }
                    QueryEditorCard()
                    ResultsCard()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
                .frame(width: proxy.size.width, alignment: .topLeading)
            }
        }
        .background(WorkbenchBackground().ignoresSafeArea())
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionSwitcherButton(toolbarMode: true)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                SchemaRefreshButton()
                DatabaseSwitcherButton()
            }
        }
        .sheet(item: $workspace.selectedProfileForEdit) { profile in
            BookmarkEditorView(profile: profile)
        }
        .onChange(of: workspace.queryText) { _, _ in
            workspace.refreshAssist()
        }
        .onChange(of: workspace.queryCursorOffset) { _, _ in
            workspace.refreshAssist()
        }
    }
}

private struct HeroHeader: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PORTSQL")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.78))

            Text("Elegant database control, sized for iPhone.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Live MySQL and PostgreSQL querying, schema browsing, charting, and row editing without placeholder datasets.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))

            if let bookmark = workspace.selectedBookmark {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.name.isEmpty ? bookmark.host : bookmark.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(bookmark.engine.rawValue) • \(bookmark.host):\(String(bookmark.port))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                } icon: {
                    BookmarkAvatar(profile: bookmark, foregroundStyle: .white)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                StatusBanner(
                    title: "No active connection",
                    message: "Create or select a bookmark to start a live workspace.",
                    tint: .white,
                    titleColor: .white,
                    messageColor: .white.opacity(0.82),
                    backgroundColor: Color.white.opacity(0.14)
                )
            }

            if bookmarks.bookmarks.isEmpty {
                Button {
                    workspace.createBookmark()
                } label: {
                    Label("New Connection", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleButtonStyle())
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.11, blue: 0.22),
                            PortSQLPalette.accent,
                            Color(red: 0.16, green: 0.62, blue: 0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
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
                        .frame(width: toolbarMode ? 28 : 40, height: toolbarMode ? 28 : 40)
                        .background(toolbarMode ? Color.clear : Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
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
                                        Text("\(bookmark.engine.rawValue) • \(bookmark.host):\(String(bookmark.port))")
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
                }
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
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(workspace.isLoadingSchema ? .secondary : PortSQLPalette.accent)
            .disabled(workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.isLoadingSchema)
            .accessibilityLabel("Refresh cached table list")
        }
    }
}

private struct QueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingExpandedEditor = false
    @State private var isShowingLibrarySheet = false

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    SectionHeader(title: "Query", subtitle: querySubtitle)
                    Spacer(minLength: 12)
                    Button {
                        isShowingLibrarySheet = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(PortSQLPalette.ink)
                            .frame(width: 36, height: 36)
                            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open query library")
                }

                if bookmarks.bookmarks.isEmpty {
                    connectionSection
                }
                editorSection
                if !bookmarks.bookmarks.isEmpty {
                    runButton
                }
                actionSection
                if !workspace.suggestions.isEmpty {
                    suggestionSection
                }

                feedbackSection
            }
        }
        .fullScreenCover(isPresented: $isShowingExpandedEditor) {
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
            Label("Add Connection", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionButtonStyle())
    }

    private var actionSection: some View {
        HStack(spacing: 8) {
            actionButton("FORMAT", systemImage: "text.alignleft", disabled: trimmedQuery.isEmpty) {
                workspace.formatQuery()
            }
            actionButton("EXPLAIN", systemImage: "waveform.path.ecg", disabled: workspace.selectedBookmark == nil || trimmedQuery.isEmpty) {
                workspace.runExplain()
            }
            actionButton("SAVE", systemImage: "bookmark", disabled: trimmedQuery.isEmpty) {
                workspace.saveSnippet()
            }
            if workspace.isSchemaCachingEnabled {
                actionButton("SCHEMA", systemImage: "arrow.clockwise", disabled: workspace.activeDatabaseName == nil || workspace.isLoadingSchema) {
                    workspace.refreshSchemaCatalog()
                }
            }
        }
    }

    private var editorSection: some View {
        ZStack(alignment: .topLeading) {
            HighlightedQueryEditor(
                text: $workspace.queryText,
                cursorOffset: $workspace.queryCursorOffset,
                colorScheme: colorScheme
            )
                .frame(minHeight: 220)

            if workspace.queryText.isEmpty {
                Text("SELECT customerName, country\nFROM customers\nORDER BY customerName\nLIMIT 25;")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                isShowingExpandedEditor = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.9) : PortSQLPalette.ink)
                    .frame(width: 34, height: 34)
                    .background((colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(12)
            .accessibilityLabel("Open full screen SQL editor")
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(editorBackgroundColor)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(editorBorderColor, lineWidth: 1)
        }
    }

    private var suggestionSection: some View {
        InlineSuggestionMenu(
            suggestions: visibleSuggestions.map { InlineSuggestionItem(title: $0, subtitle: completionSubtitle(for: $0)) },
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

    private func completionSubtitle(for suggestion: String) -> String {
        let uppercase = suggestion.uppercased()
        if ["SELECT", "FROM", "WHERE", "ORDER BY", "GROUP BY", "LIMIT", "JOIN"].contains(uppercase) {
            return "SQL keyword"
        }
        if suggestion.contains(".") {
            return "Schema reference"
        }
        return "Contextual completion"
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if workspace.selectedBookmark == nil {
            StatusBanner(
                title: "Connection required",
                message: "Select a bookmark before running queries or refreshing schema metadata.",
                tint: .orange
            )
        }

        if let schemaErrorMessage = workspace.schemaErrorMessage {
            StatusBanner(
                title: "Schema refresh failed",
                message: schemaErrorMessage,
                tint: .orange
            )
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
            return "Pick a server bookmark to run live queries."
        }

        let serverName = bookmark.name.isEmpty ? bookmark.host : bookmark.name
        if let database = workspace.activeDatabaseName {
            return "\(serverName) • \(database)"
        }
        return "\(serverName) • select a database in the top bar"
    }

    private var runButton: some View {
        Button {
            workspace.runQuery()
        } label: {
            if workspace.isRunning {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
            } else {
                Label("Run Query", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(PrimaryActionButtonStyle())
        .disabled(workspace.isRunning || workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || trimmedQuery.isEmpty)
    }

    private func actionButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(StudioActionTileButtonStyle())
        .disabled(disabled)
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
                        colorScheme: colorScheme
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if workspace.queryText.isEmpty {
                        Text("SELECT customerName, country\nFROM customers\nORDER BY customerName\nLIMIT 25;")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(PortSQLPalette.editorBackground(for: colorScheme))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                }
                .padding(16)
            }
            .navigationTitle("SQL Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        workspace.runQuery()
                    } label: {
                        if workspace.isRunning {
                            ProgressView()
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .disabled(workspace.isRunning || workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    private let compactColumnWidth: CGFloat = 104
    private let minimumColumnWidth: CGFloat = 52
    private let maximumColumnWidth: CGFloat = 208
    private let pagerControlHeight: CGFloat = 34

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Results")
                            .font(.headline.weight(.bold))
                        if let resultsMetadataSubtitle {
                            Text(resultsMetadataSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        if canCreateVisualization {
                            visualizerButton
                        }
                        if workspace.selectedExplorerTable != nil {
                            schemaButton
                        }
                    }
                }

                if let errorMessage = workspace.errorMessage {
                    StatusBanner(
                        title: "Execution failed",
                        message: errorMessage,
                        tint: .red
                    )
                }

                if let sql = workspace.result.generatedMutation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Generated mutation")
                            .font(.subheadline.weight(.semibold))
                        Text(sql)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                if !workspace.isRunning && (workspace.canInsertIntoCurrentTable || workspace.canEditCurrentRows) {
                    HStack(spacing: 10) {
                        Text(rowInteractionLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if workspace.canInsertIntoCurrentTable {
                            Button {
                                workspace.prepareInsert()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PortSQLPalette.ink)
                            .background(controlBackground, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
                            }
                            .accessibilityLabel("Insert row")
                        }
                    }
                }

                if !workspace.isRunning && workspace.isShowingExplorerResult {
                    HStack(spacing: 8) {
                        Button {
                            workspace.goToPreviousExplorerPage()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 42, height: pagerControlHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(!workspace.canGoToPreviousExplorerPage ? Color.secondary.opacity(0.45) : PortSQLPalette.ink)
                        .background(controlBackground, in: Capsule())
                        .disabled(!workspace.canGoToPreviousExplorerPage)

                        Spacer(minLength: 0)

                        pageStatusMenu

                        Spacer(minLength: 0)

                        Button {
                            workspace.goToNextExplorerPage()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 42, height: pagerControlHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(!workspace.canGoToNextExplorerPage ? Color.secondary.opacity(0.45) : PortSQLPalette.ink)
                        .background(controlBackground, in: Capsule())
                        .disabled(!workspace.canGoToNextExplorerPage)
                    }
                }

                if workspace.isRunning {
                    LoadingStateView(
                        title: "Loading results",
                        message: "Fetching rows for the current request."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else if workspace.result.columns.isEmpty {
                    ContentUnavailableView(
                        "No live rows yet",
                        systemImage: "tablecells",
                        description: Text("Run a query against a configured database to inspect rows and edit returned records.")
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 0) {
                                ForEach(Array(workspace.result.columns.enumerated()), id: \.element.id) { index, column in
                                    resultHeader(column, width: columnWidth(for: column, at: index))
                                }
                            }
                            .padding(.horizontal, 8)

                            ForEach(workspace.result.rows) { row in
                                Button {
                                    workspace.prepareEdit(row: row)
                                } label: {
                                    HStack(spacing: 0) {
                                        ForEach(Array(workspace.result.columns.enumerated()), id: \.offset) { index, column in
                                            resultCell(
                                                value: row.values.indices.contains(index) ? row.values[index] : "",
                                                column: column,
                                                width: columnWidth(for: column, at: index)
                                            )
                                        }
                                    }
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .alert(item: $pendingSchemaColumnDeletion) { target in
            Alert(
                title: Text("Delete Column"),
                message: Text("Delete `\(target.column.name)` from `\(target.table.name)`? This will alter the live schema."),
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

    private var pageStatusMenu: some View {
        Menu {
            ForEach([10, 25, 50, 100], id: \.self) { size in
                Button {
                    workspace.setExplorerPageSize(size)
                } label: {
                    Label(
                        "\(size) rows",
                        systemImage: workspace.explorerPageSize == size ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
            }
            Button {
                workspace.setExplorerPageSize(0)
            } label: {
                Label(
                    "No limits",
                    systemImage: workspace.isExplorerUnlimited ? "checkmark.circle.fill" : "infinity.circle"
                )
            }
        } label: {
            VStack(spacing: 1) {
                Text(workspace.isExplorerUnlimited ? "All Rows" : workspace.explorerPageLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PortSQLPalette.ink)
                Text(workspace.explorerResultRangeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 116, minHeight: 42)
            .padding(.horizontal, 12)
                .background(controlBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var schemaButton: some View {
        Button {
            isShowingSchemaSheet = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PortSQLPalette.ink)
                .frame(width: 34, height: pagerControlHeight)
                .background(controlBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show schema")
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
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PortSQLPalette.ink)
                .frame(width: 34, height: pagerControlHeight)
                .background(controlBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to visualizer")
    }

    private var resultsMetadataSubtitle: String? {
        guard workspace.isShowingExplorerResult,
              let selectedTable = workspace.selectedExplorerTable else {
            return nil
        }

        var parts = ["\(selectedTable.columns.count) cols"]
        if let rowCountEstimate = selectedTable.rowCountEstimate {
            parts.append("\(rowCountEstimate) rows")
        }
        return parts.joined(separator: " • ")
    }

    private var canCreateVisualization: Bool {
        !workspace.result.columns.isEmpty
            && VisualizationService.fieldDescriptors(for: workspace.result).contains(where: \.supportsNumeric)
    }

    private var rowInteractionLabel: String {
        workspace.canEditCurrentRows ? "Tap a row to view or edit" : "Tap a row to view"
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
                                    .frame(width: 28, height: 28)
                                    .background(Color.secondary.opacity(0.08), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingSchemaColumnDeletion = SchemaColumnDeletionTarget(table: selectedTable, column: column)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle(selectedTable.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                schemaColumnDraft = .add(to: selectedTable)
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
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

    @ViewBuilder
    private func resultHeader(_ column: QueryColumn, width: CGFloat) -> some View {
        let isSorted = workspace.isShowingExplorerResult
            && workspace.explorerSortColumn.map { $0.caseInsensitiveCompare(column.name) == .orderedSame } == true
        let direction = workspace.explorerSortDirection ?? "ASC"
        let isPrimaryKeyColumn = isPrimaryKeyResultColumn(column)

        Button {
            if workspace.isShowingExplorerResult {
                workspace.sortExplorer(by: column.name)
            }
        } label: {
            HStack(spacing: 4) {
                if isPrimaryKeyColumn {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PortSQLPalette.accent)
                }
                Text(column.name)
                    .underline(isPrimaryKeyColumn, color: PortSQLPalette.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isSorted {
                    Image(systemName: direction == "DESC" ? "arrow.down" : "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .bold, design: .default))
            .foregroundStyle(isSorted ? PortSQLPalette.accent : .secondary)
            .frame(maxWidth: .infinity, alignment: columnAlignment(for: column))
            .frame(width: width, alignment: columnAlignment(for: column))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!workspace.isShowingExplorerResult)
    }

    private func resultCell(value: String, column: QueryColumn, width: CGFloat) -> some View {
        Text(value.isEmpty ? "NULL" : value)
            .foregroundStyle(value.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: columnAlignment(for: column))
            .frame(width: width, alignment: columnAlignment(for: column))
    }

    private func columnWidth(for column: QueryColumn, at index: Int) -> CGFloat {
        let headerWidth = measuredWidth(
            for: column.name,
            font: .preferredFont(forTextStyle: .caption1)
        )
        let headerAccessoryWidth: CGFloat = isPrimaryKeyResultColumn(column) ? 14 : 0
        let sampleWidths = workspace.result.rows
            .prefix(40)
            .map { row in
                let value = row.values.indices.contains(index) ? row.values[index] : ""
                return measuredWidth(
                    for: value.isEmpty ? "NULL" : value,
                    font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
                )
            }

        let contentWidth = max(headerWidth + headerAccessoryWidth, sampleWidths.max() ?? 0)
        let paddedWidth = contentWidth + 24
        return min(max(paddedWidth, minimumColumnWidth), maximumColumnWidth)
    }

    private func measuredWidth(for text: String, font: UIFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func columnAlignment(for column: QueryColumn) -> Alignment {
        isNumericColumn(column) ? .trailing : .leading
    }

    private func isNumericColumn(_ column: QueryColumn) -> Bool {
        let type = column.type.lowercased()
        let numericMarkers = ["int", "decimal", "numeric", "float", "double", "real", "number", "serial", "bit"]
        return numericMarkers.contains { type.contains($0) }
    }

    private func isPrimaryKeyResultColumn(_ column: QueryColumn) -> Bool {
        guard workspace.isShowingExplorerResult,
              let selectedTable = workspace.selectedExplorerTable else {
            return false
        }

        return selectedTable.primaryKeyColumns.contains {
            $0.name.caseInsensitiveCompare(column.name) == .orderedSame
        }
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
                            Text("Editing `\(originalName)`")
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
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Column type", text: $draft.type)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Nullable", isOn: $draft.isNullable)
                }

                Section {
                    Text("Examples: `VARCHAR(255)`, `INT`, `TIMESTAMP`, `DECIMAL(10,2)`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.mode.confirmationTitle) {
                        Task {
                            await save()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
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

private struct BookmarksView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        List {
            Section("Servers") {
                if bookmarks.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No servers saved",
                        systemImage: "server.rack",
                        description: Text("Create your first MySQL or PostgreSQL server to start querying live data.")
                    )
                } else {
                    ForEach(bookmarks.bookmarks) { bookmark in
                        HStack(spacing: 14) {
                            BookmarkAvatar(profile: bookmark, size: 44, cornerRadius: 14)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(bookmark.name.isEmpty ? bookmark.host : bookmark.name)
                                Text("\(bookmark.engine.rawValue) • \(bookmark.host):\(String(bookmark.port))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(bookmark.schemaCachingEnabled ? "Caching table lists for \(bookmark.schemaCacheDurationLabel)" : "Table list caching off")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Edit") {
                                workspace.selectedProfileForEdit = bookmark
                            }
                            .buttonStyle(SecondaryActionButtonStyle())
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            workspace.selectBookmark(bookmark.id)
                        }
                    }
                    .onDelete(perform: bookmarks.delete)
                }
            }

            Section("Sync") {
                Label("Servers are mirrored through iCloud key-value sync.", systemImage: "icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            Button {
                workspace.createBookmark()
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(item: $workspace.selectedProfileForEdit) { profile in
            BookmarkEditorView(profile: profile)
        }
    }
}

private struct BookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State var profile: ConnectionProfile
    @State private var isShowingIconPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $profile.name)
                    Picker("Engine", selection: $profile.engine) {
                        ForEach(DatabaseEngine.allCases) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .onChange(of: profile.engine) { oldValue, engine in
                        profile.port = engine.defaultPort
                        if profile.iconName == BookmarkIconCatalog.defaultName(for: oldValue) {
                            profile.iconName = nil
                        }
                    }
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
                    TextField("Host", text: $profile.host)
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: Binding(
                        get: { String(profile.port) },
                        set: { input in
                            let digits = input.filter(\.isNumber)
                            profile.port = Int(digits) ?? 0
                        }
                    ))
                        .keyboardType(.numberPad)
                    TextField("Default Database", text: $profile.defaultDatabase)
                    Toggle("Use TLS", isOn: $profile.usesTLS)
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
                        Text("When caching is off, PortSQL always reloads table lists from the database and hides manual refresh controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $profile.username)
                    SecureField("Password", text: $profile.password)
                }

                Section("Notes") {
                    TextField("Notes", text: $profile.notes, axis: .vertical)
                }
            }
            .navigationTitle("Bookmark")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        workspace.saveBookmark(profile)
                        dismiss()
                    }
                    .disabled(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $isShowingIconPicker) {
                BookmarkIconPicker(profile: $profile)
            }
        }
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
                            .textInputAutocapitalization(.never)
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
            .navigationBarTitleDisplayMode(.inline)
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

private struct DataEditorSheet: View {
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
                                        Text(fieldBinding.wrappedValue.column.type + (fieldBinding.wrappedValue.column.isNullable ? " • nullable" : " • required"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    fieldValueEditor(fieldBinding)

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        workspace.dismissDataEditor()
                        dismiss()
                    }
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
        .onChange(of: workspace.dataEditorDraft == nil) { _, isNil in
            if isNil {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func fieldValueEditor(_ fieldBinding: Binding<DataEditorField>) -> some View {
        if DataEditorValidationService.isJSONColumn(fieldBinding.wrappedValue.column) {
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
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .keyboardType(DataEditorValidationService.keyboardType(for: fieldBinding.wrappedValue.column))
        } else {
            Text(fieldBinding.wrappedValue.value.isEmpty ? "NULL" : fieldBinding.wrappedValue.value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func editorSubtitle(for mode: DataEditorMode) -> String {
        switch mode {
        case .view:
            return "Inspect the selected row. This result isn’t currently writable, so fields are shown read-only."
        case .insert:
            return "Insert a new row with schema-aware validation."
        case .update:
            return "Update the selected row and write the mutation back to the database."
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
                        .textInputAutocapitalization(.never)
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
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(PortSQLPalette.stroke, lineWidth: 1)
        }
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
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PortSQLPalette.stroke, lineWidth: 1)
        }
    }
}

private struct BookmarkAvatar: View {
    let profile: ConnectionProfile
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 8
    var foregroundStyle: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(profile.engine.gradient)
            .frame(width: size, height: size)
            .overlay {
                if let iconName = profile.resolvedIconName {
                    Image(systemName: iconName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(foregroundStyle)
                } else {
                    Text(profile.initials)
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(foregroundStyle)
                        .minimumScaleFactor(0.6)
                }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(titleColor)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background((backgroundColor ?? tint.opacity(0.08)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, item in
                Button {
                    onSelect(item)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: item.subtitle == nil ? 0 : 3) {
                            Text(item.title)
                                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                .foregroundStyle(PortSQLPalette.ink)
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "return")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if index < suggestions.count - 1 {
                    Divider()
                        .overlay(PortSQLPalette.stroke)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PortSQLPalette.stroke, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchBackground: View {
    var body: some View {
        LinearGradient(
            colors: [PortSQLPalette.canvasTop, PortSQLPalette.canvasAccent],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [PortSQLPalette.accent, Color.cyan.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(PortSQLPalette.surface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PortSQLPalette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct TagButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? .white : PortSQLPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(isSelected ? PortSQLPalette.accent : PortSQLPalette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(isSelected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct StudioActionTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PortSQLPalette.ink)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PortSQLPalette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
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

private extension Binding where Value == QueryRow {
    var values: [Binding<String>] {
        wrappedValue.values.indices.map { index in
            Binding<String>(
                get: { wrappedValue.values[index] },
                set: { wrappedValue.values[index] = $0 }
            )
        }
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
