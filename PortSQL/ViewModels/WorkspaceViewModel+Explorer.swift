import Foundation
import SwiftUI

/// The Explorer: table selection, paged and sorted browsing, related rows, and column changes.
extension WorkspaceViewModel {
    func selectExplorerTable(_ table: SchemaTableDescriptor) {
        // Keeping the edits returns the sidebar to the table they belong to.
        guard proceedDiscardingPendingEdits({ [weak self] in self?.selectExplorerTable(table) }, onCancel: { [weak self] in
            guard let self, let reference = self.result.sourceTableReference,
                  let edited = self.schemaCatalog.first(where: { $0.matches(reference: reference) }) else { return }
            self.selectedExplorerTableID = edited.id
        }) else { return }
        // Selecting first swaps in this table's own filter and sort before they're used below.
        selectedExplorerTableID = table.id
        if isDocumentDatabase {
            mongoDraft.collection = table.name
            mongoDraft.mode = .find
            mongoDraft.filter = explorerWhereClause.isEmpty ? "{}" : explorerWhereClause
            mongoDraft.projection = "{}"
            mongoDraft.sort = explorerOrderByClause.isEmpty ? #"{"_id": 1}"# : explorerOrderByClause
            mongoDraft.skip = "0"
            mongoDraft.limit = String(explorerPageSize)
        }
        explorerPageIndex = 0
        browse(table: table)
    }

    func browse(table: SchemaTableDescriptor? = nil) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.browse(table: table) }) else { return }
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
        guard proceedDiscardingPendingEdits({ [weak self] in self?.restartBrowse() }) else { return }
        explorerPageIndex = 0
        if let table = selectedExplorerTable {
            // Applied clauses join the table's filter and sort history.
            let scope = ClauseHistoryStore.scope(profileID: selectedBookmarkID, database: activeDatabaseName, table: table.displayName)
            ClauseHistoryStore.shared.record(explorerWhereClause, kind: .filter, in: scope)
            ClauseHistoryStore.shared.record(explorerOrderByClause, kind: .sort, in: scope)
        }
        browse()
    }

    /// Keeps the outgoing table's WHERE and ORDER BY and restores the incoming table's (empty if it has none).
    func swapExplorerClauses() {
        if let scope = explorerClauseScope {
            explorerClausesByTable[scope] = (explorerWhereClause, explorerOrderByClause)
        }
        explorerClauseScope = clauseHistoryScope
        let restored = explorerClauseScope.flatMap { explorerClausesByTable[$0] }
        explorerWhereClause = restored?.filter ?? ""
        explorerOrderByClause = restored?.sort ?? ""
    }

    var clauseHistoryScope: String? {
        selectedExplorerTable.map { ClauseHistoryStore.scope(profileID: selectedBookmarkID, database: activeDatabaseName, table: $0.displayName) }
    }

    func goToPreviousExplorerPage() {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.goToPreviousExplorerPage() }) else { return }
        guard canGoToPreviousExplorerPage else { return }
        explorerPageIndex -= 1
        browse()
    }

    func goToNextExplorerPage() {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.goToNextExplorerPage() }) else { return }
        guard canGoToNextExplorerPage else { return }
        explorerPageIndex += 1
        browse()
    }

    func setExplorerPageSize(_ size: Int) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.setExplorerPageSize(size) }) else { return }
        let boundedSize = Self.explorerPageSizes.contains(size) ? size : 100
        UserDefaults.standard.set(boundedSize, forKey: Self.explorerPageSizeKey)
        guard explorerPageSize != boundedSize else { return }
        explorerPageSize = boundedSize
        explorerPageIndex = 0
        if selectedExplorerTable != nil {
            browse()
        }
    }

    func sortExplorer(by columnName: String) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.sortExplorer(by: columnName) }) else { return }
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

    /// Sorts the Explorer by one column in a given direction, or clears the sort when `descending` is nil.
    func sortExplorer(by columnName: String, descending: Bool?) {
        guard proceedDiscardingPendingEdits({ [weak self] in self?.sortExplorer(by: columnName, descending: descending) }) else { return }
        if let descending {
            explorerOrderByClause = isDocumentDatabase
                ? MongoQueryService.pretty([columnName: descending ? -1 : 1])
                : "\(sqlIdentifier(columnName, engine: selectedBookmark?.engine ?? .postgresql)) \(descending ? "DESC" : "ASC")"
        } else {
            explorerOrderByClause = ""
        }
        restartBrowse()
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

    func browseQuery(
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
        // Every column, in table order; the grid's column settings hide any the user doesn't want.
        let projection = table.columns
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

    func normalizedWhereClause(_ clause: String) -> String {
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

    func normalizedOrderByClause(_ clause: String) -> String {
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
}
