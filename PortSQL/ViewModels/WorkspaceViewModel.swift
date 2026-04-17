import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var selectedBookmarkID: UUID?
    @Published var selectedDatabaseName = ""
    @Published private(set) var availableDatabases: [String] = []
    @Published var queryText = ""
    @Published var explorerWhereClause = ""
    @Published var explorerOrderByClause = ""
    @Published private(set) var explorerPageIndex = 0
    @Published private(set) var explorerPageSize = 25
    @Published var suggestions: [String] = []
    @Published var hints: [EditorHint] = []
    @Published var schema: [SchemaSuggestion] = []
    @Published var schemaCatalog: [SchemaTableDescriptor] = []
    @Published var result = QueryResultTable.empty
    @Published var selectedProfileForEdit: ConnectionProfile?
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var schemaErrorMessage: String?
    @Published var dataEditorDraft: DataEditorDraft?
    @Published var dataEditorValidation: [UUID: String] = [:]
    @Published var dataEditorErrorMessage: String?
    @Published var isSavingMutation = false
    @Published var selectedExplorerTableID: UUID?

    private weak var bookmarkStore: BookmarkStore?
    private weak var libraryStore: WorkspaceLibraryStore?

    func configure(bookmarkStore: BookmarkStore, libraryStore: WorkspaceLibraryStore) {
        self.bookmarkStore = bookmarkStore
        self.libraryStore = libraryStore
        if selectedBookmarkID == nil {
            selectedBookmarkID = bookmarkStore.bookmarks.first?.id
        }
        selectedDatabaseName = selectedBookmark?.trimmedDefaultDatabase ?? ""
        refreshAssist()
        reloadSchema()
    }

    var selectedBookmark: ConnectionProfile? {
        bookmarkStore?.bookmark(with: selectedBookmarkID)
    }

    var activeDatabaseName: String? {
        let explicit = selectedDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let fallback = selectedBookmark?.trimmedDefaultDatabase ?? ""
        if !fallback.isEmpty {
            return fallback
        }

        return availableDatabases.first
    }

    var visualProfiles: [QueryColumnProfile] {
        result.profiles.filter { !$0.numericSeries.isEmpty }
    }

    var history: [QueryHistoryEntry] {
        libraryStore?.history ?? []
    }

    var snippets: [SavedQuerySnippet] {
        libraryStore?.snippets ?? []
    }

    var selectedExplorerTable: SchemaTableDescriptor? {
        if let selectedExplorerTableID {
            return schemaCatalog.first(where: { $0.id == selectedExplorerTableID })
        }
        return schemaCatalog.first
    }

    var currentEditableTable: SchemaTableDescriptor? {
        let reference = result.sourceTableReference ?? inferredTableReference(in: queryText)
        guard let reference else { return nil }
        return schemaCatalog.first(where: { $0.matches(reference: reference) })
    }

    var canInsertIntoCurrentTable: Bool {
        currentEditableTable != nil
    }

    var canEditCurrentRows: Bool {
        guard let table = currentEditableTable, !result.rows.isEmpty else { return false }
        let resultColumnNames = Set(result.columns.map { normalizedIdentifier($0.name) })
        let identifiers = table.editingIdentifierColumns
        return !identifiers.isEmpty
            && identifiers.allSatisfy { resultColumnNames.contains(normalizedIdentifier($0.name)) }
    }

    var isShowingExplorerResult: Bool {
        guard let selectedExplorerTable else { return false }
        let currentQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedBrowseQuery = browseQuery(for: selectedExplorerTable).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.sourceTableReference == selectedExplorerTable.displayName
            && currentQuery == expectedBrowseQuery
    }

    var canGoToPreviousExplorerPage: Bool {
        isShowingExplorerResult && explorerPageIndex > 0 && !isRunning
    }

    var canGoToNextExplorerPage: Bool {
        isShowingExplorerResult && result.rows.count >= explorerPageSize && !isRunning
    }

    var explorerPageLabel: String {
        "Page \(explorerPageIndex + 1)"
    }

    var explorerResultRangeLabel: String {
        guard isShowingExplorerResult, !result.rows.isEmpty else { return "0 rows" }
        let start = explorerPageIndex * explorerPageSize + 1
        let end = start + result.rows.count - 1
        return "\(start)-\(end)"
    }

    var explorerSortColumn: String? {
        let trimmed = normalizedOrderByClause(explorerOrderByClause)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        return parts.first.map(String.init)
    }

    var explorerSortDirection: String? {
        let trimmed = normalizedOrderByClause(explorerOrderByClause)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return "ASC" }
        let last = String(parts[1]).uppercased()
        return ["ASC", "DESC"].contains(last) ? last : "ASC"
    }

    func refreshAssist() {
        if schemaCatalog.isEmpty {
            schema = []
        } else {
            schema = schemaCatalog.flatMap { table in
                [SchemaSuggestion(kind: "table", value: table.name),
                 SchemaSuggestion(kind: "table", value: table.displayName)] +
                table.columns.flatMap { column in
                    [
                        SchemaSuggestion(kind: "column", value: column.name),
                        SchemaSuggestion(kind: "column", value: "\(table.name).\(column.name)")
                    ]
                }
            }
        }
        suggestions = SQLAssistService.suggestions(for: queryText, schema: schema)
        hints = SQLAssistService.hints(for: queryText)
    }

    func applySuggestion(_ suggestion: String) {
        if queryText.hasSuffix(" ") || queryText.isEmpty {
            queryText += suggestion
        } else {
            queryText += " " + suggestion
        }
        refreshAssist()
    }

    func runQuery() {
        run(sql: queryText, title: inferredTitle(for: queryText))
    }

    func runExplain() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(sql: "EXPLAIN \(trimmed)", title: "Explain plan")
    }

    func formatQuery() {
        queryText = SQLAssistService.format(queryText)
        refreshAssist()
    }

    func reloadSchema() {
        guard let bookmark = selectedBookmark else {
            availableDatabases = []
            schemaCatalog = []
            selectedExplorerTableID = nil
            schemaErrorMessage = nil
            refreshAssist()
            return
        }

        let currentSelection = selectedDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let databases = try await DatabaseService.shared.listDatabases(profile: bookmark)
                let resolvedDatabase = resolveDatabaseSelection(
                    requested: currentSelection,
                    bookmark: bookmark,
                    available: databases
                )
                let catalog = try await DatabaseService.shared.loadSchema(
                    profile: bookmark,
                    database: resolvedDatabase
                )
                await MainActor.run {
                    self.availableDatabases = databases
                    self.selectedDatabaseName = resolvedDatabase ?? ""
                    self.schemaCatalog = catalog
                    let activeExplorerTable: SchemaTableDescriptor?
                    if let selectedExplorerTableID,
                       let existingTable = catalog.first(where: { $0.id == selectedExplorerTableID }) {
                        self.selectedExplorerTableID = selectedExplorerTableID
                        activeExplorerTable = existingTable
                    } else {
                        let firstTable = catalog.first
                        self.selectedExplorerTableID = firstTable?.id
                        activeExplorerTable = firstTable
                    }
                    if self.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let activeExplorerTable {
                        self.queryText = self.defaultQuery(for: activeExplorerTable)
                    }
                    self.schemaErrorMessage = nil
                    self.refreshAssist()
                    if self.result.columns.isEmpty,
                       self.errorMessage == nil,
                       let activeExplorerTable {
                        self.browse(table: activeExplorerTable)
                    }
                }
            } catch {
                await MainActor.run {
                    self.availableDatabases = self.resolveFallbackDatabases(for: bookmark)
                    self.schemaCatalog = []
                    self.selectedExplorerTableID = nil
                    self.schemaErrorMessage = error.localizedDescription
                    self.refreshAssist()
                }
            }
        }
    }

    func saveSnippet() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        libraryStore?.saveSnippet(title: inferredTitle(for: trimmed), sql: trimmed)
    }

    func apply(history entry: QueryHistoryEntry) {
        queryText = entry.sql
        refreshAssist()
    }

    func apply(snippet: SavedQuerySnippet) {
        queryText = snippet.sql
        refreshAssist()
    }

    func insertReference(for table: SchemaTableDescriptor) {
        let reference = table.displayName
        if queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryText = defaultQuery(for: table)
        } else {
            queryText += "\n" + reference
        }
        selectedExplorerTableID = table.id
        refreshAssist()
    }

    func selectExplorerTable(_ table: SchemaTableDescriptor) {
        selectedExplorerTableID = table.id
        explorerPageIndex = 0
        browse(table: table)
    }

    func browse(table: SchemaTableDescriptor? = nil) {
        guard let targetTable = table ?? selectedExplorerTable else {
            errorMessage = "Choose a table before browsing rows."
            return
        }
        selectedExplorerTableID = targetTable.id
        let sql = browseQuery(for: targetTable)
        queryText = sql
        refreshAssist()
        run(sql: sql, title: "Browse \(targetTable.displayName)")
    }

    func restartBrowse() {
        explorerPageIndex = 0
        browse()
    }

    func goToPreviousExplorerPage() {
        guard canGoToPreviousExplorerPage else { return }
        explorerPageIndex -= 1
        browse()
    }

    func goToNextExplorerPage() {
        guard canGoToNextExplorerPage else { return }
        explorerPageIndex += 1
        browse()
    }

    func setExplorerPageSize(_ size: Int) {
        guard size > 0, explorerPageSize != size else { return }
        explorerPageSize = size
        explorerPageIndex = 0
        if selectedExplorerTable != nil {
            browse()
        }
    }

    func sortExplorer(by columnName: String) {
        let normalizedTarget = normalizedIdentifier(columnName)
        let normalizedCurrent = explorerSortColumn.map(normalizedIdentifier)
        if normalizedCurrent == normalizedTarget {
            explorerOrderByClause = "\(columnName) \(explorerSortDirection == "DESC" ? "ASC" : "DESC")"
        } else {
            explorerOrderByClause = "\(columnName) ASC"
        }
        explorerPageIndex = 0
        browse()
    }

    func insertColumn(_ column: SchemaColumnDescriptor, from table: SchemaTableDescriptor) {
        let reference = "\(table.name).\(column.name)"
        if queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryText = "SELECT \(reference)\nFROM \(table.displayName)\nLIMIT 50;"
        } else {
            queryText += queryText.hasSuffix(" ") ? reference : " \(reference)"
        }
        selectedExplorerTableID = table.id
        refreshAssist()
    }

    func saveSchemaColumn(_ draft: SchemaColumnDraft) async throws {
        guard let bookmark = selectedBookmark else {
            throw DatabaseServiceError.notConfigured
        }

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "PortSQL.Schema", code: 1, userInfo: [NSLocalizedDescriptionKey: "Column name is required."])
        }
        guard !trimmedType.isEmpty else {
            throw NSError(domain: "PortSQL.Schema", code: 2, userInfo: [NSLocalizedDescriptionKey: "Column type is required."])
        }

        var normalizedDraft = draft
        normalizedDraft.name = trimmedName
        normalizedDraft.type = trimmedType

        try await DatabaseService.shared.applySchemaColumnChange(
            normalizedDraft,
            profile: bookmark,
            database: activeDatabaseName
        )

        await MainActor.run {
            self.result = .empty
            self.queryText = ""
            self.selectedExplorerTableID = normalizedDraft.table.id
            self.errorMessage = nil
            self.reloadSchema()
        }
    }

    func deleteSchemaColumn(_ column: SchemaColumnDescriptor, from table: SchemaTableDescriptor) async throws {
        guard let bookmark = selectedBookmark else {
            throw DatabaseServiceError.notConfigured
        }

        try await DatabaseService.shared.dropSchemaColumn(
            column,
            from: table,
            profile: bookmark,
            database: activeDatabaseName
        )

        await MainActor.run {
            self.result = .empty
            self.queryText = ""
            self.selectedExplorerTableID = table.id
            self.errorMessage = nil
            self.reloadSchema()
        }
    }

    func deleteHistory(at offsets: IndexSet) {
        libraryStore?.deleteHistory(at: offsets)
    }

    func deleteSnippets(at offsets: IndexSet) {
        libraryStore?.deleteSnippets(at: offsets)
    }

    private func run(sql: String, title: String) {
        isRunning = true
        errorMessage = nil
        Task {
            do {
                var table = try await DatabaseService.shared.execute(
                    query: sql,
                    profile: selectedBookmark,
                    database: activeDatabaseName
                )
                table.sourceTableReference = inferredTableReference(in: sql)
                table.sourceQuery = sql
                await MainActor.run {
                    self.result = table
                    self.isRunning = false
                    self.errorMessage = nil
                    self.libraryStore?.addHistory(
                        title: title,
                        sql: sql,
                        connectionName: self.selectedBookmark?.name ?? "Unassigned",
                        summary: table.executionSummary
                    )
                    if self.shouldReloadSchema(after: sql) {
                        self.reloadSchema()
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.result = QueryResultTable.empty
                    self.isRunning = false
                }
            }
        }
    }

    func prepareEdit(row: QueryRow) {
        let resultColumnNames = result.columns.map(\.name)
        let resultMap = Dictionary(uniqueKeysWithValues: zip(resultColumnNames, row.values))
        let table = currentEditableTable ?? SchemaTableDescriptor(
            schemaName: "",
            name: inferredTableReference(in: queryText) ?? "Result Row",
            columns: result.columns.map {
                SchemaColumnDescriptor(name: $0.name, type: $0.type, isNullable: true, isPrimaryKey: false, isUnique: false)
            },
            rowCountEstimate: nil
        )

        let resultNormalized = Dictionary(uniqueKeysWithValues: zip(resultColumnNames.map(normalizedIdentifier), row.values))
        let editableIdentifierColumnNames = Set(
            (currentEditableTable?.editingIdentifierColumns ?? [])
                .map(\.name)
                .map(normalizedIdentifier)
        )
        let canUpdateRow = currentEditableTable.map { editableTable in
            let identifiers = editableTable.editingIdentifierColumns
            return !identifiers.isEmpty
                && identifiers.allSatisfy { resultNormalized[normalizedIdentifier($0.name)] != nil }
        } ?? false

        let fields = result.columns.compactMap { resultColumn -> DataEditorField? in
            let schemaColumn = currentEditableTable?.column(named: resultColumn.name)
                ?? SchemaColumnDescriptor(name: resultColumn.name, type: resultColumn.type, isNullable: true, isPrimaryKey: false, isUnique: false)
            let currentValue = resultMap[resultColumn.name] ?? ""
            return DataEditorField(
                column: schemaColumn,
                value: currentValue,
                originalValue: currentValue,
                isEditable: canUpdateRow && !editableIdentifierColumnNames.contains(normalizedIdentifier(schemaColumn.name))
            )
        }

        dataEditorDraft = DataEditorDraft(mode: canUpdateRow ? .update : .view, table: table, fields: fields, rowID: row.id)
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    func prepareInsert(for table: SchemaTableDescriptor? = nil) {
        guard let targetTable = table ?? currentEditableTable ?? selectedExplorerTable else {
            errorMessage = "Pick a table in Explorer before inserting a row."
            return
        }

        let fields = targetTable.columns.map { column in
            DataEditorField(
                column: column,
                value: "",
                originalValue: nil,
                isEditable: true
            )
        }
        dataEditorDraft = DataEditorDraft(mode: .insert, table: targetTable, fields: fields, rowID: nil)
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    func saveDataEditor() {
        guard let draft = dataEditorDraft,
              let bookmark = selectedBookmark else {
            return
        }

        guard draft.mode != .view else {
            dismissDataEditor()
            return
        }

        let validation = DataEditorValidationService.validate(fields: draft.fields, mode: draft.mode, engine: bookmark.engine)
        guard validation.isEmpty else {
            dataEditorValidation = validation
            dataEditorErrorMessage = "Fix the highlighted fields before saving."
            return
        }

        guard let mutation = mutationSQL(for: draft, engine: bookmark.engine) else {
            dataEditorErrorMessage = "This row cannot be saved because the primary key context is missing."
            return
        }

        isSavingMutation = true
        dataEditorErrorMessage = nil
        Task {
            do {
                _ = try await DatabaseService.shared.execute(
                    query: mutation,
                    profile: bookmark,
                    database: activeDatabaseName
                )
                await MainActor.run {
                    self.result.generatedMutation = mutation
                    self.isSavingMutation = false
                    self.dataEditorDraft = nil
                    self.dataEditorValidation = [:]
                    if self.result.sourceTableReference == nil || self.currentEditableTable?.id != draft.table.id {
                        self.queryText = self.defaultQuery(for: draft.table)
                    }
                    self.runQuery()
                }
            } catch {
                await MainActor.run {
                    self.isSavingMutation = false
                    self.dataEditorErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func dismissDataEditor() {
        dataEditorDraft = nil
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    func createBookmark() {
        selectedProfileForEdit = ConnectionProfile(
            name: "",
            engine: .postgresql,
            iconName: nil,
            host: "",
            port: 5432,
            username: "",
            password: "",
            defaultDatabase: ""
        )
    }

    func saveBookmark(_ profile: ConnectionProfile) {
        bookmarkStore?.upsert(profile)
        selectBookmark(profile.id)
        selectedProfileForEdit = nil
    }

    func selectBookmark(_ id: UUID?) {
        selectedBookmarkID = id
        selectedDatabaseName = bookmarkStore?.bookmark(with: id)?.trimmedDefaultDatabase ?? ""
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        refreshAssist()
        reloadSchema()
    }

    func selectDatabase(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedDatabaseName = trimmed
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        reloadSchema()
    }

    private func inferredTitle(for sql: String) -> String {
        let compact = sql
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(36))
    }

    private func defaultQuery(for table: SchemaTableDescriptor) -> String {
        browseQuery(for: table, whereClause: "", orderByClause: "")
    }

    private func browseQuery(
        for table: SchemaTableDescriptor,
        whereClause: String? = nil,
        orderByClause: String? = nil
    ) -> String {
        let projection = table.columns
            .prefix(6)
            .map(\.name)
            .joined(separator: ", ")
        let selectList = projection.isEmpty ? "*" : projection
        let trimmedWhere = normalizedWhereClause(whereClause ?? explorerWhereClause)
        let trimmedOrder = normalizedOrderByClause(orderByClause ?? explorerOrderByClause)

        var lines = [
            "SELECT \(selectList)",
            "FROM \(table.displayName)"
        ]
        if !trimmedWhere.isEmpty {
            lines.append("WHERE \(trimmedWhere)")
        }
        if !trimmedOrder.isEmpty {
            lines.append("ORDER BY \(trimmedOrder)")
        }
        lines.append("LIMIT \(explorerPageSize)")
        lines.append("OFFSET \(explorerPageIndex * explorerPageSize);")
        return lines.joined(separator: "\n")
    }

    private func normalizedWhereClause(_ clause: String) -> String {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.range(of: #"^\s*WHERE\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.replacingOccurrences(
                of: #"^\s*WHERE\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return trimmed
    }

    private func normalizedOrderByClause(_ clause: String) -> String {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.range(of: #"^\s*ORDER\s+BY\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.replacingOccurrences(
                of: #"^\s*ORDER\s+BY\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if trimmed.range(of: #"^\s*ORDER\s+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed.replacingOccurrences(
                of: #"^\s*ORDER\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return trimmed
    }

    private func shouldReloadSchema(after sql: String) -> Bool {
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["CREATE ", "ALTER ", "DROP ", "TRUNCATE "].contains { normalized.hasPrefix($0) }
    }

    private func mutationSQL(for draft: DataEditorDraft, engine: DatabaseEngine) -> String? {
        switch draft.mode {
        case .view:
            return nil
        case .insert:
            let populatedFields = draft.fields.compactMap { field -> (String, String)? in
                guard let literal = DataEditorValidationService.sqlLiteral(for: field, engine: engine) else {
                    return nil
                }
                return (field.column.name, literal)
            }
            guard !populatedFields.isEmpty else { return nil }
            let columnList = populatedFields.map { $0.0 }.joined(separator: ", ")
            let valueList = populatedFields.map { $0.1 }.joined(separator: ", ")
            return """
            INSERT INTO \(draft.table.displayName) (\(columnList))
            VALUES (\(valueList));
            """
        case .update:
            let identifierColumnNames = Set(draft.table.editingIdentifierColumns.map(\.name).map(normalizedIdentifier))
            let identifierFields = draft.fields.filter {
                identifierColumnNames.contains(normalizedIdentifier($0.column.name))
            }
            guard !identifierFields.isEmpty,
                  identifierFields.allSatisfy({ $0.originalValue?.isEmpty == false }) else {
                return nil
            }
            let assignments = draft.fields
                .filter { $0.isEditable }
                .compactMap { field -> String? in
                    if field.value.trimmingCharacters(in: .whitespacesAndNewlines) == field.originalValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
                        return nil
                    }
                    if field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "\(field.column.name) = NULL"
                    }
                    guard let literal = DataEditorValidationService.sqlLiteral(for: field, engine: engine) else {
                        return nil
                    }
                    return "\(field.column.name) = \(literal)"
                }
            guard !assignments.isEmpty else { return nil }
            let predicates = identifierFields.compactMap { field -> String? in
                guard let originalValue = field.originalValue, !originalValue.isEmpty else { return nil }
                let comparisonField = DataEditorField(
                    column: field.column,
                    value: originalValue,
                    originalValue: originalValue,
                    isEditable: false
                )
                guard let literal = DataEditorValidationService.sqlLiteral(for: comparisonField, engine: engine) else {
                    return nil
                }
                return "\(field.column.name) = \(literal)"
            }
            guard predicates.count == identifierFields.count else { return nil }
            return """
            UPDATE \(draft.table.displayName)
            SET \(assignments.joined(separator: ", "))
            WHERE \(predicates.joined(separator: " AND "));
            """
        }
    }

    private func inferredTableReference(in sql: String) -> String? {
        let normalized = sql.uppercased()
        if normalized.hasPrefix("EXPLAIN "), let explainRange = sql.range(of: "EXPLAIN ", options: .caseInsensitive) {
            let nested = String(sql[explainRange.upperBound...])
            return inferredTableReference(in: nested)
        }
        guard let fromRange = normalized.range(of: "FROM ") ?? normalized.range(of: "UPDATE ") ?? normalized.range(of: "INTO ") else {
            return nil
        }
        let tail = sql[fromRange.upperBound...]
        return tail
            .split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "," || $0 == ")" })
            .first
            .map(String.init)
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
    }

    private func resolveDatabaseSelection(
        requested: String,
        bookmark: ConnectionProfile,
        available: [String]
    ) -> String? {
        let candidates = [
            requested,
            bookmark.trimmedDefaultDatabase
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if available.isEmpty {
            return candidates.first
        }

        if let matchingCandidate = candidates.first(where: { candidate in
            available.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
        }) {
            return available.first(where: { $0.caseInsensitiveCompare(matchingCandidate) == .orderedSame })
        }

        return available.first
    }

    private func resolveFallbackDatabases(for bookmark: ConnectionProfile) -> [String] {
        let current = selectedDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = bookmark.trimmedDefaultDatabase
        return Array(Set([current, fallback].filter { !$0.isEmpty })).sorted()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
