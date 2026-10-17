import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var selectedBookmarkID: UUID?
    @Published var selectedDatabaseName = ""
    @Published private(set) var availableDatabases: [String] = []
    @Published var queryText = "" {
        didSet { querySelectionLength = 0; queryErrorRange = nil }
    }
    @Published var queryErrorRange: NSRange?
    @Published var manualCommit = false
    @Published private(set) var hasOpenTransaction = false
    private(set) var consoleSessionID = UUID()
    @Published var queryCursorOffset = 0
    @Published var querySelectionLength = 0
    @Published var mongoDraft = MongoQueryDraft()
    @Published var explorerWhereClause = ""
    @Published var explorerOrderByClause = ""
    @Published private(set) var explorerPageIndex = 0
    @Published private(set) var explorerPageSize = 25
    @Published var suggestions: [String] = []
    @Published var hints: [EditorHint] = []
    @Published var schema: [SchemaSuggestion] = []
    @Published var schemaCatalog: [SchemaTableDescriptor] = []
    @Published private(set) var foreignKeys: [SchemaForeignKey] = []
    private var relationshipTask: Task<Void, Never>?
    @Published var result = QueryResultTable.empty
    @Published private(set) var resultSets: [QueryResultTable] = []
    @Published private(set) var selectedResultIndex = 0
    @Published var selectedProfileForEdit: ConnectionProfile?
    @Published var isRunning = false
    @Published var errorMessage: String? {
        didSet { offerCertificateTrustIfNeeded(for: errorMessage) }
    }
    @Published var schemaErrorMessage: String? {
        didSet { offerCertificateTrustIfNeeded(for: schemaErrorMessage) }
    }
    /// A server CA awaiting the user's decision to trust it for a connection.
    @Published var certificateTrustRequest: CertificateTrustRequest?
    /// Why a requested certificate review couldn't show a CA to trust.
    @Published var certificateReviewError: String?
    var certificateProbeTask: Task<Void, Never>?
    /// CAs the user declined, by connection and fingerprint, so they aren't offered again this session.
    var declinedCertificateAuthorities: Set<String> = []
    @Published var dataEditorDraft: DataEditorDraft?
    @Published var dataEditorValidation: [UUID: String] = [:]
    @Published var dataEditorErrorMessage: String?
    @Published var isSavingMutation = false
    @Published var selectedExplorerTableID: UUID?
    @Published var pendingSafetyConfirmation: PendingSQLExecution?
    @Published var parameterDraft: QueryParameterDraft?
    @Published var parameterErrorMessage: String?
    @Published private(set) var isLoadingSchema = false
    /// The most recent console execution, used for run status displays.
    @Published private(set) var lastExecution: QueryHistoryEntry?

    private(set) weak var bookmarkStore: BookmarkStore?
    private weak var libraryStore: WorkspaceLibraryStore?
    private var assistTask: Task<Void, Never>?
    private var schemaLoadToken: UUID?
    private var runToken: UUID?
    private var queryTask: Task<Void, Never>?
    private var cancellationWriteWarning: String?
    private var executionHistory: (token: UUID, entry: QueryHistoryEntry, started: TimeInterval)?
    private var mutationTask: Task<Void, Never>?
    private var mutationToken: UUID?
    var activeBoundQuery: BoundQuery?
    private var engineDrafts: [DatabaseEngine: (query: String, filter: String, sort: String)] = [:]
    private let schemaCacheStore = SchemaCacheStore.shared

    func configure(
        bookmarkStore: BookmarkStore,
        libraryStore: WorkspaceLibraryStore
    ) {
        guard self.bookmarkStore == nil else { return }
        self.bookmarkStore = bookmarkStore
        self.libraryStore = libraryStore
        if selectedBookmarkID == nil {
            selectedBookmarkID = bookmarkStore.bookmarks.first?.id
        }
        if selectedDatabaseName.isEmpty { selectedDatabaseName = selectedBookmark?.trimmedDefaultDatabase ?? "" }
        rebuildSchemaSuggestions()
        refreshAssist()
        reloadSchema()
    }

    var selectedBookmark: ConnectionProfile? {
        bookmarkStore?.bookmark(with: selectedBookmarkID)
    }

    var isDocumentDatabase: Bool { selectedBookmark?.engine == .mongodb }
    var isSQLDatabase: Bool { selectedBookmark?.engine.isSQL ?? true }
    var usesJSONEditor: Bool { selectedBookmark?.engine.usesJSONEditor == true }
    var editorPlaceholder: String { selectedBookmark?.engine.queryPlaceholder ?? L10n.text("SQL query") }

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
        guard selectedBookmark?.engine.supportsRowEditing == true, result.isExplorerGenerated == true,
              let reference = result.sourceTableReference else { return nil }
        return schemaCatalog.first(where: { $0.matches(reference: reference) && ($0.objectKind == nil || $0.objectKind == .table) })
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
        if isDocumentDatabase { return (try? MongoQueryService.jsonObject(explorerOrderByClause))?.keys.first }
        let trimmed = normalizedOrderByClause(explorerOrderByClause)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        return parts.first.map { normalizedIdentifier(String($0)) }
    }

    var explorerSortDirection: String? {
        if isDocumentDatabase {
            guard let sort = try? MongoQueryService.jsonObject(explorerOrderByClause), let key = sort.keys.first else { return nil }
            return sort[key]?.toInt() == -1 ? "DESC" : "ASC"
        }
        let trimmed = normalizedOrderByClause(explorerOrderByClause)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return "ASC" }
        let last = String(parts[1]).uppercased()
        return ["ASC", "DESC"].contains(last) ? last : "ASC"
    }

    func refreshAssist() {
        assistTask?.cancel()
        if !isSQLDatabase {
            suggestions = []
            hints = []
            return
        }

        let query = queryText
        let catalog = schemaCatalog
        let activeDatabase = activeDatabaseName
        let cursorOffset = queryCursorOffset
        let engine = selectedBookmark?.engine ?? .postgresql

        assistTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }

            let suggestions = SQLAssistService.suggestions(
                for: query,
                catalog: catalog,
                activeDatabase: activeDatabase,
                cursorOffset: cursorOffset,
                engine: engine
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

    var hasQuerySelection: Bool {
        isSQLDatabase && SQLEditingService.selection(in: queryText, offset: queryCursorOffset, length: querySelectionLength) != nil
    }

    var editorPositionLabel: String {
        let offset = SQLEditingService.characterOffset(in: queryText, utf16Offset: queryCursorOffset)
        let lines = queryText.prefix(offset).split(separator: "\n", omittingEmptySubsequences: false)
        return L10n.format("Ln %d, Col %d", lines.count, (lines.last?.count ?? 0) + 1)
    }

    private var selectedQuery: String {
        guard isSQLDatabase,
              let range = SQLEditingService.selection(in: queryText, offset: queryCursorOffset, length: querySelectionLength) else {
            guard isSQLDatabase, let range = SQLEditingService.statement(in: queryText, atUTF16: queryCursorOffset, engine: selectedBookmark?.engine ?? .postgresql) else { return queryText }
            return String(queryText[range])
        }
        return String(queryText[range])
    }

    func runQuery(entireBuffer: Bool = false) {
        guard !isRunning else { return }
        let sql = entireBuffer ? queryText : selectedQuery
        if activeBoundQuery?.sql != queryText {
            let names = QueryParameterService.parameters(in: sql, engine: selectedBookmark?.engine ?? .postgresql)
            if !names.isEmpty {
                parameterDraft = QueryParameterDraft(sourceSQL: sql, values: Dictionary(uniqueKeysWithValues: names.map { ($0, "") }))
                return
            }
        }
        guard let values = boundValues(for: sql) else { return }
        runChecked(sql: sql, title: inferredTitle(for: sql), values: values)
    }

    private func boundValues(for sql: String) -> [QueryBoundValue]? {
        guard let bound = activeBoundQuery, bound.sql == queryText, !bound.values.isEmpty else { return [] }
        guard sql == queryText else {
            errorMessage = L10n.text("Run the complete parameterized query to preserve its bound values.")
            return nil
        }
        return bound.values
    }

    func runExplain() {
        let sql = selectedQuery
        guard let values = boundValues(for: sql) else { return }
        guard let explainSQL = SQLSafetyService.explainQuery(
            for: sql, engine: selectedBookmark?.engine ?? .postgresql
        ) else {
            errorMessage = L10n.text("Explain is available only for read-only queries.")
            return
        }
        run(sql: explainSQL, title: L10n.text("Explain plan"), values: values, policy: .readOnly)
    }

    func formatQuery() {
        let original = queryText
        if isDocumentDatabase {
            do { queryText = MongoQueryService.pretty(try MongoQueryService.parse(queryText).command) }
            catch { errorMessage = DatabaseErrorFormatter.message(for: error) }
            return
        }
        if selectedBookmark?.engine == .elasticsearch {
            do { queryText = try ElasticsearchQueryService.parse(queryText).preview }
            catch { errorMessage = DatabaseErrorFormatter.message(for: error) }
            return
        }
        guard isSQLDatabase else { return }
        let range = SQLEditingService.selection(in: queryText, offset: queryCursorOffset, length: querySelectionLength)
        let formatted = SQLAssistService.format(range.map { String(queryText[$0]) } ?? queryText, engine: selectedBookmark?.engine ?? .postgresql)
        if let range {
            let offset = queryText[..<range.lowerBound].utf16.count
            queryText.replaceSubrange(range, with: formatted)
            queryCursorOffset = offset
            querySelectionLength = formatted.utf16.count
        } else { queryText = formatted }
        if let bound = activeBoundQuery, bound.sql == original {
            activeBoundQuery = BoundQuery(sql: queryText, values: bound.values, sourceSQL: bound.sourceSQL)
        }
        refreshAssist()
    }

    func runMongoBuilder(explain: Bool = false) throws {
        let command = try mongoDraft.command(fallbackCollection: selectedExplorerTable?.name)
        activeBoundQuery = nil
        queryText = command
        if explain {
            guard let explained = MongoQueryService.explain(command) else { throw DatabaseServiceError.readOnlyQueryRequired }
            run(sql: explained, title: L10n.text("Explain plan"), policy: .readOnly)
        } else {
            let parsed = try MongoQueryService.parse(command)
            let findName = parsed.command["find"]?.stringValue
            let projection = try MongoQueryService.jsonObject(mongoDraft.projection)
            let table = projection.isEmpty && selectedExplorerTable?.name == findName ? selectedExplorerTable : nil
            run(sql: command, title: inferredTitle(for: command), policy: .readOnly, explorerTable: table)
        }
    }

    func editMongoCommand(_ command: String) {
        activeBoundQuery = nil
        queryText = command
        mongoDraft.mode = .command
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
                    self.schemaErrorMessage = DatabaseErrorFormatter.message(for: error)
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
        let previousTableName = selectedExplorerTable?.displayName
        schemaCatalog = catalog
        rebuildSchemaSuggestions()

        let activeExplorerTable: SchemaTableDescriptor?
        if let existingTable = catalog.first(where: { $0.displayName == previousTableName }) {
            self.selectedExplorerTableID = existingTable.id
            activeExplorerTable = existingTable
        } else {
            let firstTable = catalog.first
            selectedExplorerTableID = firstTable?.id
            activeExplorerTable = firstTable
        }

        let hadQuery = !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hadQuery, let activeExplorerTable {
            queryText = defaultQuery(for: activeExplorerTable)
        }
        schemaErrorMessage = nil
        isLoadingSchema = false
        schemaLoadToken = nil
        refreshAssist()
        if !hadQuery, result.columns.isEmpty,
           errorMessage == nil,
           let activeExplorerTable {
            browse(table: activeExplorerTable)
        }
    }

    func saveSnippet() {
        let source = activeBoundQuery?.sql == queryText ? (activeBoundQuery?.sourceSQL ?? queryText) : queryText
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        libraryStore?.saveSnippet(title: inferredTitle(for: trimmed), sql: trimmed,
                                  bookmarkID: selectedBookmark?.id, database: activeDatabaseName, engine: selectedBookmark?.engine)
    }

    @discardableResult
    func apply(history entry: QueryHistoryEntry) -> Bool {
        guard restoreQueryContext(bookmarkID: entry.bookmarkID, database: entry.database, engine: entry.engine) else { return false }
        activeBoundQuery = nil
        queryText = entry.sql
        queryCursorOffset = 0
        if usesJSONEditor { mongoDraft.mode = .command }
        refreshAssist()
        return true
    }

    @discardableResult
    func apply(snippet: SavedQuerySnippet) -> Bool {
        guard restoreQueryContext(bookmarkID: snippet.bookmarkID, database: snippet.database, engine: snippet.engine) else { return false }
        if usesJSONEditor { mongoDraft.mode = .command }
        let parameters = QueryParameterService.parameters(
            in: snippet.sql,
            engine: selectedBookmark?.engine ?? .postgresql
        )
        guard !parameters.isEmpty else {
            activeBoundQuery = nil
            queryText = snippet.sql
            queryCursorOffset = 0
            refreshAssist()
            return true
        }
        parameterDraft = QueryParameterDraft(
            sourceSQL: snippet.sql,
            values: Dictionary(uniqueKeysWithValues: parameters.map { ($0, "") })
        )
        parameterErrorMessage = nil
        return true
    }

    private func restoreQueryContext(bookmarkID: UUID?, database: String?, engine: DatabaseEngine?) -> Bool {
        guard !isRunning else { return false }
        if let bookmarkID {
            guard let profile = bookmarkStore?.bookmarks.first(where: { $0.id == bookmarkID }),
                  engine == nil || profile.engine == engine else {
                errorMessage = L10n.text("The saved connection is unavailable or its database engine changed.")
                return false
            }
            let changesContext = profile.id != selectedBookmark?.id || (database != nil && database != activeDatabaseName)
            guard !changesContext || !hasOpenTransaction else {
                errorMessage = ConsoleSessionError.pendingTransaction.localizedDescription
                return false
            }
            if profile.id != selectedBookmark?.id { selectBookmark(profile.id) }
            if let database, !database.isEmpty, database != activeDatabaseName { selectDatabase(database) }
        } else if let engine, engine != selectedBookmark?.engine {
            errorMessage = L10n.text("Choose a connection with the same database engine before opening this query.")
            return false
        }
        errorMessage = nil
        return true
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
        if isDocumentDatabase {
            mongoDraft.collection = table.name
            mongoDraft.mode = .find
            mongoDraft.filter = explorerWhereClause.isEmpty ? "{}" : explorerWhereClause
            mongoDraft.projection = "{}"
            mongoDraft.sort = explorerOrderByClause.isEmpty ? #"{"_id": 1}"# : explorerOrderByClause
            mongoDraft.skip = "0"
            mongoDraft.limit = String(explorerPageSize)
        }
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
        let sql: String
        do {
            sql = isDocumentDatabase ? try MongoQueryService.browse(collection: targetTable.name, filter: explorerWhereClause,
                sort: explorerOrderByClause, limit: explorerPageSize, skip: explorerPageIndex * explorerPageSize) : browseQuery(for: targetTable)
        } catch {
            errorMessage = DatabaseErrorFormatter.message(for: error)
            return
        }
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
        if let table = selectedExplorerTable {
            // Applied clauses join the table's filter and sort history.
            let scope = ClauseHistoryStore.scope(profileID: selectedBookmarkID, database: activeDatabaseName, table: table.displayName)
            ClauseHistoryStore.shared.record(explorerWhereClause, kind: .filter, in: scope)
            ClauseHistoryStore.shared.record(explorerOrderByClause, kind: .sort, in: scope)
        }
        browse()
    }

    var clauseHistoryScope: String? {
        selectedExplorerTable.map { ClauseHistoryStore.scope(profileID: selectedBookmarkID, database: activeDatabaseName, table: $0.displayName) }
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
        if isDocumentDatabase {
            let descending = explorerSortColumn == columnName && explorerSortDirection != "DESC"
            explorerOrderByClause = MongoQueryService.pretty([columnName: descending ? -1 : 1])
            explorerPageIndex = 0
            browse()
            return
        }
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
        guard !isRunning else { return }
        let currentRunToken = UUID()
        queryTask?.cancel()
        runToken = currentRunToken
        isRunning = true
        errorMessage = nil
        let profile = selectedBookmark
        let historySQL = activeBoundQuery?.sql == sql ? (activeBoundQuery?.sourceSQL ?? sql) : sql
        executionHistory = (currentRunToken, QueryHistoryEntry(
            title: title, sql: historySQL,
            connectionName: profile.map { $0.name.isEmpty ? $0.host : $0.name } ?? L10n.text("Unassigned"),
            summary: "", bookmarkID: profile?.id, database: activeDatabaseName, engine: profile?.engine
        ), ProcessInfo.processInfo.systemUptime)
        cancellationWriteWarning = nil
        if let profile, !policy.requiresReadOnlySession, !SQLSafetyService.isReadOnlySQL(sql, engine: profile.engine) {
            if profile.engine == .redis {
                cancellationWriteWarning = RedisClientError.writeOutcomeUnknown.localizedDescription
            } else if profile.engine == .clickhouse || profile.engine == .elasticsearch {
                cancellationWriteWarning = HTTPDatabaseError.unconfirmedWrite.localizedDescription
            }
        }
        let database = activeDatabaseName
        let capturedQuery = queryText
        let currentRange = SQLEditingService.statement(in: queryText, atUTF16: queryCursorOffset, engine: profile?.engine ?? .postgresql)
        let executionOffset = currentRange.flatMap { String(queryText[$0]).trimmingCharacters(in: .whitespacesAndNewlines) == sql ? NSRange($0, in: queryText).location : nil }
            ?? (queryText as NSString).range(of: sql).location
        let usesConsole = explorerTable == nil && !policy.requiresReadOnlySession && profile?.engine.supportsConsoleTransactions == true
        let manual = manualCommit
        let sessionID = consoleSessionID
        queryErrorRange = nil
        queryTask = Task {
            var failureSQL = sql
            var failureOffset = executionOffset
            var completed: [QueryResultTable] = []
            do {
                let ranges = SQLEditingService.statementRanges(in: sql, engine: profile?.engine ?? .postgresql)
                if ranges.count > 1, !values.isEmpty {
                    throw NSError(domain: "PortSQL.Parameters", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Run parameterized statements individually.")])
                }
                let statements = ranges.isEmpty ? [sql] : ranges.map { String(sql[$0]) }
                for (index, statement) in statements.enumerated() {
                    try Task.checkCancellation()
                    failureSQL = statement
                    failureOffset = executionOffset == NSNotFound ? NSNotFound : executionOffset + (ranges.indices.contains(index) ? NSRange(ranges[index], in: sql).location : 0)
                    var table = try await DatabaseService.shared.execute(
                        query: statement, values: values, profile: profile, database: database, policy: policy,
                        sessionID: usesConsole ? sessionID : nil, manualCommit: manual
                    )
                    table.sourceTableReference = explorerTable?.displayName ?? inferredTableReference(in: statement)
                    table.isExplorerGenerated = explorerTable != nil
                    table.sourceQuery = statement
                    completed.append(table)
                }
                let table = completed.last ?? .empty
                let transactionOpen = await DatabaseService.shared.consoleHasTransaction(sessionID)
                await MainActor.run {
                    guard self.runToken == currentRunToken else { return }
                    self.result = table
                    self.resultSets = completed
                    self.selectedResultIndex = max(0, completed.count - 1)
                    self.hasOpenTransaction = transactionOpen
                    self.loadRelationships(for: explorerTable, profile: profile, database: database)
                    self.queryTask = nil
                    self.cancellationWriteWarning = nil
                    self.isRunning = false
                    self.errorMessage = nil
                    self.finishExecutionHistory(token: currentRunToken, outcome: .succeeded, summary: table.executionSummary)
                    if self.shouldReloadSchema(after: sql) {
                        self.reloadSchema(forceRefresh: true)
                    }
                }
            } catch {
                let transactionOpen = await DatabaseService.shared.consoleHasTransaction(sessionID)
                await MainActor.run {
                    guard self.runToken == currentRunToken else { return }
                    self.errorMessage = SQLQueryDiagnostic.message(for: error)
                    self.finishExecutionHistory(token: currentRunToken, outcome: error is CancellationError ? .cancelled : .failed,
                                                summary: self.errorMessage ?? L10n.text("Failed"))
                    if usesConsole { self.hasOpenTransaction = transactionOpen }
                    if self.queryText == capturedQuery, failureOffset != NSNotFound,
                       let range = SQLQueryDiagnostic.range(for: error, sql: failureSQL) {
                        self.queryErrorRange = NSRange(location: failureOffset + range.location, length: range.length)
                        self.queryCursorOffset = failureOffset + range.location
                        self.querySelectionLength = range.length
                    }
                    self.resultSets = completed
                    self.selectedResultIndex = max(0, completed.count - 1)
                    self.result = completed.last ?? .empty
                    self.queryTask = nil
                    self.cancellationWriteWarning = nil
                    self.isRunning = false
                }
            }
        }
    }

    func selectResult(_ index: Int) {
        guard resultSets.indices.contains(index) else { return }
        selectedResultIndex = index
        result = resultSets[index]
        foreignKeys = []
    }

    private func loadRelationships(for table: SchemaTableDescriptor?, profile: ConnectionProfile?, database: String?) {
        relationshipTask?.cancel()
        foreignKeys = []
        guard let table, let profile, profile.engine.isRelational else { return }
        let expectedResult = result.sourceQuery
        relationshipTask = Task {
            do {
                let keys = try await DatabaseService.shared.schemaForeignKeys(table: table, profile: profile, database: database)
                guard !Task.isCancelled, result.sourceQuery == expectedResult else { return }
                foreignKeys = keys
            } catch { /* Data browsing stays available when metadata privileges are limited. */ }
        }
    }

    func followForeignKey(_ key: SchemaForeignKey, row: QueryRow) {
        guard let profile = selectedBookmark, profile.engine.isRelational,
              !key.columns.isEmpty, key.columns.count == key.referencedColumns.count else { return }
        var values: [QueryBoundValue] = []
        for column in key.columns {
            guard let index = result.columns.firstIndex(where: { $0.name == column }), row.cells.indices.contains(index) else { return }
            switch row.cells[index] {
            case .text(let value), .dateTime(let value): values.append(.string(value))
            case .integer(let value):
                if let integer = Int64(value) { values.append(.integer(integer)) } else { values.append(.decimal(value)) }
            case .decimal(let value): values.append(.decimal(value))
            case .boolean(let value): values.append(.boolean(value))
            default: errorMessage = L10n.text("This reference has a NULL or unsupported key value."); return
            }
        }
        let target = schemaCatalog.first { $0.schemaName == key.referencedSchema && $0.name == key.referencedTable }
            ?? SchemaTableDescriptor(schemaName: key.referencedSchema, name: key.referencedTable, columns: [], rowCountEstimate: nil)
        let clauses = key.referencedColumns.enumerated().map { index, column in
            sqlIdentifier(column, engine: profile.engine) + " = " + (profile.engine == .postgresql ? "$\(index + 1)" : "?")
        }
        let sql = "SELECT * FROM " + sqlQualifiedTable(target, engine: profile.engine) + " WHERE " + clauses.joined(separator: " AND ") + " LIMIT 100;"
        queryText = sql
        activeBoundQuery = BoundQuery(sql: sql, values: values)
        selectedExplorerTableID = target.id
        run(sql: sql, title: target.displayName, values: values, policy: .readOnly, explorerTable: target)
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

    func cancelQuery() {
        if let token = runToken {
            finishExecutionHistory(token: token, outcome: .cancelled, summary: cancellationWriteWarning ?? L10n.text("Cancelled"))
        }
        if let cancellationWriteWarning { errorMessage = cancellationWriteWarning }
        cancellationWriteWarning = nil
        queryTask?.cancel()
        queryTask = nil
        runToken = nil
        isRunning = false
        hasOpenTransaction = false
        let previousSession = consoleSessionID
        consoleSessionID = UUID()
        Task { await DatabaseService.shared.closeConsole(previousSession) }
    }

    func disconnectConsole() { cancelQuery() }

    private func finishExecutionHistory(token: UUID, outcome: QueryHistoryOutcome, summary: String) {
        guard let pending = executionHistory, pending.token == token else { return }
        executionHistory = nil
        var entry = pending.entry
        entry.summary = summary
        entry.outcome = outcome
        entry.duration = max(0, ProcessInfo.processInfo.systemUptime - pending.started)
        lastExecution = entry
        libraryStore?.addHistory(entry)
    }

    func setManualCommit(_ enabled: Bool) {
        guard selectedBookmark?.engine.supportsConsoleTransactions == true else { return }
        guard !hasOpenTransaction, !isRunning else { return }
        manualCommit = enabled
    }

    func finishTransaction(commit: Bool) {
        guard !isRunning else { return }
        isRunning = true
        let sessionID = consoleSessionID
        let token = UUID()
        runToken = token
        queryTask = Task {
            do {
                try Task.checkCancellation()
                try await DatabaseService.shared.finishConsoleTransaction(sessionID, commit: commit)
                guard runToken == token, !Task.isCancelled else { return }
                hasOpenTransaction = false
            } catch {
                let transactionOpen = await DatabaseService.shared.consoleHasTransaction(sessionID)
                guard runToken == token, !Task.isCancelled else { return }
                errorMessage = DatabaseErrorFormatter.message(for: error)
                hasOpenTransaction = transactionOpen
            }
            isRunning = false; queryTask = nil; runToken = nil
        }
    }

    var transferBoundQuery: BoundQuery? {
        if let bound = activeBoundQuery, bound.sql == queryText { return bound }
        let engine = selectedBookmark?.engine ?? .postgresql
        guard QueryParameterService.parameters(in: queryText, engine: engine).isEmpty else { return nil }
        let words = SQLEditingService.tokens(queryText, engine: engine)
        if (engine.isMySQLFamily || engine == .sqlite), words.contains(where: { $0.text == "?" }) { return nil }
        if engine == .postgresql, words.contains(where: { $0.text.range(of: #"^\$[0-9]+$"#, options: .regularExpression) != nil }) { return nil }
        return BoundQuery(sql: queryText, values: [])
    }

    func useMongoTemplate(_ kind: String) {
        guard isDocumentDatabase, let collection = selectedExplorerTable?.name else { return }
        activeBoundQuery = nil
        mongoDraft.mode = .command
        queryText = MongoQueryService.template(kind, collection: collection)
        refreshAssist()
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
                    && schemaColumn.isGenerated != true
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
                isEditable: column.isGenerated != true && !Self.isUnsupportedBinaryColumn(column)
            )
        }
        dataEditorDraft = DataEditorDraft(mode: .insert, table: targetTable, fields: fields, rowID: nil)
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    /// Opens the insert editor pre-filled from a loaded row. Primary-key and unique columns start empty so
    /// the database can assign them, and binary values are left out. Nothing is written until the editor is saved.
    func prepareDuplicate(row: QueryRow) {
        prepareInsert()
        guard var draft = dataEditorDraft, draft.mode == .insert else { return }
        let names = result.columns.map { normalizedIdentifier($0.name) }
        // Ambiguous result columns can't be matched to table columns safely; keep the blank insert form.
        guard Set(names).count == names.count else { return }
        draft.fields = draft.fields.map { field in
            guard field.isEditable, !field.column.isPrimaryKey, !field.column.isUnique,
                  let index = names.firstIndex(of: normalizedIdentifier(field.column.name)) else { return field }
            let cell = row.cells[safe: index] ?? .null
            guard !cell.isBinary else { return field }
            var copy = field
            copy.value = cell.isNull ? "" : cell.displayValue
            copy.isNull = cell.isNull
            return copy
        }
        dataEditorDraft = draft
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

    @discardableResult
    func saveBookmark(_ profile: ConnectionProfile) -> Bool {
        guard !hasOpenTransaction else { errorMessage = ConsoleSessionError.pendingTransaction.localizedDescription; return false }
        let oldEngine = selectedBookmark?.engine
        guard bookmarkStore?.upsert(profile) == true else {
            errorMessage = bookmarkStore?.errorMessage
            return false
        }
        selectBookmark(profile.id, previousEngineOverride: oldEngine)
        selectedProfileForEdit = nil
        return true
    }

    func selectBookmark(_ id: UUID?, previousEngineOverride: DatabaseEngine? = nil) {
        guard !hasOpenTransaction else { errorMessage = ConsoleSessionError.pendingTransaction.localizedDescription; return }
        disconnectConsole()
        let previousEngine = previousEngineOverride ?? selectedBookmark?.engine
        pendingSafetyConfirmation = nil
        parameterDraft = nil
        activeBoundQuery = nil
        cancelMutation()
        queryTask?.cancel()
        queryTask = nil
        if let previousEngine {
            engineDrafts[previousEngine] = (queryText, explorerWhereClause, explorerOrderByClause)
        }
        selectedBookmarkID = id
        if selectedBookmark?.engine.supportsConsoleTransactions != true { manualCommit = false }
        mongoDraft.collection = ""
        querySelectionLength = 0
        if previousEngine != selectedBookmark?.engine {
            let draft = selectedBookmark.flatMap { engineDrafts[$0.engine] }
            queryText = draft?.query ?? ""
            explorerWhereClause = draft?.filter ?? ""
            explorerOrderByClause = draft?.sort ?? ""
        }
        selectedDatabaseName = bookmarkStore?.bookmark(with: id)?.trimmedDefaultDatabase ?? ""
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        resultSets = []
        runToken = nil
        isRunning = false
        schemaCatalog = []
        selectedExplorerTableID = nil
        rebuildSchemaSuggestions()
        refreshAssist()
        reloadSchema()
    }

    func selectDatabase(_ name: String) {
        guard !hasOpenTransaction else { errorMessage = ConsoleSessionError.pendingTransaction.localizedDescription; return }
        disconnectConsole()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSafetyConfirmation = nil
        parameterDraft = nil
        activeBoundQuery = nil
        cancelMutation()
        queryTask?.cancel()
        queryTask = nil
        selectedDatabaseName = trimmed
        mongoDraft.collection = ""
        explorerPageIndex = 0
        explorerPageSize = 25
        result = QueryResultTable.empty
        resultSets = []
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

    func defaultQuery(for table: SchemaTableDescriptor) -> String {
        browseQuery(for: table, whereClause: "", orderByClause: "")
    }

    private func browseQuery(
        for table: SchemaTableDescriptor,
        whereClause: String? = nil,
        orderByClause: String? = nil
    ) -> String {
        if isDocumentDatabase {
            return (try? MongoQueryService.browse(collection: table.name, filter: whereClause ?? explorerWhereClause,
                sort: orderByClause ?? explorerOrderByClause, limit: explorerPageSize, skip: explorerPageIndex * explorerPageSize)) ?? ""
        }
        if selectedBookmark?.engine == .elasticsearch {
            return ElasticsearchQueryService.browse(index: table.name, limit: explorerPageSize, offset: explorerPageIndex * explorerPageSize)
        }
        guard isSQLDatabase else { return "SCAN 0 COUNT 100" }
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
        if isDocumentDatabase {
            return (try? MongoQueryService.parse(sql)).map { ["create", "drop"].contains($0.name) } ?? false
        }
        if selectedBookmark?.engine == .elasticsearch, let command = try? ElasticsearchQueryService.parse(sql) {
            return !command.isReadOnly && (command.method == "PUT" || command.method == "DELETE")
        }
        let normalized = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["CREATE ", "ALTER ", "DROP ", "TRUNCATE "].contains { normalized.hasPrefix($0) }
    }

    private func mutationSQL(for draft: DataEditorDraft, engine: DatabaseEngine) -> BoundQuery? {
        guard engine.supportsRowEditing else { return nil }
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
        case .mysql, .mariadb:
            return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
        default:
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
        if bookmark.engine == .redis {
            for value in [requested, bookmark.trimmedDefaultDatabase, "0"] {
                if let database = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), database >= 0 { return String(database) }
            }
        }
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
