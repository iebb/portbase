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
                VStack(alignment: .leading, spacing: 12) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "tablecells.fill")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(PortSQLPalette.accentGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Browse")
                                        .font(.title3.weight(.bold))
                                        .accessibilityAddTraits(.isHeader)
                                    Text(explorerSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    focusedClause = nil
                                    workspace.restartBrowse()
                                } label: {
                                    Image(systemName: "play.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white)
                                .background(PortSQLPalette.accentGradient, in: Capsule())
                                .shadow(color: PortSQLPalette.accent.opacity(0.3), radius: 6, x: 0, y: 3)
                                .disabled(workspace.selectedExplorerTable == nil || workspace.isRunning)
                                .accessibilityLabel("Run table browse query")
                                .accessibilityHint("Applies the current WHERE and ORDER BY clauses")
                            }

                            if let selectedTable = workspace.selectedExplorerTable {
                                HStack(alignment: .center, spacing: 10) {
                                    Menu {
                                        ForEach(filteredTables) { table in
                                            Button {
                                                focusedClause = nil
                                                workspace.selectExplorerTable(table)
                                            } label: {
                                                HStack(alignment: .top, spacing: 10) {
                                                    Image(systemName: workspace.selectedExplorerTableID == table.id ? "checkmark.circle.fill" : "tablecells")
                                                        .font(.footnote.weight(.bold))
                                                        .foregroundStyle(workspace.selectedExplorerTableID == table.id ? PortSQLPalette.accent : .secondary)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(table.name)
                                                            .font(.subheadline.weight(.semibold))
                                                        VStack(alignment: .leading, spacing: 1) {
                                                            Text(tableSummary(table))
                                                                .font(.caption2)
                                                                .foregroundStyle(.secondary)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Table")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                Text(selectedTable.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(PortSQLPalette.ink)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.down")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(PortSQLPalette.stroke, lineWidth: 1)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(minHeight: 44)
                                    .accessibilityLabel(L10n.format("Choose table, currently %@", selectedTable.name))
                                }

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        PortbaseChip(title: L10n.plural("column_count_short", count: selectedTable.columns.count), systemImage: "tablecells", tint: .teal)
                                        if let estimate = selectedTable.rowCountEstimate {
                                            PortbaseChip(title: L10n.plural("row_count", count: estimate), systemImage: "list.number", tint: PortSQLPalette.accent)
                                        }
                                        if !selectedTable.primaryKeyColumns.isEmpty {
                                            PortbaseChip(title: selectedTable.primaryKeyColumns.map(\.name).joined(separator: ", "), systemImage: "key.fill", tint: .orange)
                                        }
                                        if workspace.canInsertIntoCurrentTable && workspace.selectedBookmark?.isReadOnly != true {
                                            PortbaseChip(title: L10n.text("Editable"), systemImage: "pencil", tint: .green)
                                        }
                                    }
                                }

                                clauseRow(
                                    field: .whereClause,
                                    title: "WHERE",
                                    text: $workspace.explorerWhereClause,
                                    placeholder: wherePlaceholder(for: selectedTable),
                                    suggestions: whereSuggestions(for: selectedTable),
                                    apply: applyWhereSuggestion
                                )

                                clauseRow(
                                    field: .orderByClause,
                                    title: "ORDER",
                                    text: $workspace.explorerOrderByClause,
                                    placeholder: orderByPlaceholder(for: selectedTable),
                                    suggestions: orderBySuggestions(for: selectedTable),
                                    apply: applyOrderSuggestion
                                )
                            } else {
                                HStack(spacing: 10) {
                                    Image(systemName: "tablecells")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("Choose a table to browse and filter rows.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(PortSQLPalette.stroke, lineWidth: 1)
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
                        PanelCard {
                            StatusBanner(
                                title: "Schema unavailable",
                                message: schemaErrorMessage,
                                tint: .orange
                            )
                        }
                    } else if filteredTables.isEmpty {
                        PanelCard {
                            if workspace.selectedBookmark == nil {
                                ContentUnavailableView {
                                    Label("Add a database connection", systemImage: "server.rack")
                                } actions: {
                                    Button {
                                        workspace.createBookmark()
                                    } label: {
                                        Label("Add Connection", systemImage: "plus.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .accessibilityHint("Opens the server connection form")
                                }
                            } else {
                                ContentUnavailableView {
                                    Label("No schema metadata", systemImage: "square.stack.3d.up.slash")
                                } actions: {
                                    Button {
                                        workspace.refreshSchemaCatalog()
                                    } label: {
                                        Label("Refresh Tables", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .disabled(workspace.isLoadingSchema)
                                }
                            }
                        }
                    } else {
                        ResultsCard()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
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
                ConnectionSwitcherButton(toolbarMode: true)
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

    private func wherePlaceholder(for table: SchemaTableDescriptor) -> String {
        let columnName = table.columns.first?.name ?? "column"
        return "\(columnName) > 5"
    }

    private func orderByPlaceholder(for table: SchemaTableDescriptor) -> String {
        let columnName = table.columns.first?.name ?? "column"
        return "\(columnName) DESC"
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
    private func clauseRow(
        field: ClauseField,
        title: String,
        text: Binding<String>,
        placeholder: String,
        suggestions: [ClauseSuggestion],
        apply: @escaping (ClauseSuggestion) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let fieldLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))

            fieldLayout {
                Text(title)
                    .font(.caption.weight(.bold))
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
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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

    private var explorerSubtitle: String {
        if workspace.isLoadingSchema, let database = workspace.activeDatabaseName {
            return L10n.format("Loading %@", database)
        }
        if let database = workspace.activeDatabaseName {
            return L10n.format("Live browsing in %@", database)
        }
        return L10n.text("Choose a table to browse live rows")
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(PortSQLPalette.surface, in: Capsule())
            .overlay {
                Capsule()
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

    private func outcomeFilter(_ value: QueryHistoryOutcome?, title: String, symbol: String) -> some View {
        let selected = outcome == value
        return Button { withAnimation(.easeOut(duration: 0.15)) { outcome = value } } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .white : PortSQLPalette.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: PortbaseControlSize.minimumHeight)
                .background(selected ? AnyShapeStyle(PortSQLPalette.accentGradient) : AnyShapeStyle(PortSQLPalette.surface), in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? Color.clear : PortSQLPalette.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyRow: some View {
        PortbaseEmptyState(
            title: L10n.text("No matching queries"),
            message: selection == .history ? L10n.text("Queries you run appear here. Loading one never runs it.")
                                           : L10n.text("Save a query from the console to keep it one tap away."),
            systemImage: selection == .history ? "clock.arrow.circlepath" : "bookmark"
        )
        .listRowBackground(Color.clear)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Library", selection: $selection) {
                        ForEach(LibrarySection.allCases) { section in Text(section.title).tag(section) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    if selection == .history {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                outcomeFilter(nil, title: L10n.text("All Statuses"), symbol: "line.3.horizontal.decrease")
                                ForEach(QueryHistoryOutcome.allCases, id: \.self) { value in
                                    outcomeFilter(value, title: value.title, symbol: value.symbolName)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    }
                }
                if let contextError {
                    Section { StatusBanner(title: L10n.text("Execution failed"), message: contextError, tint: .red) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if selection == .history {
                    Section {
                        ForEach(history) { entry in
                            Button {
                                if workspace.apply(history: entry) { dismiss() }
                                else { contextError = workspace.errorMessage }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    RecentQueryRow(entry: entry)
                                    if entry.outcome == .failed || entry.outcome == .cancelled {
                                        Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            .padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 6)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .accessibilityHint("Loads this query into the console without running it")
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    if let index = library.history.firstIndex(where: { $0.id == entry.id }) { library.deleteHistory(at: IndexSet(integer: index)) }
                                }
                            }
                        }
                        if history.isEmpty { emptyRow }
                    } header: {
                        Text(L10n.format("Queries: %d", history.count))
                    }
                } else {
                    Section {
                        Button {
                            workspace.saveSnippet()
                        } label: {
                            Label("Save Current", systemImage: "bookmark.fill")
                        }
                        .disabled(workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ForEach(snippets) { snippet in
                            HStack(alignment: .top, spacing: 12) {
                                Button {
                                    if workspace.apply(snippet: snippet) { dismiss() }
                                    else { contextError = workspace.errorMessage }
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 28, height: 28)
                                            .background(LinearGradient(colors: (snippet.engine ?? .postgresql).brandColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(snippet.title).font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                            if !snippet.note.isEmpty { Text(snippet.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                            Text(snippet.sql).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
                                            if let engine = snippet.engine {
                                                PortbaseChip(title: [engine.rawValue, snippet.database].compactMap { $0 }.joined(separator: " · "), tint: engine.tint)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Loads this query into the console without running it")
                                Button { editing = snippet } label: { Image(systemName: "pencil").toolIconChrome() }
                                    .buttonStyle(.plain).accessibilityLabel(L10n.format("Edit saved query %@", snippet.title))
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    if let index = library.snippets.firstIndex(where: { $0.id == snippet.id }) { library.deleteSnippets(at: IndexSet(integer: index)) }
                                }
                            }
                        }
                        if snippets.isEmpty { emptyRow }
                    }
                }
            }
            .listStyle(.portbaseGrouped)
            .scrollContentBackground(.hidden)
            .background(PortbaseBackdrop().ignoresSafeArea())
            .searchable(text: $search, prompt: L10n.text("Search queries"))
            .navigationTitle("Library")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: PortbaseToolbar.leading) { NavigationLink("Trash") { LibraryStorageView() } }
                ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                    Menu {
                        Toggle("Current connection only", isOn: $currentConnectionOnly)
                            .disabled(workspace.selectedBookmark == nil)
                        if selection == .history {
                            Picker("Status", selection: $outcome) {
                                Text("All Statuses").tag(Optional<QueryHistoryOutcome>.none)
                                ForEach(QueryHistoryOutcome.allCases, id: \.self) { value in Text(value.title).tag(Optional(value)) }
                            }
                        }
                        Button("Reset Filters") { outcome = nil; currentConnectionOnly = false; search = "" }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Filter queries")
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { snippet in SavedQueryDetailsSheet(snippet: snippet) }
        }
    }
}

private struct SavedQueryDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @State var snippet: SavedQuerySnippet

    var body: some View {
        NavigationStack {
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
                Section("Query") { Text(snippet.sql).font(.callout.monospaced()).textSelection(.enabled) }
            }
            .navigationTitle("Edit Saved Query")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines); library.updateSnippet(snippet); dismiss() }
                        .disabled(snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
