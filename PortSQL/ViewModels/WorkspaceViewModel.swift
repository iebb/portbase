import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var selectedBookmarkID: UUID?
    @Published var selectedDatabaseName = ""
    @Published private(set) var availableDatabases: [String] = []
    @Published var queryText = ""
    @Published var queryCursorOffset = 0
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
    @Published var pendingSafetyConfirmation: PendingSQLExecution?
    @Published var parameterDraft: QueryParameterDraft?
    @Published var parameterErrorMessage: String?
    @Published private(set) var isLoadingSchema = false

    private weak var bookmarkStore: BookmarkStore?
    private weak var libraryStore: WorkspaceLibraryStore?
    private weak var purchaseStore: PurchaseStore?
    private var assistTask: Task<Void, Never>?
    private var schemaLoadToken: UUID?
    private var runToken: UUID?
    private var queryTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var mutationToken: UUID?
    private var activeBoundQuery: BoundQuery?
    private let schemaCacheStore = SchemaCacheStore.shared

    func configure(
        bookmarkStore: BookmarkStore,
        libraryStore: WorkspaceLibraryStore,
        purchaseStore: PurchaseStore
    ) {
        self.bookmarkStore = bookmarkStore
        self.libraryStore = libraryStore
        self.purchaseStore = purchaseStore
        if selectedBookmarkID == nil {
            selectedBookmarkID = bookmarkStore.bookmarks.first?.id
        }
        selectedDatabaseName = selectedBookmark?.trimmedDefaultDatabase ?? ""
        rebuildSchemaSuggestions()
        refreshAssist()
        reloadSchema()
    }

    var selectedBookmark: ConnectionProfile? {
        bookmarkStore?.bookmark(with: selectedBookmarkID)
    }

    var isSchemaCachingEnabled: Bool {
        selectedBookmark?.schemaCachingEnabled == true
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
        guard result.isExplorerGenerated == true,
              let reference = result.sourceTableReference else { return nil }
        return schemaCatalog.first(where: { $0.matches(reference: reference) })
    }

    var canInsertIntoCurrentTable: Bool {
        currentEditableTable != nil
    }

    var canEditCurrentRows: Bool {
        guard let table = currentEditableTable, !result.rows.isEmpty else { return false }
        let normalizedResultColumns = result.columns.map { normalizedIdentifier($0.name) }
        guard Set(normalizedResultColumns).count == normalizedResultColumns.count else { return false }
        let resultColumnNames = Set(normalizedResultColumns)
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
        L10n.format("Page %d", explorerPageIndex + 1)
    }

    var explorerResultRangeLabel: String {
        guard isShowingExplorerResult, !result.rows.isEmpty else { return L10n.text("0 rows") }
        let start = explorerPageIndex * explorerPageSize + 1
        let end = start + result.rows.count - 1
        return "\(start)-\(end)"
    }

    var isExplorerUnlimited: Bool {
        false
    }

    var explorerSortColumn: String? {
        let trimmed = normalizedOrderByClause(explorerOrderByClause)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        return parts.first.map { normalizedIdentifier(String($0)) }
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
        assistTask?.cancel()

        let query = queryText
        let catalog = schemaCatalog
        let activeDatabase = activeDatabaseName
        let cursorOffset = queryCursorOffset

        assistTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }

            let suggestions = SQLAssistService.suggestions(
                for: query,
                catalog: catalog,
                activeDatabase: activeDatabase,
                cursorOffset: cursorOffset
            )
            let hints = SQLAssistService.hints(for: query)

            await MainActor.run {
                guard self.queryText == query, self.queryCursorOffset == cursorOffset else { return }
                self.suggestions = suggestions
                self.hints = hints
            }
        }
    }

    func applySuggestion(_ suggestion: String) {
        let applied = SQLAssistService.applySuggestion(suggestion, to: queryText, cursorOffset: queryCursorOffset)
        queryText = applied.query
        queryCursorOffset = applied.cursorOffset
        refreshAssist()
    }

    func runQuery() {
        let boundValues = activeBoundQuery?.sql == queryText ? activeBoundQuery?.values ?? [] : []
        runChecked(sql: queryText, title: inferredTitle(for: queryText), values: boundValues)
    }

    func runExplain() {
        guard let explainSQL = SQLSafetyService.explainQuery(
            for: queryText,
            engine: selectedBookmark?.engine ?? .postgresql
        ) else {
            errorMessage = L10n.text("Explain is available only for read-only queries.")
            return
        }
        let values = activeBoundQuery?.sql == queryText ? activeBoundQuery?.values ?? [] : []
        run(sql: explainSQL, title: L10n.text("Explain plan"), values: values, policy: .readOnly)
    }

    func formatQuery() {
        queryText = SQLAssistService.format(queryText)
        refreshAssist()
    }

    func refreshSchemaCatalog() {
        reloadSchema(forceRefresh: true)
    }

    func reloadSchema(forceRefresh: Bool = false) {
        guard let bookmark = selectedBookmark else {
            availableDatabases = []
            schemaCatalog = []
            selectedExplorerTableID = nil
            isLoadingSchema = false
            schemaLoadToken = nil
            schemaErrorMessage = nil
            rebuildSchemaSuggestions()
            refreshAssist()
            return
        }

        let currentSelection = selectedDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheLookupDatabase = currentSelection.isEmpty ? bookmark.trimmedDefaultDatabase : currentSelection
        if bookmark.schemaCachingEnabled,
           !forceRefresh,
           !cacheLookupDatabase.isEmpty,
           let cached = schemaCacheStore.cachedCatalog(for: bookmark, requestedDatabase: cacheLookupDatabase),
           cached.isFresh(duration: bookmark.schemaCacheDuration) {
            applySchemaCatalog(
                cached.catalog,
                databases: cached.databases,
                selectedDatabase: cached.selectedDatabase
            )
            return
        }

        let loadToken = UUID()
        schemaLoadToken = loadToken
        isLoadingSchema = true
        schemaErrorMessage = nil
        Task {
            do {
                let databases = try await DatabaseService.shared.listDatabases(profile: bookmark)
                let resolvedDatabase = resolveDatabaseSelection(
                    requested: currentSelection,
                    bookmark: bookmark,
                    available: databases
                )
                if bookmark.schemaCachingEnabled,
                   !forceRefresh,
                   let cacheDatabase = resolvedDatabase,
                   let cached = schemaCacheStore.cachedCatalog(for: bookmark, requestedDatabase: cacheDatabase),
                   cached.isFresh(duration: bookmark.schemaCacheDuration) {
                    await MainActor.run {
                        guard self.schemaLoadToken == loadToken else { return }
                        self.applySchemaCatalog(
                            cached.catalog,
                            databases: cached.databases.isEmpty ? databases : cached.databases,
                            selectedDatabase: cached.selectedDatabase ?? resolvedDatabase
                        )
                    }
                    return
                }

                let catalog = try await DatabaseService.shared.loadSchema(
                    profile: bookmark,
                    database: resolvedDatabase
                )
                if bookmark.schemaCachingEnabled, let cacheDatabase = resolvedDatabase {
                    schemaCacheStore.store(
                        databases: databases,
                        selectedDatabase: resolvedDatabase,
                        catalog: catalog,
                        for: bookmark,
                        requestedDatabase: cacheDatabase
                    )
                }
                await MainActor.run {
                    guard self.schemaLoadToken == loadToken else { return }
                    self.applySchemaCatalog(catalog, databases: databases, selectedDatabase: resolvedDatabase)
                }
            } catch {
                await MainActor.run {
                    guard self.schemaLoadToken == loadToken else { return }
                    self.availableDatabases = self.resolveFallbackDatabases(for: bookmark)
                    self.schemaCatalog = []
                    self.selectedExplorerTableID = nil
                    self.schemaErrorMessage = error.localizedDescription
                    self.isLoadingSchema = false
                    self.rebuildSchemaSuggestions()
                    self.refreshAssist()
                }
            }
        }
    }

    private func applySchemaCatalog(
        _ catalog: [SchemaTableDescriptor],
        databases: [String],
        selectedDatabase: String?
    ) {
        availableDatabases = databases
        selectedDatabaseName = selectedDatabase ?? ""
        schemaCatalog = catalog
        rebuildSchemaSuggestions()

        let activeExplorerTable: SchemaTableDescriptor?
        if let selectedExplorerTableID,
           let existingTable = catalog.first(where: { $0.id == selectedExplorerTableID }) {
            self.selectedExplorerTableID = selectedExplorerTableID
            activeExplorerTable = existingTable
        } else {
            let firstTable = catalog.first
            selectedExplorerTableID = firstTable?.id
            activeExplorerTable = firstTable
        }

        if queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let activeExplorerTable {
            queryText = defaultQuery(for: activeExplorerTable)
        }
        schemaErrorMessage = nil
        isLoadingSchema = false
        schemaLoadToken = nil
        refreshAssist()
        if result.columns.isEmpty,
           errorMessage == nil,
           let activeExplorerTable {
            browse(table: activeExplorerTable)
        }
    }

    func saveSnippet() {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        libraryStore?.saveSnippet(title: inferredTitle(for: trimmed), sql: trimmed)
    }

    func apply(history entry: QueryHistoryEntry) {
        activeBoundQuery = nil
        queryText = entry.sql
        refreshAssist()
    }

    func apply(snippet: SavedQuerySnippet) {
        let parameters = QueryParameterService.parameters(
            in: snippet.sql,
            engine: selectedBookmark?.engine ?? .postgresql
        )
        guard !parameters.isEmpty else {
            activeBoundQuery = nil
            queryText = snippet.sql
            refreshAssist()
            return
        }
        parameterDraft = QueryParameterDraft(
            sourceSQL: snippet.sql,
            values: Dictionary(uniqueKeysWithValues: parameters.map { ($0, "") })
        )
        parameterErrorMessage = nil
    }

    func applyParameters(_ draft: QueryParameterDraft) -> Bool {
        let engine = selectedBookmark?.engine ?? .postgresql
        do {
            let boundQuery = try QueryParameterService.boundQuery(
                sql: draft.sourceSQL,
                values: draft.values,
                nullParameters: draft.nullParameters,
                engine: engine
            )
            queryText = boundQuery.sql
            activeBoundQuery = boundQuery
            parameterDraft = nil
            parameterErrorMessage = nil
            refreshAssist()
            return true
        } catch {
            parameterErrorMessage = error.localizedDescription
            return false
        }
    }

    func cancelParameters() {
        parameterDraft = nil
        parameterErrorMessage = nil
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
            errorMessage = L10n.text("Choose a table before browsing rows.")
            return
        }
        selectedExplorerTableID = targetTable.id
        let sql = browseQuery(for: targetTable)
        activeBoundQuery = nil
        queryText = sql
        refreshAssist()
        run(
            sql: sql,
            title: L10n.format("Browse %@", targetTable.displayName),
            policy: .readOnly,
            explorerTable: targetTable
        )
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
        let boundedSize = [10, 25, 50, 100].contains(size) ? size : 25
        guard explorerPageSize != boundedSize else { return }
        explorerPageSize = boundedSize
        explorerPageIndex = 0
        if selectedExplorerTable != nil {
            browse()
        }
    }

    func sortExplorer(by columnName: String) {
        let normalizedTarget = normalizedIdentifier(columnName)
        let normalizedCurrent = explorerSortColumn.map(normalizedIdentifier)
        let quotedColumn = sqlIdentifier(columnName, engine: selectedBookmark?.engine ?? .postgresql)
        if normalizedCurrent == normalizedTarget {
            explorerOrderByClause = "\(quotedColumn) \(explorerSortDirection == "DESC" ? "ASC" : "DESC")"
        } else {
            explorerOrderByClause = "\(quotedColumn) ASC"
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
        try enforceWritableConnection(bookmark)

        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "PortSQL.Schema", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Column name is required.")])
        }
        guard !trimmedType.isEmpty else {
            throw NSError(domain: "PortSQL.Schema", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("Column type is required.")])
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
            self.reloadSchema(forceRefresh: true)
        }
    }

    func deleteSchemaColumn(_ column: SchemaColumnDescriptor, from table: SchemaTableDescriptor) async throws {
        guard let bookmark = selectedBookmark else {
            throw DatabaseServiceError.notConfigured
        }
        try enforceWritableConnection(bookmark)

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
            self.reloadSchema(forceRefresh: true)
        }
    }

    func deleteHistory(at offsets: IndexSet) {
        libraryStore?.deleteHistory(at: offsets)
    }

    func deleteSnippets(at offsets: IndexSet) {
        libraryStore?.deleteSnippets(at: offsets)
    }

    private func run(
        sql: String,
        title: String,
        values: [QueryBoundValue] = [],
        policy: DatabaseExecutionPolicy = .userQuery(confirmed: false),
        explorerTable: SchemaTableDescriptor? = nil
    ) {
        let currentRunToken = UUID()
        queryTask?.cancel()
        runToken = currentRunToken
        isRunning = true
        errorMessage = nil
        queryTask = Task {
            do {
                var table = try await DatabaseService.shared.execute(
                    query: sql,
                    values: values,
                    profile: selectedBookmark,
                    database: activeDatabaseName,
                    policy: policy
                )
                table.sourceTableReference = explorerTable?.displayName ?? inferredTableReference(in: sql)
                table.isExplorerGenerated = explorerTable != nil
                table.sourceQuery = sql
                await MainActor.run {
                    guard self.runToken == currentRunToken else { return }
                    self.result = table
                    self.queryTask = nil
                    self.isRunning = false
                    self.errorMessage = nil
                    self.libraryStore?.addHistory(
                        title: title,
                        sql: sql,
                        connectionName: self.selectedBookmark?.name ?? L10n.text("Unassigned"),
                        summary: table.executionSummary
                    )
                    if self.shouldReloadSchema(after: sql) {
                        self.reloadSchema(forceRefresh: true)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.runToken == currentRunToken else { return }
                    self.errorMessage = error.localizedDescription
                    self.result = QueryResultTable.empty
                    self.queryTask = nil
                    self.isRunning = false
                }
            }
        }
    }

    private func runChecked(sql: String, title: String, values: [QueryBoundValue] = []) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let assessment = SQLSafetyService.assessment(
            for: trimmed,
            readOnly: selectedBookmark?.isReadOnly == true,
            engine: selectedBookmark?.engine ?? .postgresql
        )
        if let assessment, assessment.blocksExecution {
            errorMessage = assessment.message
            return
        }
        if let assessment, assessment.requiresConfirmation {
            pendingSafetyConfirmation = PendingSQLExecution(
                sql: trimmed,
                title: title,
                values: values,
                assessment: assessment
            )
            return
        }
        run(sql: trimmed, title: title, values: values)
    }

    private func enforceWritableConnection(_ bookmark: ConnectionProfile) throws {
        guard !bookmark.isReadOnly else {
            throw NSError(
                domain: "PortSQL.Safety",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text("This server is read-only. Disable read-only mode before making changes.")]
            )
        }
    }

    func runPendingSafetyConfirmation() {
        guard let pendingSafetyConfirmation else { return }
        self.pendingSafetyConfirmation = nil
        run(
            sql: pendingSafetyConfirmation.sql,
            title: pendingSafetyConfirmation.title,
            values: pendingSafetyConfirmation.values,
            policy: .userQuery(confirmed: true)
        )
    }

    func cancelPendingSafetyConfirmation() {
        pendingSafetyConfirmation = nil
    }

    func exportResultURL(format: QueryResultExportFormat) -> URL? {
        QueryResultExportService.write(result, format: format)
    }

    private func rebuildSchemaSuggestions() {
        if schemaCatalog.isEmpty {
            schema = []
            return
        }

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

    func prepareEdit(row: QueryRow) {
        let resultColumnNames = result.columns.map(\.name)
        let table = currentEditableTable ?? SchemaTableDescriptor(
            schemaName: "",
            name: inferredTableReference(in: queryText) ?? L10n.text("Result Row"),
            columns: result.columns.map {
                SchemaColumnDescriptor(name: $0.name, type: $0.type, isNullable: true, isPrimaryKey: false, isUnique: false)
            },
            rowCountEstimate: nil
        )

        let normalizedNames = resultColumnNames.map(normalizedIdentifier)
        let hasDuplicateColumns = Set(normalizedNames).count != normalizedNames.count
        var resultNormalized: [String: QueryCell] = [:]
        if !hasDuplicateColumns {
            for (index, name) in normalizedNames.enumerated() {
                resultNormalized[name] = row.cells[safe: index] ?? .null
            }
        }
        let editableIdentifierColumnNames = Set(
            (currentEditableTable?.editingIdentifierColumns ?? [])
                .map(\.name)
                .map(normalizedIdentifier)
        )
        let canUpdateRow = currentEditableTable.map { editableTable in
            let identifiers = editableTable.editingIdentifierColumns
            return !hasDuplicateColumns && !identifiers.isEmpty
                && identifiers.allSatisfy { resultNormalized[normalizedIdentifier($0.name)] != nil }
        } ?? false

        let fields = result.columns.enumerated().map { index, resultColumn -> DataEditorField in
            let schemaColumn = currentEditableTable?.column(named: resultColumn.name)
                ?? SchemaColumnDescriptor(name: resultColumn.name, type: resultColumn.type, isNullable: true, isPrimaryKey: false, isUnique: false)
            let currentCell = row.cells[safe: index] ?? .null
            let currentValue = currentCell.displayValue
            return DataEditorField(
                column: schemaColumn,
                value: currentValue,
                originalValue: currentValue,
                isNull: currentCell.isNull,
                originalIsNull: currentCell.isNull,
                isEditable: selectedBookmark?.isReadOnly != true
                    && canUpdateRow
                    && !currentCell.isBinary
                    && !Self.isUnsupportedBinaryColumn(schemaColumn)
                    && !editableIdentifierColumnNames.contains(normalizedIdentifier(schemaColumn.name))
            )
        }

        dataEditorDraft = DataEditorDraft(mode: selectedBookmark?.isReadOnly == true ? .view : (canUpdateRow ? .update : .view), table: table, fields: fields, rowID: row.id)
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    func prepareInsert(for table: SchemaTableDescriptor? = nil) {
        if selectedBookmark?.isReadOnly == true {
            errorMessage = L10n.text("This server is read-only. Disable read-only mode before inserting rows.")
            return
        }
        guard let targetTable = table ?? currentEditableTable ?? selectedExplorerTable else {
            errorMessage = L10n.text("Pick a table in Explorer before inserting a row.")
            return
        }

        let fields = targetTable.columns.map { column in
            DataEditorField(
                column: column,
                value: "",
                originalValue: nil,
                isEditable: !Self.isUnsupportedBinaryColumn(column)
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
        do {
            try enforceWritableConnection(bookmark)
        } catch {
            dataEditorErrorMessage = error.localizedDescription
            return
        }

        guard draft.mode != .view else {
            dismissDataEditor()
            return
        }

        let validation = DataEditorValidationService.validate(fields: draft.fields, mode: draft.mode, engine: bookmark.engine)
        guard validation.isEmpty else {
            dataEditorValidation = validation
            dataEditorErrorMessage = L10n.text("Fix the highlighted fields before saving.")
            return
        }

        guard let mutation = mutationSQL(for: draft, engine: bookmark.engine) else {
            dataEditorErrorMessage = L10n.text("This row cannot be saved because the primary key context is missing.")
            return
        }

        isSavingMutation = true
        dataEditorErrorMessage = nil
        mutationTask?.cancel()
        let token = UUID()
        mutationToken = token
        let databaseName = activeDatabaseName
        let table = draft.table
        mutationTask = Task {
            do {
                _ = try await DatabaseService.shared.execute(
                    query: mutation.sql,
                    values: mutation.values,
                    profile: bookmark,
                    database: databaseName,
                    policy: .mutation(expectedAffectedRows: 1)
                )
                await MainActor.run {
                    guard self.mutationToken == token else { return }
                    self.mutationToken = nil
                    self.mutationTask = nil
                    self.result.generatedMutation = mutation.sql
                    self.isSavingMutation = false
                    self.dataEditorDraft = nil
                    self.dataEditorValidation = [:]
                    if self.result.sourceTableReference == nil || self.currentEditableTable?.id != table.id {
                        self.queryText = self.defaultQuery(for: table)
                    }
                    self.runQuery()
                }
            } catch {
                await MainActor.run {
                    guard self.mutationToken == token else { return }
                    self.mutationToken = nil
                    self.mutationTask = nil
                    self.isSavingMutation = false
                    self.dataEditorErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func dismissDataEditor() {
        mutationTask?.cancel()
        mutationTask = nil
        mutationToken = nil
        isSavingMutation = false
        dataEditorDraft = nil
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    func createBookmark() {
        let bookmarkCount = bookmarkStore?.bookmarks.count ?? 0
        guard PremiumPolicy.canCreateBookmark(
            existingCount: bookmarkCount,
            hasPro: purchaseStore?.hasPro == true
        ) else {
            purchaseStore?.presentPaywall(for: .unlimitedBookmarks)
            return
        }
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
        cancelMutation()
        queryTask?.cancel()
        queryTask = nil
        selectedBookmarkID = id
        selectedDatabaseName = bookmarkStore?.bookmark(with: id)?.trimmedDefaultDatabase ?? ""
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        runToken = nil
        isRunning = false
        schemaCatalog = []
        selectedExplorerTableID = nil
        rebuildSchemaSuggestions()
        refreshAssist()
        reloadSchema()
    }

    func selectDatabase(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelMutation()
        queryTask?.cancel()
        queryTask = nil
        selectedDatabaseName = trimmed
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        runToken = nil
        isRunning = false
        schemaCatalog = []
        selectedExplorerTableID = nil
        rebuildSchemaSuggestions()
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
            .map { sqlIdentifier($0.name, engine: selectedBookmark?.engine ?? .postgresql) }
            .joined(separator: ", ")
        let selectList = projection.isEmpty ? "*" : projection
        let trimmedWhere = normalizedWhereClause(whereClause ?? explorerWhereClause)
        let trimmedOrder = normalizedOrderByClause(orderByClause ?? explorerOrderByClause)

        var lines = [
            "SELECT \(selectList)",
            "FROM \(sqlQualifiedTable(table, engine: selectedBookmark?.engine ?? .postgresql))"
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

    private func mutationSQL(for draft: DataEditorDraft, engine: DatabaseEngine) -> BoundQuery? {
        var values: [QueryBoundValue] = []
        func bind(_ value: QueryBoundValue) -> String {
            values.append(value)
            return engine == .postgresql ? "$\(values.count)" : "?"
        }
        let tableName = sqlQualifiedTable(draft.table, engine: engine)

        switch draft.mode {
        case .view:
            return nil
        case .insert:
            let populatedFields = draft.fields.filter(\.isEditable).compactMap { field -> (String, QueryBoundValue)? in
                if field.column.isPrimaryKey,
                   field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !field.isNull {
                    return nil
                }
                guard let value = DataEditorValidationService.boundValue(for: field) else { return nil }
                return (field.column.name, value)
            }
            guard !populatedFields.isEmpty else { return nil }
            let columnList = populatedFields.map { sqlIdentifier($0.0, engine: engine) }.joined(separator: ", ")
            let valueList = populatedFields.map { bind($0.1) }.joined(separator: ", ")
            let sql = """
            INSERT INTO \(tableName) (\(columnList))
            VALUES (\(valueList));
            """
            return BoundQuery(sql: sql, values: values)
        case .update:
            let identifierColumnNames = Set(draft.table.editingIdentifierColumns.map(\.name).map(normalizedIdentifier))
            let identifierFields = draft.fields.filter {
                identifierColumnNames.contains(normalizedIdentifier($0.column.name))
            }
            guard !identifierFields.isEmpty,
                  identifierFields.allSatisfy({ $0.originalIsNull != true && $0.originalValue != nil }) else {
                return nil
            }
            let changedFields = draft.fields.filter { field in
                guard field.isEditable else { return false }
                let current = field.value
                let original = field.originalValue ?? ""
                let currentIsNull = field.isNull
                let originalIsNull = field.originalIsNull ?? original.isEmpty
                return currentIsNull != originalIsNull || (!currentIsNull && current != original)
            }
            let assignments = draft.fields
                .filter { changedFields.contains($0) }
                .compactMap { field -> String? in
                    let columnName = sqlIdentifier(field.column.name, engine: engine)
                    if field.isNull {
                        return "\(columnName) = NULL"
                    }
                    guard let value = DataEditorValidationService.boundValue(for: field) else {
                        return nil
                    }
                    return "\(columnName) = \(bind(value))"
                }
            guard !assignments.isEmpty else { return nil }
            var predicates = identifierFields.compactMap { field -> String? in
                guard let originalValue = field.originalValue else { return nil }
                let comparisonField = DataEditorField(
                    column: field.column,
                    value: originalValue,
                    originalValue: originalValue,
                    isEditable: false
                )
                guard let value = DataEditorValidationService.boundValue(for: comparisonField) else {
                    return nil
                }
                return "\(sqlIdentifier(field.column.name, engine: engine)) = \(bind(value))"
            }
            guard predicates.count == identifierFields.count else { return nil }
            predicates.append(contentsOf: changedFields.compactMap { field -> String? in
                let columnName = sqlIdentifier(field.column.name, engine: engine)
                if field.originalIsNull == true {
                    return "\(columnName) IS NULL"
                }
                guard let originalValue = field.originalValue else { return nil }
                let comparisonField = DataEditorField(
                    column: field.column,
                    value: originalValue,
                    originalValue: originalValue,
                    isEditable: false
                )
                guard let value = DataEditorValidationService.boundValue(for: comparisonField) else { return nil }
                return "\(columnName) = \(bind(value))"
            })
            let sql = """
            UPDATE \(tableName)
            SET \(assignments.joined(separator: ", "))
            WHERE \(predicates.joined(separator: " AND "));
            """
            return BoundQuery(sql: sql, values: values)
        }
    }

    private func sqlQualifiedTable(_ table: SchemaTableDescriptor, engine: DatabaseEngine) -> String {
        let tableName = sqlIdentifier(table.name, engine: engine)
        guard !table.schemaName.isEmpty else { return tableName }
        return "\(sqlIdentifier(table.schemaName, engine: engine)).\(tableName)"
    }

    private func sqlIdentifier(_ value: String, engine: DatabaseEngine) -> String {
        switch engine {
        case .mysql:
            return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql:
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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

    private func cancelMutation() {
        mutationTask?.cancel()
        mutationTask = nil
        mutationToken = nil
        isSavingMutation = false
        dataEditorDraft = nil
    }

    nonisolated static func isUnsupportedBinaryColumn(_ column: SchemaColumnDescriptor) -> Bool {
        let type = column.type.lowercased()
        return ["bytea", "blob", "binary", "varbinary", "geometry"].contains { type.contains($0) }
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

struct PendingSQLExecution: Identifiable, Hashable {
    let id = UUID()
    let sql: String
    let title: String
    let values: [QueryBoundValue]
    let assessment: SQLSafetyAssessment
}
