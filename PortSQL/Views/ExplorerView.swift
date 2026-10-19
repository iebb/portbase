import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ExplorerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var clauseEditorHeight: CGFloat = 32
    @State private var focusedClause: ClauseField?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Where there's room, the table, its clauses, and the run button share one row, and the rows
    /// below take the rest of the screen.
    private var isWide: Bool { horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize }
    /// Phones lay the panels out edge to edge, without cards inside the page's padding.
    private var isFlat: Bool { horizontalSizeClass == .compact }

    private var runButton: some View {
        Button {
            focusedClause = nil
            workspace.restartBrowse()
        } label: {
            Image(systemName: "play.fill")
                .font(.rowTitle)
                .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(PortSQLPalette.accent, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .disabled(workspace.selectedExplorerTable == nil || workspace.isRunning)
        .accessibilityLabel("Run table browse query")
        .accessibilityHint("Applies the current WHERE and ORDER BY clauses")
    }

    private func whereRow(_ table: SchemaTableDescriptor) -> some View {
        clauseRow(field: .whereClause, title: "WHERE", text: $workspace.explorerWhereClause, placeholder: L10n.text("Filter"),
                  suggestions: whereSuggestions(for: table), apply: applyWhereSuggestion)
            .frame(maxWidth: .infinity)
    }

    private func orderRow(_ table: SchemaTableDescriptor) -> some View {
        clauseRow(field: .orderByClause, title: "ORDER", text: $workspace.explorerOrderByClause, placeholder: L10n.text("Sort"),
                  suggestions: orderBySuggestions(for: table), apply: applyOrderSuggestion)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: isFlat ? 0 : Spacing.l) {
                    // Browsing needs a connection; without one, only the empty state below is shown.
                    if workspace.selectedBookmark != nil, isWide, let selectedTable = workspace.selectedExplorerTable {
                        HStack(alignment: .top, spacing: Spacing.s) {
                            tableMenu.frame(maxWidth: 260)
                            whereRow(selectedTable)
                            orderRow(selectedTable)
                            runButton
                        }
                    } else if workspace.selectedBookmark != nil {
                        PanelCard {
                            VStack(alignment: .leading, spacing: Spacing.m) {
                                // One row: the table and the run button (selecting a table browses it; run re-applies the clauses).
                                HStack(alignment: .center, spacing: Spacing.s) {
                                    tableMenu
                                    runButton
                                }

                                if let selectedTable = workspace.selectedExplorerTable {

                                    HStack(spacing: Spacing.xs) {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: Spacing.xs) {
                                                // Column count and editability already show above the results.
                                                if let estimate = selectedTable.rowCountEstimate {
                                                    PortbaseChip(title: L10n.plural("row_count", count: estimate), systemImage: "list.number", tint: PortSQLPalette.accent)
                                                }
                                                if !selectedTable.primaryKeyColumns.isEmpty {
                                                    PortbaseChip(title: selectedTable.primaryKeyColumns.map(\.name).joined(separator: ", "), systemImage: "key.fill", tint: .orange)
                                                }
                                            }
                                        }
                                        // On phones the connection's badges share this row rather than taking one of their own.
                                        if isFlat, let profile = workspace.selectedBookmark, ConnectionStatusBadges.hasBadges(profile) {
                                            ConnectionStatusBadges(profile: profile).fixedSize()
                                        }
                                    }

                                    // Side by side where there's room, as on the Mac; stacked on phones.
                                    let clauses = horizontalSizeClass == .regular
                                        ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.s))
                                        : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
                                    clauses {
                                        whereRow(selectedTable)
                                        orderRow(selectedTable)
                                    }
                                } else {
                                    HStack(spacing: Spacing.s) {
                                        Image(systemName: "tablecells")
                                            .font(.rowTitle)
                                            .foregroundStyle(.secondary)
                                        Text("Choose a table to browse and filter rows.")
                                            .font(.rowDetail)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, Spacing.m)
                                    .padding(.vertical, Spacing.s)
                                    .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                            .stroke(PortSQLPalette.stroke, lineWidth: 1)
                                    }
                                }

                            }
                        }
                    }

                    if workspace.isLoadingSchema {
                        PanelCard {
                            LoadingStateView(
                                title: L10n.text("Loading database"),
                                message: loadingDatabaseMessage
                            )
                        }
                    } else if let schemaErrorMessage = workspace.schemaErrorMessage {
                        ConnectionIssueBanner(message: schemaErrorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                    } else if filteredTables.isEmpty {
                        Group {
                            if workspace.selectedBookmark == nil {
                                PortbaseEmptyState(
                                    title: L10n.text("Add a database connection"),
                                    message: L10n.text("Add a connection to browse tables, run queries, and build charts."),
                                    systemImage: "server.rack",
                                    actionTitle: L10n.text("Add Connection"),
                                    action: { workspace.createBookmark() }
                                )
                            } else {
                                PortbaseEmptyState(
                                    title: L10n.text("No schema metadata"),
                                    message: L10n.text("Choose a database or refresh the schema."),
                                    systemImage: "square.stack.3d.up.slash",
                                    actionTitle: L10n.text("Refresh Tables"),
                                    action: { workspace.refreshSchemaCatalog() }
                                )
                            }
                        }
                        .portbaseCardSurface()
                    } else {
                        ResultsCard()
                            .frame(maxHeight: isWide ? .infinity : nil, alignment: .top)
                    }
                }
                .environment(\.workspaceFillsHeight, isWide)
                .environment(\.workspaceIsFlat, isFlat)
                .padding(isFlat ? 0 : Spacing.l)
                .frame(width: proxy.size.width,
                       height: isWide ? max(proxy.size.height, WorkspaceLayout.minimumFillHeight) : nil,
                       alignment: .topLeading)
            }
            // A page-wide tap gesture to dismiss the clause keyboard cancelled taps on the result grid,
            // so cells couldn't be selected or edited. Scrolling, or selecting a cell, dismisses it instead.
            .scrollDismissesKeyboard(.interactively)
        }
        .background(WorkbenchBackground().ignoresSafeArea())
        .navigationTitle("Explorer")
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
    }

    private var filteredTables: [SchemaTableDescriptor] {
        workspace.schemaCatalog
    }

    private func tableSummary(_ table: SchemaTableDescriptor) -> String {
        let columnSummary = L10n.plural("column_count", count: table.columns.count)
        guard let rowCountEstimate = table.rowCountEstimate else { return columnSummary }
        return L10n.format("%@ • approximately %@", columnSummary, L10n.plural("row_count", count: rowCountEstimate))
    }


    @ViewBuilder
    private var tableMenu: some View {
        Menu {
            ForEach(filteredTables) { table in
                Button {
                    focusedClause = nil
                    workspace.selectExplorerTable(table)
                } label: {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Image(systemName: workspace.selectedExplorerTableID == table.id ? "checkmark.circle.fill" : "tablecells")
                            .font(.footnoteText.weight(.bold))
                            .foregroundStyle(workspace.selectedExplorerTableID == table.id ? PortSQLPalette.accent : .secondary)

                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(table.name)
                                .font(.rowTitle)
                            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                Text(tableSummary(table))
                                    .font(.microText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "tablecells").foregroundStyle(PortSQLPalette.muted)
                Text(workspace.selectedExplorerTable?.name ?? L10n.text("Choose a table"))
                    .font(.rowTitle)
                    .foregroundStyle(PortSQLPalette.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnoteText.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.touchTarget)
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: Sizes.touchTarget)
        .accessibilityLabel(workspace.selectedExplorerTable.map { L10n.format("Choose table, currently %@", $0.name) } ?? L10n.text("Choose a table"))

    }

    private func clauseRow(
        field: ClauseField,
        title: String,
        text: Binding<String>,
        placeholder: String,
        suggestions: [SQLClauseSuggestion],
        apply: @escaping (SQLClauseSuggestion) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            let fieldLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
                : AnyLayout(HStackLayout(spacing: Spacing.s))

            fieldLayout {
                Text(title)
                    .font(.captionStrong)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .allowsTightening(true)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 44, alignment: .leading)

                ZStack(alignment: .leading) {
                    HighlightedClauseEditor(
                        text: text,
                        colorScheme: colorScheme,
                        accessibilityLabel: L10n.format("%@ SQL clause", title)
                    ) { isFocused in
                        if isFocused {
                            focusedClause = field
                        } else if focusedClause == field {
                            focusedClause = nil
                        }
                    }
                    .frame(height: min(max(clauseEditorHeight, 32), 72))

                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.codeText)
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, Spacing.xxxs)
                            .allowsHitTesting(false)
                    }
                }
                ClauseHistoryMenu(kind: field == .whereClause ? .filter : .sort, text: text)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(focusedClause == field ? PortSQLPalette.accent.opacity(0.45) : PortSQLPalette.stroke, lineWidth: 1)
            }

            if focusedClause == field && !suggestions.isEmpty {
                InlineSuggestionMenu(
                    suggestions: Array(suggestions.prefix(8)).map {
                        InlineSuggestionItem(title: $0.label, subtitle: $0.detail, symbol: $0.kind.symbol, tint: $0.kind.tint)
                    },
                    onSelect: { item in
                        if let match = suggestions.first(where: { $0.label == item.title && $0.detail == item.subtitle }) {
                            apply(match)
                        }
                    }
                )
            }
        }
    }

    private var loadingDatabaseMessage: String {
        if let database = workspace.activeDatabaseName {
            return L10n.format("Reading tables and columns from %@.", database)
        }
        return L10n.text("Reading tables and columns from the selected database.")
    }

    private func whereSuggestions(for table: SchemaTableDescriptor) -> [SQLClauseSuggestion] {
        clauseSuggestions(workspace.explorerWhereClause, kind: .filter, table: table)
    }

    private func orderBySuggestions(for table: SchemaTableDescriptor) -> [SQLClauseSuggestion] {
        clauseSuggestions(workspace.explorerOrderByClause, kind: .sort, table: table)
    }

    /// Completions for a clause field from the same engine as the console, as if the field's text
    /// followed SELECT * FROM the table.
    private func clauseSuggestions(_ text: String, kind: SQLCompletionEngine.ClauseKind, table: SchemaTableDescriptor) -> [SQLClauseSuggestion] {
        SQLCompletionEngine.clauseSuggestions(text, kind: kind, table: table, catalog: workspace.schemaCatalog,
                                              activeDatabase: workspace.activeDatabaseName,
                                              engine: workspace.selectedBookmark?.engine ?? .postgresql, limit: 8)
    }

    private func applyWhereSuggestion(_ suggestion: SQLClauseSuggestion) {
        workspace.explorerWhereClause = suggestion.completedText
        focusedClause = .whereClause
    }

    private func applyOrderSuggestion(_ suggestion: SQLClauseSuggestion) {
        workspace.explorerOrderByClause = suggestion.completedText
        focusedClause = .orderByClause
    }

    private func explorerTag(_ text: String) -> some View {
        Text(text)
            .font(.badgeText)
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xxs)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
    }

    private enum ClauseField {
        case whereClause
        case orderByClause
    }

}

/// Query history and saved queries on one continuous surface, in the style of Termius's lists: a title
/// with a close button, underline tabs with counts, one search-and-filter row, flat rows grouped by day,
/// and a quiet footer. Loading a query never runs it.
struct LibrarySheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.connectionSessionOpener) private var sessionOpener
    /// Shown as a page rather than a sheet: no close button, and opening a query calls this instead.
    var onOpened: (() -> Void)? = nil
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @State private var selection: LibrarySection = .history
    @State private var search = ""
    @State private var outcome: QueryHistoryOutcome?
    @State private var currentConnectionOnly = false
    @State private var editing: SavedQuerySnippet?
    @State private var contextError: String?
    @State private var showsStorage = false
    @FocusState private var searchFocused: Bool

    private var history: [QueryHistoryEntry] {
        library.history.filter { entry in
            (!currentConnectionOnly || entry.bookmarkID == workspace.selectedBookmark?.id)
                && (outcome == nil || (entry.outcome ?? .succeeded) == outcome)
                && matches([entry.title, entry.sql, entry.connectionName, entry.database ?? "", entry.summary])
        }
    }
    private var snippets: [SavedQuerySnippet] {
        library.snippets.filter { snippet in
            (!currentConnectionOnly || snippet.bookmarkID == workspace.selectedBookmark?.id)
                && matches([snippet.title, snippet.sql, snippet.note, snippet.database ?? ""])
        }
    }
    private func matches(_ fields: [String]) -> Bool {
        search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
    }
    /// History grouped by calendar day, newest first, as Termius groups its history.
    private var historyDays: [(day: Date, entries: [QueryHistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: history) { calendar.startOfDay(for: $0.executedAt) }
        return groups.keys.sorted(by: >).map { day in (day, groups[day]!.sorted { $0.executedAt > $1.executedAt }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsStorage { storage } else { libraryPage }
        }
        .background(PortSQLPalette.canvasTop.ignoresSafeArea())
        .sheet(item: $editing) { snippet in SavedQueryDetailsSheet(snippet: snippet) }
    }

    // MARK: Library

    private var libraryPage: some View {
        VStack(spacing: 0) {
            header
            tabs
            filterBar
            if let contextError {
                StatusBanner(title: L10n.text("Execution failed"), message: contextError, tint: .red)
                    .padding(.horizontal, Spacing.xl).padding(.bottom, Spacing.s)
            }
            list
            footer
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Text("Library").font(.pageTitle).foregroundStyle(PortSQLPalette.ink)
            Spacer(minLength: Spacing.m)
            closeButton
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder private var closeButton: some View {
        if onOpened == nil { PortbaseCloseButton { dismiss() } }
    }

    private var tabs: some View {
        PortbaseTabs(selection: $selection, options: [
            PortbaseChoice(value: LibrarySection.history, title: LibrarySection.history.title, count: library.history.count),
            PortbaseChoice(value: LibrarySection.snippets, title: LibrarySection.snippets.title, count: library.snippets.count),
        ])
        .padding(.horizontal, Spacing.xl)
        .overlay(alignment: .bottom) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
    }

    private var filterBar: some View {
        HStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(PortSQLPalette.muted).accessibilityHidden(true)
                TextField(L10n.text("Search queries"), text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .portbaseTextCapitalization(.never)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PortSQLPalette.muted) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.bodyText)
            .portbaseFieldChrome()
            .frame(maxWidth: .infinity)
            if selection == .history {
                Menu {
                    Picker("Status", selection: $outcome) {
                        Text("All Statuses").tag(Optional<QueryHistoryOutcome>.none)
                        ForEach(QueryHistoryOutcome.allCases, id: \.self) { value in
                            Label(value.title, systemImage: value.symbolName).tag(Optional(value))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    filterLabel(outcome?.title ?? L10n.text("All Statuses"), active: outcome != nil)
                }
                .portbaseFilterMenu()
                .accessibilityLabel("Status")
            }
            Menu {
                Picker("Connection", selection: $currentConnectionOnly) {
                    Text("All Connections").tag(false)
                    Text("Current Connection").tag(true)
                }
                .pickerStyle(.inline)
                .disabled(workspace.selectedBookmark == nil)
            } label: {
                filterLabel(currentConnectionOnly ? (workspace.selectedBookmark?.name ?? L10n.text("Current Connection")) : L10n.text("All Connections"),
                            active: currentConnectionOnly)
            }
            .portbaseFilterMenu()
            .accessibilityLabel("Connection")
            if selection == .snippets {
                Button { workspace.saveSnippet() } label: { Label("Save Current", systemImage: "plus") }
                    .buttonStyle(.portbaseSecondary)
                    .disabled(workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
    }

    private func filterLabel(_ title: String, active: Bool) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.microText).foregroundStyle(PortSQLPalette.muted)
        }
        .font(.captionStrong)
        .foregroundStyle(active ? PortSQLPalette.accent : PortSQLPalette.ink)
        .padding(.horizontal, Spacing.s)
        .frame(minHeight: Sizes.statusBar)
        .background(active ? PortSQLPalette.accentSoft : PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(active ? PortSQLPalette.accent.opacity(0.4) : PortSQLPalette.stroke, lineWidth: 1) }
        .contentShape(Rectangle())
    }

    private var list: some View {
        List {
            if selection == .history {
                ForEach(historyDays, id: \.day) { group in
                    // Day labels are plain rows so they align with the rows below, without section chrome.
                    Text(Self.dayTitle(group.day))
                        .font(.captionStrong)
                        .foregroundStyle(PortSQLPalette.muted)
                        .padding(.horizontal, Spacing.m)
                        .padding(.top, group.day == historyDays.first?.day ? 0 : Spacing.m)
                        .padding(.bottom, Spacing.xxs)
                        .libraryRow()
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.entries) { entry in
                        LibraryHistoryRow(entry: entry) { load(entry) }
                            .libraryRow()
                            .contextMenu { historyMenu(entry) }
                            .swipeActions { Button("Delete", role: .destructive) { delete(entry) } }
                    }
                }
            } else {
                ForEach(snippets) { snippet in
                    LibrarySnippetRow(snippet: snippet, open: { load(snippet) }, edit: { editing = snippet })
                        .libraryRow()
                        .contextMenu { snippetMenu(snippet) }
                        .swipeActions { Button("Delete", role: .destructive) { delete(snippet) } }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .overlay {
            if selection == .history ? history.isEmpty : snippets.isEmpty { emptyState }
        }
    }

    private var emptyState: some View {
        let filtered = !search.isEmpty || outcome != nil || currentConnectionOnly
        return PortbaseEmptyState(
            title: filtered ? L10n.text("No matching queries") : (selection == .history ? L10n.text("No queries yet") : L10n.text("No saved queries")),
            message: selection == .history ? L10n.text("Queries you run appear here. Loading one never runs it.")
                                           : L10n.text("Save a query from the console to keep it one tap away."),
            systemImage: selection == .history ? "clock.arrow.circlepath" : "bookmark",
            secondaryTitle: filtered ? L10n.text("Reset Filters") : nil,
            secondaryAction: filtered ? { search = ""; outcome = nil; currentConnectionOnly = false } : nil
        )
        .padding(Spacing.xxl)
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Text(selection == .history ? L10n.format("Queries: %d", history.count) : L10n.format("Saved Queries: %d", snippets.count))
                .font(.captionText.monospacedDigit())
                .foregroundStyle(PortSQLPalette.muted)
            Spacer(minLength: Spacing.s)
            Button { showsStorage = true } label: { Label("Trash & Storage", systemImage: "trash") }
                .buttonStyle(.portbaseToolbar)
                .font(.captionStrong)
        }
        .padding(.horizontal, Spacing.xl)
        .frame(minHeight: Sizes.toolbar)
        .overlay(alignment: .top) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
    }

    // MARK: Trash and storage

    private var storage: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Button { showsStorage = false } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.portbaseToolbar)
                Spacer(minLength: Spacing.m)
                closeButton
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.s)
            Text("Trash & Storage").font(.pageTitle).foregroundStyle(PortSQLPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.s)
            LibraryStorageView()
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: Actions

    private func load(_ entry: QueryHistoryEntry) {
        // With connection tabs, a query opens in its connection's tab rather than replacing the current one.
        if let sessionOpener, let id = entry.bookmarkID {
            sessionOpener.open(id) { _ = $0.apply(history: entry) }
            finish()
        } else if workspace.apply(history: entry) { finish() } else { contextError = workspace.errorMessage }
    }

    private func load(_ snippet: SavedQuerySnippet) {
        if let sessionOpener, let id = snippet.bookmarkID {
            sessionOpener.open(id) { _ = $0.apply(snippet: snippet) }
            finish()
        } else if workspace.apply(snippet: snippet) { finish() } else { contextError = workspace.errorMessage }
    }

    private func finish() {
        if let onOpened { onOpened() } else { dismiss() }
    }

    private func delete(_ entry: QueryHistoryEntry) {
        if let index = library.history.firstIndex(where: { $0.id == entry.id }) { library.deleteHistory(at: IndexSet(integer: index)) }
    }

    private func delete(_ snippet: SavedQuerySnippet) {
        if let index = library.snippets.firstIndex(where: { $0.id == snippet.id }) { library.deleteSnippets(at: IndexSet(integer: index)) }
    }

    @ViewBuilder private func historyMenu(_ entry: QueryHistoryEntry) -> some View {
        Button("Load into Console", systemImage: "arrow.down.doc") { load(entry) }
        Button("Copy SQL", systemImage: "doc.on.doc") { PortbaseClipboard.copy(entry.sql) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(entry) }
    }

    @ViewBuilder private func snippetMenu(_ snippet: SavedQuerySnippet) -> some View {
        Button("Load into Console", systemImage: "arrow.down.doc") { load(snippet) }
        Button("Edit", systemImage: "pencil") { editing = snippet }
        Button("Copy SQL", systemImage: "doc.on.doc") { PortbaseClipboard.copy(snippet.sql) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(snippet) }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.text("Today") }
        if calendar.isDateInYesterday(day) { return L10n.text("Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}

/// A rounded tile with the engine's symbol, like a Termius host icon.
private struct LibraryEngineTile: View {
    let engine: DatabaseEngine?
    var fallback = "terminal"

    var body: some View {
        Group {
            if let engine {
                EngineGlyph(engine: engine).fill(engine.tint).frame(width: 18, height: 18)
            } else {
                Image(systemName: fallback).font(.captionStrong).foregroundStyle(PortSQLPalette.muted)
            }
        }
            .frame(width: Sizes.avatar, height: Sizes.avatar)
            .background((engine?.tint ?? PortSQLPalette.muted).opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct LibraryHistoryRow: View {
    let entry: QueryHistoryEntry
    let open: () -> Void
    @State private var hovering = false

    private var outcome: QueryHistoryOutcome { entry.outcome ?? .succeeded }
    private var outcomeTint: Color {
        switch outcome { case .succeeded: .green; case .failed: .red; case .cancelled: .gray }
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: Spacing.m) {
                LibraryEngineTile(engine: entry.engine)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(outcomeTint)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().strokeBorder(PortSQLPalette.canvasTop, lineWidth: 1.5) }
                            .offset(x: 2, y: 2)
                    }
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(Self.preview(entry.sql))
                        .font(.codeDetail)
                        .foregroundStyle(PortSQLPalette.ink)
                        .lineLimit(1)
                    Text(outcome == .succeeded ? [entry.connectionName, entry.database].compactMap { $0 }.joined(separator: " · ") : entry.summary)
                        .font(.captionText)
                        .foregroundStyle(outcome == .failed ? Color.red : PortSQLPalette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Spacing.xxxs) {
                    Text(entry.executedAt, format: .dateTime.hour().minute())
                        .font(.captionText.monospacedDigit())
                        .foregroundStyle(PortSQLPalette.muted)
                    if let duration = entry.duration {
                        Text(WorkspaceActivityService.durationLabel(duration))
                            .font(.microText.monospacedDigit())
                            .foregroundStyle(PortSQLPalette.muted)
                    }
                }
            }
            .libraryRowChrome(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([outcome.title, entry.title, entry.connectionName].joined(separator: ", "))
        .accessibilityHint("Loads this query into the console without running it")
    }

    /// The query on one line, with runs of whitespace collapsed.
    static func preview(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct LibrarySnippetRow: View {
    let snippet: SavedQuerySnippet
    let open: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: open) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    LibraryEngineTile(engine: snippet.engine, fallback: "bookmark.fill")
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(snippet.title).font(.rowTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                        Text(snippet.note.isEmpty ? LibraryHistoryRow.preview(snippet.sql) : snippet.note)
                            .font(snippet.note.isEmpty ? .codeCaption : .captionText)
                            .foregroundStyle(PortSQLPalette.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let engine = snippet.engine {
                        Text([engine.rawValue, snippet.database].compactMap { $0 }.joined(separator: " · "))
                            .font(.captionText)
                            .foregroundStyle(PortSQLPalette.muted)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Loads this query into the console without running it")
            Button(action: edit) {
                Image(systemName: "pencil").foregroundStyle(PortSQLPalette.muted)
                    .frame(width: Sizes.tool, height: Sizes.tool)
            }
            .buttonStyle(.portbaseToolbar)
            .opacity(hovering ? 1 : PortbaseLibraryStyle.restingActionOpacity)
            .accessibilityLabel(L10n.format("Edit saved query %@", snippet.title))
        }
        .libraryRowChrome(hovering: hovering)
        .onHover { hovering = $0 }
    }
}

private enum PortbaseLibraryStyle {
#if os(macOS)
    /// Row actions stay faint until the pointer is over the row, as in Termius.
    static let restingActionOpacity: Double = 0.35
    static let rowInset: CGFloat = 0
#else
    static let restingActionOpacity: Double = 1
    static let rowInset: CGFloat = Spacing.xl - Spacing.m
#endif
}

private extension View {
    func libraryRowChrome(hovering: Bool) -> some View {
        padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: Sizes.row)
            .background(hovering ? PortSQLPalette.surface : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }

    /// Row content lines up with the page margin; the Mac's plain list adds its own 8-point inset.
    func libraryRow() -> some View {
        listRowInsets(EdgeInsets(top: 1, leading: PortbaseLibraryStyle.rowInset, bottom: 1, trailing: PortbaseLibraryStyle.rowInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder func portbaseFilterMenu() -> some View {
#if os(macOS)
        // A plain button menu draws the chip label as designed instead of as link-tinted text.
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
#else
        self
#endif
    }
}

private struct SavedQueryDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @State var snippet: SavedQuerySnippet

    var body: some View {
        PortbaseSheet(L10n.text("Edit Saved Query")) {
            Form {
                TextField("Query name", text: $snippet.title)
                Section("Notes") { TextEditor(text: $snippet.note).frame(minHeight: 100).accessibilityLabel("Query notes") }
                Section("Connection") {
                    Text([snippet.engine?.rawValue, snippet.database].compactMap { $0 }.joined(separator: " · "))
                    Button("Use Current Connection") {
                        snippet.bookmarkID = workspace.selectedBookmark?.id
                        snippet.engine = workspace.selectedBookmark?.engine
                        snippet.database = workspace.activeDatabaseName
                    }
                    .disabled(workspace.selectedBookmark == nil)
                }
                Section("Query") { Text(snippet.sql).font(.codeDetail).textSelection(.enabled) }
            }
            .portbaseForm()
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button("Save") { snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines); library.updateSnippet(snippet); dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private enum LibrarySection: String, CaseIterable, Identifiable {
    case history
    case snippets

    var id: String { rawValue }

    var title: String {
        switch self { case .history: L10n.text("History"); case .snippets: L10n.text("Saved Queries") }
    }
}

private extension QueryHistoryOutcome {
    var symbolName: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }
}
