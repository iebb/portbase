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

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    // Browsing needs a connection; without one, only the empty state below is shown.
                    if workspace.selectedBookmark != nil {
                        PanelCard {
                            VStack(alignment: .leading, spacing: Spacing.m) {
                                // One row: the table and the run button (selecting a table browses it; run re-applies the clauses).
                                HStack(alignment: .center, spacing: Spacing.s) {
                                    tableMenu
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

                                if let selectedTable = workspace.selectedExplorerTable {

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

                                    clauseRow(
                                        field: .whereClause,
                                        title: "WHERE",
                                        text: $workspace.explorerWhereClause,
                                        placeholder: L10n.text("Filter"),
                                        suggestions: whereSuggestions(for: selectedTable),
                                        apply: applyWhereSuggestion
                                    )

                                    clauseRow(
                                        field: .orderByClause,
                                        title: "ORDER",
                                        text: $workspace.explorerOrderByClause,
                                        placeholder: L10n.text("Sort"),
                                        suggestions: orderBySuggestions(for: selectedTable),
                                        apply: applyOrderSuggestion
                                    )
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
                                title: "Loading database",
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
                    }
                }
                .padding(Spacing.l)
                .frame(width: proxy.size.width, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissClauseFocus()
                }
            }
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

    private func dismissClauseFocus() {
        focusedClause = nil
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#else
        NSApp.keyWindow?.makeFirstResponder(nil)
#endif
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
        suggestions: [ClauseSuggestion],
        apply: @escaping (ClauseSuggestion) -> Void
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
                    suggestions: Array(suggestions.prefix(6)).map {
                        InlineSuggestionItem(title: $0.label, subtitle: nil)
                    },
                    onSelect: { item in
                        if let match = suggestions.first(where: { $0.label == item.title }) {
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

    private func whereSuggestions(for table: SchemaTableDescriptor) -> [ClauseSuggestion] {
        let context = clauseContext(for: workspace.explorerWhereClause)
        let columnNames = table.columns.map(\.name)
        let normalizedColumns = Set(columnNames.map { $0.lowercased() })
        let previousToken = context.previousToken?.lowercased()
        let currentToken = context.currentToken.lowercased()

        let columnSuggestions = columnNames.map { ClauseSuggestion(label: $0, insertion: $0) }
        let logicalSuggestions = [
            ClauseSuggestion(label: "AND", insertion: "AND "),
            ClauseSuggestion(label: "OR", insertion: "OR ")
        ]
        let operatorSuggestions = [
            ClauseSuggestion(label: "=", insertion: "= "),
            ClauseSuggestion(label: "!=", insertion: "!= "),
            ClauseSuggestion(label: ">", insertion: "> "),
            ClauseSuggestion(label: ">=", insertion: ">= "),
            ClauseSuggestion(label: "<", insertion: "< "),
            ClauseSuggestion(label: "<=", insertion: "<= "),
            ClauseSuggestion(label: "LIKE", insertion: "LIKE "),
            ClauseSuggestion(label: "IN", insertion: "IN "),
            ClauseSuggestion(label: "IS NULL", insertion: "IS NULL"),
            ClauseSuggestion(label: "IS NOT NULL", insertion: "IS NOT NULL")
        ]
        let valueSuggestions = [
            ClauseSuggestion(label: "NULL", insertion: "NULL"),
            ClauseSuggestion(label: "0", insertion: "0"),
            ClauseSuggestion(label: "''", insertion: "''"),
            ClauseSuggestion(label: "TRUE", insertion: "TRUE"),
            ClauseSuggestion(label: "FALSE", insertion: "FALSE")
        ]

        let currentLooksLikeColumn = normalizedColumns.contains(currentToken)
        let previousIsColumn = previousToken.map(normalizedColumns.contains) ?? false

        if previousToken == "is" {
            return filteredSuggestions(
                from: [
                    ClauseSuggestion(label: "NULL", insertion: "NULL"),
                    ClauseSuggestion(label: "NOT NULL", insertion: "NOT NULL")
                ] + logicalSuggestions + columnSuggestions,
                matching: context.currentToken
            )
        }

        if ["=", "!=", ">", ">=", "<", "<=", "like", "in"].contains(previousToken ?? "") {
            return filteredSuggestions(
                from: valueSuggestions + columnSuggestions + logicalSuggestions,
                matching: context.currentToken
            )
        }

        if ["null", "not null", "true", "false"].contains(previousToken ?? "") {
            return filteredSuggestions(
                from: logicalSuggestions + columnSuggestions,
                matching: context.currentToken
            )
        }

        if previousIsColumn || currentLooksLikeColumn {
            return filteredSuggestions(
                from: operatorSuggestions + logicalSuggestions + columnSuggestions,
                matching: context.currentToken
            )
        }

        if ["and", "or"].contains(previousToken ?? "") {
            return filteredSuggestions(
                from: columnSuggestions + logicalSuggestions,
                matching: context.currentToken
            )
        }

        return filteredSuggestions(
            from: columnSuggestions + logicalSuggestions + operatorSuggestions,
            matching: context.currentToken
        )
    }

    private func orderBySuggestions(for table: SchemaTableDescriptor) -> [ClauseSuggestion] {
        let context = clauseContext(for: workspace.explorerOrderByClause)
        let columnNames = table.columns.map(\.name)
        let normalizedColumns = Set(columnNames.map { $0.lowercased() })
        let previousToken = context.previousToken?.lowercased()
        let currentToken = context.currentToken.lowercased()
        let currentLooksLikeColumn = normalizedColumns.contains(currentToken)

        let columnSuggestions = columnNames.map { ClauseSuggestion(label: $0, insertion: $0) }
        let sortSuggestions = [
            ClauseSuggestion(label: "ASC", insertion: "ASC"),
            ClauseSuggestion(label: "DESC", insertion: "DESC"),
            ClauseSuggestion(label: ",", insertion: ", ")
        ]

        if context.lastSignificantCharacter == "," {
            return filteredSuggestions(
                from: columnSuggestions + sortSuggestions,
                matching: context.currentToken
            )
        }

        if ["asc", "desc"].contains(previousToken ?? "") {
            return filteredSuggestions(
                from: [ClauseSuggestion(label: ",", insertion: ", ")] + columnSuggestions,
                matching: context.currentToken
            )
        }

        if previousToken.map(normalizedColumns.contains) ?? false || currentLooksLikeColumn {
            return filteredSuggestions(
                from: sortSuggestions + columnSuggestions,
                matching: context.currentToken
            )
        }

        return filteredSuggestions(
            from: columnSuggestions + sortSuggestions,
            matching: context.currentToken
        )
    }

    private func filteredSuggestions(from candidates: [ClauseSuggestion], matching token: String) -> [ClauseSuggestion] {
        let deduplicated = orderedUnique(candidates)
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedToken.isEmpty else {
            return Array(deduplicated.prefix(8))
        }

        let ranked = deduplicated.sorted { lhs, rhs in
            let leftRank = suggestionRank(lhs.label, token: normalizedToken)
            let rightRank = suggestionRank(rhs.label, token: normalizedToken)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        return Array(ranked.filter { suggestionRank($0.label, token: normalizedToken) < 3 }.prefix(8))
    }

    private func applyWhereSuggestion(_ suggestion: ClauseSuggestion) {
        workspace.explorerWhereClause = mergedClause(current: workspace.explorerWhereClause, suggestion: suggestion)
        focusedClause = .whereClause
    }

    private func applyOrderSuggestion(_ suggestion: ClauseSuggestion) {
        workspace.explorerOrderByClause = mergedClause(current: workspace.explorerOrderByClause, suggestion: suggestion)
        focusedClause = .orderByClause
    }

    private func mergedClause(current: String, suggestion: ClauseSuggestion) -> String {
        let fragment = trailingTokenFragment(in: current)

        if !fragment.isEmpty {
            let dropCount = fragment.count
            let prefix = String(current.dropLast(dropCount))
            return normalizedClause(prefix + suggestion.insertion)
        }

        if current.isEmpty {
            return normalizedClause(suggestion.insertion)
        }

        if suggestion.insertion == ", " {
            return normalizedClause(current + ", ")
        }

        if let lastCharacter = current.last, lastCharacter.isWhitespace {
            return normalizedClause(current + suggestion.insertion)
        }

        return normalizedClause(current + " " + suggestion.insertion)
    }

    private func clauseContext(for input: String) -> ClauseContext {
        let tokens = clauseTokens(in: input)
        let endsWithWhitespace = input.last?.isWhitespace == true
        let fragment = trailingTokenFragment(in: input)
        let currentToken = endsWithWhitespace ? "" : fragment
        let completedTokens = currentToken.isEmpty ? tokens : Array(tokens.dropLast())
        return ClauseContext(
            currentToken: currentToken,
            previousToken: completedTokens.last,
            lastSignificantCharacter: input.trimmingCharacters(in: .whitespacesAndNewlines).last
        )
    }

    private func clauseTokens(in input: String) -> [String] {
        var tokens: [String] = []
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }

            if character.isLetter || character.isNumber || character == "_" {
                let start = index
                index += 1
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    index += 1
                }
                tokens.append(String(characters[start..<index]))
                continue
            }

            if index + 1 < characters.count {
                let pair = String(characters[index...index + 1])
                if [">=", "<=", "!=", "=="].contains(pair) {
                    tokens.append(pair)
                    index += 2
                    continue
                }
            }

            if [">", "<", "=", ",", "(", ")"].contains(character) {
                tokens.append(String(character))
            }
            index += 1
        }

        return tokens
    }

    private func trailingTokenFragment(in input: String) -> String {
        let fragment = input.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return String(fragment.reversed())
    }

    private func normalizedClause(_ value: String) -> String {
        value.replacingOccurrences(of: "  ", with: " ")
    }

    private func orderedUnique(_ candidates: [ClauseSuggestion]) -> [ClauseSuggestion] {
        var seen = Set<ClauseSuggestion>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func suggestionRank(_ candidate: String, token: String) -> Int {
        let normalizedCandidate = candidate.lowercased()
        if normalizedCandidate == token {
            return 0
        }
        if normalizedCandidate.hasPrefix(token) {
            return 1
        }
        if normalizedCandidate.contains(token) {
            return 2
        }
        return 3
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

    private struct ClauseSuggestion: Hashable {
        let label: String
        let insertion: String
    }

    private struct ClauseContext {
        let currentToken: String
        let previousToken: String?
        let lastSignificantCharacter: Character?
    }
}

/// Query history and saved queries on one continuous surface, in the style of Termius's lists: a title
/// with a close button, underline tabs with counts, one search-and-filter row, flat rows grouped by day,
/// and a quiet footer. Loading a query never runs it.
struct LibrarySheetView: View {
    @Environment(\.dismiss) private var dismiss
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

    private var closeButton: some View {
        PortbaseCloseButton { dismiss() }
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
        if workspace.apply(history: entry) { dismiss() } else { contextError = workspace.errorMessage }
    }

    private func load(_ snippet: SavedQuerySnippet) {
        if workspace.apply(snippet: snippet) { dismiss() } else { contextError = workspace.errorMessage }
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
        Image(systemName: engine?.symbolName ?? fallback)
            .font(.captionStrong)
            .foregroundStyle(engine?.tint ?? PortSQLPalette.muted)
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
