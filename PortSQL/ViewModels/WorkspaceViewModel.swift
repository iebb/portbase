import Foundation
import SwiftUI

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var selectedBookmarkID: UUID?
    @Published var selectedDatabaseName = ""
    @Published private(set) var availableDatabases: [String] = []
    @Published private(set) var isRefreshingDatabases = false
    /// The console text and what's worked out from it, published apart from the workspace (see `QueryEditorState`).
    let editor = QueryEditorState()
    var queryText: String {
        get { editor.text }
        set { editor.text = newValue }
    }
    var queryErrorRange: NSRange? {
        get { editor.errorRange }
        set { editor.errorRange = newValue }
    }
    @Published var manualCommit = false
    @Published private(set) var hasOpenTransaction = false
    private(set) var consoleSessionID = UUID()
    var queryCursorOffset: Int {
        get { editor.cursorOffset }
        set { editor.cursorOffset = newValue }
    }
    var querySelectionLength: Int {
        get { editor.selectionLength }
        set { editor.selectionLength = newValue }
    }
    @Published var mongoDraft = MongoQueryDraft()
    @Published var explorerWhereClause = ""
    @Published var explorerOrderByClause = ""
    @Published var explorerPageIndex = 0
    /// Rows per Explorer page: the user's choice, kept across databases and launches.
    @Published var explorerPageSize = WorkspaceViewModel.storedExplorerPageSize
    static let explorerPageSizes = [50, 100, 250, 500, 1_000]
    static let explorerPageSizeKey = "Portbase.explorerPageSize"
    private static var storedExplorerPageSize: Int {
        let stored = UserDefaults.standard.integer(forKey: explorerPageSizeKey)
        return explorerPageSizes.contains(stored) ? stored : 100
    }
    /// Context-aware completions at the console caret, from `SQLCompletionEngine`.
    private(set) var completion: SQLCompletionResult {
        get { editor.completion }
        set { editor.completion = newValue }
    }
    /// The text and caret the completion was computed for, so a stale one is never applied.
    private var completionSource: (text: String, cursor: Int)?
    var hints: [EditorHint] {
        get { editor.hints }
        set { editor.hints = newValue }
    }
    @Published var schema: [SchemaSuggestion] = []
    @Published var schemaCatalog: [SchemaTableDescriptor] = []
    @Published private(set) var foreignKeys: [SchemaForeignKey] = []
    /// Foreign keys in other tables that point at the browsed table, for opening the rows that reference a row.
    @Published private(set) var referencingKeys: [SchemaRelationship] = []
    private var relationshipTask: Task<Void, Never>?
    @Published var result = QueryResultTable.empty {
        didSet { prunePendingCellEdits() }
    }
    /// Cell values edited in the grid but not yet written, keyed by loaded row and column.
    @Published var pendingCellEdits: [PendingCellKey: DataEditorField] = [:]
    /// Rows marked for deletion, written with the cell edits on Submit.
    @Published var pendingRowDeletions: Set<QueryRow.ID> = []
    /// Shows the statements Submit will run; pending deletions always pass through it first.
    @Published var isShowingChangePreview = false

    var hasPendingChanges: Bool { !pendingCellEdits.isEmpty || !pendingRowDeletions.isEmpty }
    var pendingChangeCount: Int { pendingCellEdits.count + pendingRowDeletions.count }
    @Published var isSubmittingPendingEdits = false
    @Published var pendingEditError: String?
    /// An action that would replace the loaded rows, held until staged edits are discarded or kept.
    @Published var pendingDiscardRequest: PendingDiscardRequest?
    @Published var isShowingAssistant = false
    /// Set by the command palette or a menu command to open the schema diagram wherever the workspace is shown.
    @Published var isShowingSchemaDiagram = false
    /// A note shown once per connection and database, the first time a save goes to a table that can't
    /// roll back. Saves aren't blocked: each one is limited to a single row.
    @Published var writeWithoutRollbackNotice: String?
    /// This console's conversation with the assistant.
    let assistant = AssistantSession()
    /// A chart the assistant proposed, built once its query finishes running.
    @Published var pendingAssistantChart: AssistantChartSuggestion?
    @Published var resultSets: [QueryResultTable] = []
    @Published private(set) var selectedResultIndex = 0
    /// While a script runs, which of its statements is running, for "Running 2 of 5".
    @Published private(set) var runProgress: ScriptRunProgress?
    /// The statement a script stopped at, shown as a failed tab after the results before it.
    @Published private(set) var failedStatement: FailedScriptStatement?
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
    @Published var selectedExplorerTableID: UUID? {
        didSet { if oldValue != selectedExplorerTableID { swapExplorerClauses() } }
    }
    /// WHERE and ORDER BY text for each table this session, so a filter stays with its table.
    var explorerClausesByTable: [String: (filter: String, sort: String)] = [:]
    /// The table whose clauses are in the fields now.
    var explorerClauseScope: String?
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
    var mutationTask: Task<Void, Never>?
    var mutationToken: UUID?
    var activeBoundQuery: BoundQuery?
    private var engineDrafts: [DatabaseEngine: String] = [:]
    private let schemaCacheStore = SchemaCacheStore.shared

    init() {
        editor.onEdit = { [weak self] in self?.refreshAssist() }
    }

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
        editPlan != nil && !result.rows.isEmpty
    }

    /// Result columns shown with a key icon: the browsed table's primary key, or the columns that identify
    /// rows in an editable query result.
    var resultKeyColumnNames: Set<String> {
        if isShowingExplorerResult { return Set(selectedExplorerTable?.primaryKeyColumns.map(\.name) ?? []) }
        guard let plan = editPlan else { return [] }
        return Set(plan.targets.flatMap(\.keyColumns).compactMap { result.columns[safe: $0.resultIndex]?.name })
    }

    private var editPlanCache: (key: Int, plan: ResultEditPlan?)?

    /// What in the current result can be edited. An Explorer browse maps its columns to the table by name,
    /// as row editing always has; a console query's results map through the column origins the database
    /// reported, never through the SQL text. Console results aren't edited while the console holds an open
    /// transaction, whose locks a save on another connection would wait behind.
    var editPlan: ResultEditPlan? {
        var hasher = Hasher()
        hasher.combine(result.columns.map(\.id))
        hasher.combine(result.columns.map(\.origin))
        hasher.combine(result.isExplorerGenerated)
        hasher.combine(result.sourceTableReference)
        hasher.combine(result.sourceQuery)
        hasher.combine(schemaCatalog.map(\.id))
        hasher.combine(hasOpenTransaction)
        hasher.combine(selectedBookmark?.engine)
        let key = hasher.finalize()
        if let editPlanCache, editPlanCache.key == key { return editPlanCache.plan }
        let plan = makeEditPlan()
        editPlanCache = (key, plan)
        return plan
    }

    private func makeEditPlan() -> ResultEditPlan? {
        guard let engine = selectedBookmark?.engine, engine.supportsRowEditing, result.documents == nil else { return nil }
        if let table = currentEditableTable { return ResultEditPlanner.explorerPlan(table: table, columns: result.columns) }
        guard result.isExplorerGenerated != true, !hasOpenTransaction, let statement = result.sourceQuery,
              SQLSafetyService.isReadOnlySQL(statement, engine: engine) else { return nil }
        return ResultEditPlanner.originPlan(columns: result.columns, statement: statement, catalog: schemaCatalog, engine: engine)
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
            if completion != .empty { completion = .empty }
            if !hints.isEmpty { hints = [] }
            return
        }

        let query = queryText
        let catalog = schemaCatalog
        let activeDatabase = activeDatabaseName
        let cursorOffset = queryCursorOffset
        let engine = selectedBookmark?.engine ?? .postgresql
        let usage = SQLCompletionUsage.counts()

        assistTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }

            let completion = SQLCompletionEngine.complete(query, cursor: cursorOffset, catalog: catalog,
                                                          activeDatabase: activeDatabase, engine: engine, usage: usage)
            // A newer keystroke has taken over; don't spend the time on hints nobody will see.
            guard !Task.isCancelled else { return }
            // Unknown tables first: they're about this text and this database, not general advice.
            let hints = SQLInspection.hints(for: query, catalog: catalog, engine: engine, cursor: cursorOffset) + SQLAssistService.hints(for: query)

            await MainActor.run {
                guard self.queryText == query, self.queryCursorOffset == cursorOffset else { return }
                // Only changes are published: every assignment redraws each view watching the workspace.
                if self.completion != completion { self.completion = completion }
                self.completionSource = (query, cursorOffset)
                let same = self.hints.count == hints.count
                    && zip(self.hints, hints).allSatisfy { $0.title == $1.title && $0.message == $1.message && $0.severity == $1.severity }
                if !same { self.hints = hints }
            }
        }
    }

    /// Accepts a completion computed for the current text and caret.
    func applyCompletion(_ item: SQLCompletionItem) {
        guard let source = completionSource, source.text == queryText else { return }
        let applied = SQLCompletionEngine.apply(item, to: queryText, result: completion)
        SQLCompletionUsage.record(item)
        completion = .empty
        queryText = applied.text
        queryCursorOffset = applied.cursor
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
        guard proceedDiscardingPendingEdits({ [weak self] in self?.runQuery(entireBuffer: entireBuffer) }) else { return }
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

    /// Whether Explain Analyze is offered for the current connection.
    var canExplainAnalyze: Bool { selectedBookmark.map { SQLSafetyService.supportsExplainAnalyze($0.engine) } ?? false }

    /// Shows the query's plan. With `analyze`, the query runs, read-only, so the plan reports actual times and rows.
    func runExplain(analyze: Bool = false) {
        let sql = selectedQuery
        guard let values = boundValues(for: sql) else { return }
        let engine = selectedBookmark?.engine ?? .postgresql
        if analyze, !SQLSafetyService.supportsExplainAnalyze(engine) {
            errorMessage = L10n.text("Explain Analyze is available for PostgreSQL and MySQL.")
            return
        }
        guard let explainSQL = SQLSafetyService.explainQuery(for: sql, engine: engine, analyze: analyze) else {
            errorMessage = L10n.text("Explain is available only for read-only queries.")
            return
        }
        run(sql: explainSQL, title: L10n.text(analyze ? "Explain Analyze" : "Explain plan"), values: values, policy: .readOnly)
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

    // MARK: Assistant

    /// What the assistant is told about this workspace. Hosts, users, and secrets are never included;
    /// sample values only leave the device when the user allows them in settings.
    func assistantContext(includingSampleRows: Bool) -> AssistantContext? {
        guard let engine = selectedBookmark?.engine else { return nil }
        return AssistantContext(
            engine: engine,
            database: activeDatabaseName,
            tables: schemaCatalog,
            foreignKeys: foreignKeys,
            currentQuery: queryText,
            resultColumns: result.columns,
            sampleRows: includingSampleRows
                ? result.rows.prefix(AssistantPromptBuilder.maximumSampleRows).map { $0.cells.map { $0.isNull ? "NULL" : $0.displayValue } }
                : [],
            isReadOnly: selectedBookmark?.isReadOnly ?? false,
            environment: selectedBookmark.flatMap { $0.environment == .none ? nil : $0.environment.title }
        )
    }

    /// Puts an assistant query in the editor without running it, at the cursor or in place of the editor's text.
    func applyAssistantQuery(_ sql: String, replacing: Bool) {
        activeBoundQuery = nil
        if replacing || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryText = sql
            queryCursorOffset = (sql as NSString).length
        } else {
            let edit = SQLTemplateService.insert(sql, into: queryText, cursor: queryCursorOffset, selectionLength: querySelectionLength)
            queryText = edit.text
            queryCursorOffset = edit.cursor
        }
        querySelectionLength = 0
    }

    /// Runs a proposed chart's query through the normal console path, where writes still need
    /// confirmation, and remembers the chart so the results can open it in the chart editor.
    func runAssistantChart(_ chart: AssistantChartSuggestion) {
        applyAssistantQuery(chart.query, replacing: true)
        pendingAssistantChart = chart
        runQuery()
    }

    /// The chart editor's starting point for a proposed chart, once its query has produced a result.
    /// Unknown column names fall back to the result's defaults.
    func consumeAssistantChart() -> SavedVisualizationPreset? {
        guard let chart = pendingAssistantChart, !isRunning else { return nil }
        pendingAssistantChart = nil
        guard !result.columns.isEmpty else { return nil }
        var preset = VisualizationService.reconciledPreset(nil, for: result,
            connectionProfileID: selectedBookmark?.id, connectionName: selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: activeDatabaseName, sourceTableReference: result.sourceTableReference)
        preset.chartType = chart.chartType
        preset.xField = chart.x
        preset.yFields = chart.y
        preset.yField = chart.y.first ?? preset.yField
        if let title = chart.title, !title.isEmpty { preset.title = title; preset.chartTitle = title }
        return VisualizationService.reconciledPreset(preset, for: result,
            connectionProfileID: selectedBookmark?.id, connectionName: selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: activeDatabaseName, sourceTableReference: result.sourceTableReference)
    }

    func refreshSchemaCatalog() {
        reloadSchema(forceRefresh: true)
    }

    /// Asks the server for its current databases, bypassing the schema cache, so databases created or
    /// dropped elsewhere appear without reloading the active database's tables.
    func refreshDatabaseList() {
        guard let bookmark = selectedBookmark, !isRefreshingDatabases else { return }
        isRefreshingDatabases = true
        let requestedDatabase = activeDatabaseName
        Task {
            defer { isRefreshingDatabases = false }
            do {
                let databases = try await DatabaseService.shared.listDatabases(profile: bookmark)
                guard selectedBookmarkID == bookmark.id else { return }
                availableDatabases = databases
                if bookmark.schemaCachingEnabled, let requestedDatabase {
                    schemaCacheStore.updateDatabases(databases, for: bookmark, requestedDatabase: requestedDatabase)
                }
            } catch {
                guard selectedBookmarkID == bookmark.id else { return }
                schemaErrorMessage = DatabaseErrorFormatter.message(for: error)
            }
        }
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

    func deleteHistory(at offsets: IndexSet) {
        libraryStore?.deleteHistory(at: offsets)
    }

    func deleteSnippets(at offsets: IndexSet) {
        libraryStore?.deleteSnippets(at: offsets)
    }

    func run(
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
        runProgress = nil
        failedStatement = nil
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
            var statementCount = 1
            do {
                let ranges = SQLEditingService.statementRanges(in: sql, engine: profile?.engine ?? .postgresql)
                if ranges.count > 1, !values.isEmpty {
                    throw NSError(domain: "PortSQL.Parameters", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Run parameterized statements individually.")])
                }
                let statements = ranges.isEmpty ? [sql] : ranges.map { String(sql[$0]) }
                statementCount = statements.count
                for (index, statement) in statements.enumerated() {
                    try Task.checkCancellation()
                    if statements.count > 1 {
                        await MainActor.run {
                            guard self.runToken == currentRunToken else { return }
                            self.runProgress = ScriptRunProgress(current: index + 1, total: statements.count)
                        }
                    }
                    failureSQL = statement
                    failureOffset = executionOffset == NSNotFound ? NSNotFound : executionOffset + (ranges.indices.contains(index) ? NSRange(ranges[index], in: sql).location : 0)
                    var table = try await DatabaseService.shared.execute(
                        query: statement, values: values, profile: profile, database: database, policy: policy,
                        sessionID: usesConsole ? sessionID : nil, manualCommit: manual
                    )
                    table.sourceTableReference = explorerTable?.displayName ?? VisualizationService.inferredTableReference(in: statement)
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
                    self.runProgress = nil
                    self.loadRelationships(for: explorerTable, profile: profile, database: database)
                    if explorerTable == nil { self.resolveColumnOrigins(profile: profile, database: database, token: currentRunToken) }
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
                    self.runProgress = nil
                    // In a script, the tabs show where it stopped; a single statement's error speaks for itself.
                    if statementCount > 1, !(error is CancellationError) {
                        self.failedStatement = FailedScriptStatement(number: completed.count + 1, total: statementCount,
                                                                     sql: failureSQL.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                     message: self.errorMessage ?? "")
                    }
                    self.queryTask = nil
                    self.cancellationWriteWarning = nil
                    self.isRunning = false
                }
            }
        }
    }

    /// Selects a statement in the editor, as a result tab's Show in Editor does; nothing happens once it's been edited away.
    func revealStatement(_ sql: String) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = (queryText as NSString).range(of: trimmed)
        guard !trimmed.isEmpty, range.location != NSNotFound else { return }
        queryCursorOffset = range.location
        querySelectionLength = range.length
    }

    /// Whether the results panel has anything to show: rows, a summary, an error, or a run in progress.
    var hasResultsToShow: Bool {
        isRunning || errorMessage != nil || !resultSets.isEmpty || failedStatement != nil
            || !result.columns.isEmpty || result.documents != nil || result.affectedRowCount != nil || result.generatedMutation != nil
    }

    /// PostgreSQL names a result column's table only by OID, so the names come from a read-only catalog
    /// lookup once the rows are shown; they're patched in only if no other run has replaced the results.
    private func resolveColumnOrigins(profile: ConnectionProfile?, database: String?, token: UUID) {
        guard let profile, profile.engine == .postgresql,
              resultSets.contains(where: { $0.columns.contains { $0.origin?.postgresTableOID != nil && $0.origin?.isResolved != true } }) else { return }
        let sets = resultSets
        Task {
            var resolved = sets
            for index in sets.indices where sets[index].columns.contains(where: { $0.origin?.postgresTableOID != nil }) {
                // Without names the results simply stay read-only.
                guard let columns = try? await DatabaseService.shared.resolvePostgresColumnOrigins(sets[index].columns, profile: profile, database: database) else { return }
                resolved[index].columns = columns
            }
            guard self.runToken == token, self.resultSets.map({ $0.columns.map(\.id) }) == sets.map({ $0.columns.map(\.id) }) else { return }
            for index in resolved.indices { self.resultSets[index].columns = resolved[index].columns }
            if resolved.indices.contains(self.selectedResultIndex), self.result.columns.map(\.id) == resolved[self.selectedResultIndex].columns.map(\.id) {
                self.result.columns = resolved[self.selectedResultIndex].columns
            }
        }
    }

    func selectResult(_ index: Int) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.selectResult(index) }) else { return }
        guard resultSets.indices.contains(index) else { return }
        selectedResultIndex = index
        result = resultSets[index]
        foreignKeys = []
        referencingKeys = []
    }

    private func loadRelationships(for table: SchemaTableDescriptor?, profile: ConnectionProfile?, database: String?) {
        relationshipTask?.cancel()
        foreignKeys = []
        referencingKeys = []
        guard let table, let profile, profile.engine.isRelational else { return }
        let expectedResult = result.sourceQuery
        let catalog = schemaCatalog
        relationshipTask = Task {
            do {
                let keys = try await DatabaseService.shared.schemaForeignKeys(table: table, profile: profile, database: database)
                guard !Task.isCancelled, result.sourceQuery == expectedResult else { return }
                foreignKeys = keys
                let references = try await DatabaseService.shared.schemaReferencingKeys(table: table, catalog: catalog, profile: profile, database: database)
                guard !Task.isCancelled, result.sourceQuery == expectedResult else { return }
                referencingKeys = references
            } catch { /* Data browsing stays available when metadata privileges are limited. */ }
        }
    }

    func followForeignKey(_ key: SchemaForeignKey, row: QueryRow) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.followForeignKey(key, row: row) }) else { return }
        let target = schemaCatalog.first { $0.schemaName == key.referencedSchema && $0.name == key.referencedTable }
            ?? SchemaTableDescriptor(schemaName: key.referencedSchema, name: key.referencedTable, columns: [], rowCountEstimate: nil)
        openRelatedRows(in: target, matching: key.referencedColumns, valuesOf: key.columns, row: row)
    }

    /// Opens the rows of another table whose foreign key points at this row.
    func followReference(_ reference: SchemaRelationship, row: QueryRow) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.followReference(reference, row: row) }) else { return }
        let source = schemaCatalog.first { $0.schemaName == reference.schema && $0.name == reference.table }
            ?? SchemaTableDescriptor(schemaName: reference.schema, name: reference.table, columns: [], rowCountEstimate: nil)
        openRelatedRows(in: source, matching: reference.key.columns, valuesOf: reference.key.referencedColumns, row: row)
    }

    /// Browses a table's rows whose columns equal this row's values, bound as parameters, read-only.
    private func openRelatedRows(in target: SchemaTableDescriptor, matching targetColumns: [String], valuesOf columns: [String], row: QueryRow) {
        guard let profile = selectedBookmark, profile.engine.isRelational,
              !columns.isEmpty, columns.count == targetColumns.count else { return }
        var values: [QueryBoundValue] = []
        for column in columns {
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
        let clauses = targetColumns.enumerated().map { index, column in
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

    func enforceWritableConnection(_ bookmark: ConnectionProfile) throws {
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
        guard proceedDiscardingPendingEdits({ [weak self] in self?.selectBookmark(id, previousEngineOverride: previousEngineOverride) }) else { return }
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
            engineDrafts[previousEngine] = queryText
        }
        selectedBookmarkID = id
        if selectedBookmark?.engine.supportsConsoleTransactions != true { manualCommit = false }
        mongoDraft.collection = ""
        querySelectionLength = 0
        if previousEngine != selectedBookmark?.engine {
            queryText = selectedBookmark.flatMap { engineDrafts[$0.engine] } ?? ""
        }
        selectedDatabaseName = bookmarkStore?.bookmark(with: id)?.trimmedDefaultDatabase ?? ""
        explorerPageIndex = 0
        result = QueryResultTable.empty
        resultSets = []
        failedStatement = nil
        runProgress = nil
        runToken = nil
        isRunning = false
        schemaCatalog = []
        selectedExplorerTableID = nil
        rebuildSchemaSuggestions()
        refreshAssist()
        reloadSchema()
    }

    func selectDatabase(_ name: String) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.selectDatabase(name) }) else { return }
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
        result = QueryResultTable.empty
        resultSets = []
        failedStatement = nil
        runProgress = nil
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

/// The console's text and caret, and the completions and hints worked out from them. They change with
/// every keystroke, so they're published here rather than by the workspace: typing then redraws the
/// editor and the views that show these, not every view watching the workspace.
@MainActor
final class QueryEditorState: ObservableObject {
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            if selectionLength != 0 { selectionLength = 0 }
            if errorRange != nil { errorRange = nil }
            onEdit()
        }
    }
    @Published var cursorOffset = 0 {
        didSet { if cursorOffset != oldValue { onEdit() } }
    }
    @Published var selectionLength = 0
    @Published var errorRange: NSRange?
    @Published var completion = SQLCompletionResult.empty
    @Published var hints: [EditorHint] = []
    /// Called when the text or caret moves, to work out completions and hints again.
    var onEdit: () -> Void = {}
}
