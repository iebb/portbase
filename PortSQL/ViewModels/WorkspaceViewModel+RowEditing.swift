import Foundation
import SwiftUI

/// Row editing: staged cell edits, inserts, deletions, and the single-row statements that write them.
extension WorkspaceViewModel {
    func prepareEdit(row: QueryRow) {
        dataEditorDraft = editDraft(for: row)
        dataEditorValidation = [:]
        dataEditorErrorMessage = nil
    }

    /// The row editor's draft: an update of the result's one editable table, or a read-only view of
    /// every column when the result spans several tables or none can be updated.
    private func editDraft(for row: QueryRow) -> DataEditorDraft {
        if let plan = editPlan, plan.targets.count == 1 { return editDraft(for: row, target: 0, plan: plan) }
        let table = SchemaTableDescriptor(
            schemaName: "",
            name: VisualizationService.inferredTableReference(in: result.sourceQuery ?? queryText) ?? L10n.text("Result Row"),
            columns: result.columns.map {
                SchemaColumnDescriptor(name: $0.name, type: $0.type, isNullable: true, isPrimaryKey: false, isUnique: false)
            },
            rowCountEstimate: nil
        )
        let fields = result.columns.enumerated().map { index, column -> DataEditorField in
            let cell = row.cells[safe: index] ?? .null
            return DataEditorField(column: table.columns[index], value: cell.displayValue, originalValue: cell.displayValue,
                                   isNull: cell.isNull, originalIsNull: cell.isNull, isEditable: false)
        }
        return DataEditorDraft(mode: .view, table: table, fields: fields, rowID: row.id)
    }

    /// An update of one table's part of a row: its key, which names the row, and its other columns.
    private func editDraft(for row: QueryRow, target: Int, plan: ResultEditPlan) -> DataEditorDraft {
        let table = plan.targets[target].table
        let readOnly = selectedBookmark?.isReadOnly == true
        let fields = plan.columns(of: target).map { index, mapped -> DataEditorField in
            let cell = row.cells[safe: index] ?? .null
            return DataEditorField(
                column: mapped.column,
                value: cell.displayValue,
                originalValue: cell.displayValue,
                isNull: cell.isNull,
                originalIsNull: cell.isNull,
                isEditable: !readOnly && mapped.isEditable && !cell.isBinary && !Self.isUnsupportedBinaryColumn(mapped.column)
            )
        }
        return DataEditorDraft(mode: readOnly ? .view : .update, table: table, fields: fields, rowID: row.id)
    }

    /// The value editor's field for one loaded cell, or nil when that row can't be updated safely.
    /// A staged edit for the cell is carried over, with the loaded value kept as the original.
    func editableField(rowIndex: Int, columnIndex: Int) -> DataEditorField? {
        // While a query runs its rows are about to be replaced, which would drop anything staged now.
        guard !isRunning, !isSubmittingPendingEdits, !isRowMarkedForDeletion(rowIndex: rowIndex),
              let plan = editPlan, let mapped = plan.editableColumn(at: columnIndex),
              result.rows.indices.contains(rowIndex), result.columns.indices.contains(columnIndex) else { return nil }
        let row = result.rows[rowIndex]
        guard row.cells.indices.contains(columnIndex) else { return nil }
        guard plan.targets[mapped.target].keyColumns.allSatisfy({ key in
            row.cells[safe: key.resultIndex].map { !$0.isNull && !$0.isBinary } ?? false
        }) else { return nil }
        let draft = editDraft(for: row, target: mapped.target, plan: plan)
        guard draft.mode == .update,
              var field = draft.fields.first(where: { $0.isEditable && $0.column.name == mapped.column.name }) else { return nil }
        if let staged = pendingCellEdits[PendingCellKey(rowID: row.id, column: columnIndex)] {
            field.value = staged.value
            field.isNull = staged.isNull
        }
        return field
    }

    /// The value editor's edit hook for one loaded cell; applying it stages the change for Submit.
    func cellEdit(rowIndex: Int, columnIndex: Int) -> ResultCellEdit? {
        guard let field = editableField(rowIndex: rowIndex, columnIndex: columnIndex),
              let engine = selectedBookmark?.engine else { return nil }
        let rowID = result.rows[rowIndex].id
        return ResultCellEdit(field: field, engine: engine) { [weak self] field in
            try self?.stageCell(rowID: rowID, columnIndex: columnIndex, field: field)
        }
    }

    /// Capture row identities so an open bulk editor cannot stage into a replacement result or connection.
    func cellsEdit(cells: [ResultGridCellKey]) -> ResultCellsEdit? {
        guard cells.count > 1, let fields = editableFields(cells: cells), let bookmark = selectedBookmark else { return nil }
        let keys = cells.map { PendingCellKey(rowID: result.rows[$0.row].id, column: $0.column) }
        let columns = result.columns
        let database = activeDatabaseName
        return ResultCellsEdit(fields: fields, engine: bookmark.engine) { [weak self] value, isNull in
            guard let self, self.selectedBookmarkID == bookmark.id, self.activeDatabaseName == database,
                  self.result.columns == columns,
                  zip(cells, keys).allSatisfy({ cell, key in
                      self.result.rows.indices.contains(cell.row) && self.result.rows[cell.row].id == key.rowID
                  }) else { throw Self.selectionEditError() }
            try self.stageCells(cells: cells, value: value, isNull: isNull)
        }
    }

    private func editableFields(cells: [ResultGridCellKey]) -> [DataEditorField]? {
        guard !cells.isEmpty, Set(cells).count == cells.count else { return nil }
        var fields: [DataEditorField] = []
        for cell in cells {
            guard let field = editableField(rowIndex: cell.row, columnIndex: cell.column) else { return nil }
            fields.append(field)
        }
        return fields
    }

    private static func selectionEditError() -> NSError {
        NSError(domain: "PortSQL.CellEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("The selected cells are no longer editable.")])
    }

    /// Validate the entire rectangle before changing any pending value. Submit keeps the existing
    /// bound, transactional single-row updates, grouped by row and source table.
    func stageCells(cells: [ResultGridCellKey], value: String, isNull: Bool) throws {
        try stageCellValues(cells.map { ($0, isNull ? nil : value) })
    }

    /// Stages a value for each cell, nil meaning NULL, as one change: a paste, a fill, or generated values.
    /// Every cell is checked before any is staged, so a block that's partly invalid stages nothing.
    func stageCellValues(_ values: [(cell: ResultGridCellKey, value: String?)]) throws {
        let cells = values.map(\.cell)
        guard let bookmark = selectedBookmark, let fields = editableFields(cells: cells) else { throw Self.selectionEditError() }
        try enforceWritableConnection(bookmark)
        let replacements = zip(fields, values).map { field, entry in
            var field = field
            field.value = entry.value ?? ""
            field.isNull = entry.value == nil
            return field
        }
        let validation = DataEditorValidationService.validate(fields: replacements, mode: .update, engine: bookmark.engine)
        if let field = replacements.first(where: { validation[$0.id] != nil }), let message = validation[field.id] {
            throw NSError(domain: "PortSQL.CellEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: field.column.name + ": " + message])
        }
        var edits = pendingCellEdits
        for (cell, field) in zip(cells, replacements) {
            let key = PendingCellKey(rowID: result.rows[cell.row].id, column: cell.column)
            let unchanged = field.isNull == (field.originalIsNull ?? false) && (field.isNull || field.value == (field.originalValue ?? ""))
            edits[key] = unchanged ? nil : field
        }
        pendingCellEdits = edits
        pendingEditError = nil
    }

    /// Stages values from the grid and reports a failure on the edits bar; returns its message.
    func stageGridValues(_ values: [(cell: ResultGridCellKey, value: String?)]) -> String? {
        do { try stageCellValues(values); return nil }
        catch {
            pendingEditError = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Drops staged values in the cells and restores the rows among them marked for deletion.
    func revertGridCells(_ cells: [ResultGridCellKey], rows: [Int]) {
        let keys = Set(cells.compactMap { cell in
            result.rows.indices.contains(cell.row) ? PendingCellKey(rowID: result.rows[cell.row].id, column: cell.column) : nil
        })
        if !keys.isEmpty { pendingCellEdits = pendingCellEdits.filter { !keys.contains($0.key) } }
        let ids = Set(rows.compactMap { result.rows.indices.contains($0) ? result.rows[$0].id : nil })
        if !pendingRowDeletions.isDisjoint(with: ids) { pendingRowDeletions.subtract(ids) }
        pendingEditError = nil
    }

    /// Whether any of the rows can be marked for deletion, or restored when they all are.
    func canToggleRowsDeletion(_ rows: [Int]) -> Bool {
        rows.contains { isRowMarkedForDeletion(rowIndex: $0) || canDeleteRow(rowIndex: $0) }
    }

    /// Marks every deletable row among them, or restores them all when each is already marked.
    func toggleRowsDeletion(_ rows: [Int]) {
        let loaded = rows.filter { result.rows.indices.contains($0) }
        if !loaded.isEmpty, loaded.allSatisfy({ isRowMarkedForDeletion(rowIndex: $0) }) {
            pendingRowDeletions.subtract(loaded.map { result.rows[$0].id })
        } else {
            let ids = Set(loaded.filter { canDeleteRow(rowIndex: $0) }.map { result.rows[$0].id })
            guard !ids.isEmpty else { return }
            pendingRowDeletions.formUnion(ids)
            pendingCellEdits = pendingCellEdits.filter { !ids.contains($0.key.rowID) }
        }
        pendingEditError = nil
    }

    /// The staged value for a loaded cell, typed like the column, or nil when the cell has no pending edit.
    func pendingCell(rowIndex: Int, columnIndex: Int) -> QueryCell? {
        guard !pendingCellEdits.isEmpty, result.rows.indices.contains(rowIndex), result.columns.indices.contains(columnIndex),
              let field = pendingCellEdits[PendingCellKey(rowID: result.rows[rowIndex].id, column: columnIndex)]
        else { return nil }
        return Self.stagedCell(for: field)
    }

    /// Stages a value for one cell after validating it. Setting a cell back to its loaded value drops the edit.
    func stageCell(rowID: QueryRow.ID, columnIndex: Int, field: DataEditorField) throws {
        guard let bookmark = selectedBookmark else {
            throw NSError(domain: "PortSQL.CellEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Choose a server first.")])
        }
        try enforceWritableConnection(bookmark)
        if let message = DataEditorValidationService.validate(fields: [field], mode: .update, engine: bookmark.engine).values.first {
            throw NSError(domain: "PortSQL.CellEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let key = PendingCellKey(rowID: rowID, column: columnIndex)
        let originalIsNull = field.originalIsNull ?? false
        if field.isNull == originalIsNull && (field.isNull || field.value == (field.originalValue ?? "")) {
            pendingCellEdits[key] = nil
        } else {
            pendingCellEdits[key] = field
        }
        pendingEditError = nil
    }

    /// Stages text typed into a grid cell. Returns a message when the text isn't valid for the column.
    func stageCellText(rowIndex: Int, columnIndex: Int, text: String) -> String? {
        guard var field = editableField(rowIndex: rowIndex, columnIndex: columnIndex) else {
            return L10n.text("This row cannot be saved because the primary key context is missing.")
        }
        field.value = text
        field.isNull = false
        do { try stageCell(rowID: result.rows[rowIndex].id, columnIndex: columnIndex, field: field); return nil }
        catch {
            pendingEditError = error.localizedDescription
            return error.localizedDescription
        }
    }

    func stageCellNull(rowIndex: Int, columnIndex: Int) {
        guard var field = editableField(rowIndex: rowIndex, columnIndex: columnIndex), field.column.isNullable else { return }
        field.isNull = true
        do { try stageCell(rowID: result.rows[rowIndex].id, columnIndex: columnIndex, field: field) }
        catch { pendingEditError = error.localizedDescription }
    }

    func revertPendingCell(rowIndex: Int, columnIndex: Int) {
        guard result.rows.indices.contains(rowIndex), result.columns.indices.contains(columnIndex) else { return }
        pendingCellEdits[PendingCellKey(rowID: result.rows[rowIndex].id, column: columnIndex)] = nil
    }

    /// Returns true when an action that replaces the loaded rows can go ahead now. With staged edits it
    /// asks first, and runs the action only after the edits are discarded.
    func proceedDiscardingPendingEdits(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) -> Bool {
        guard hasPendingChanges else { return true }
        if pendingDiscardRequest == nil { pendingDiscardRequest = PendingDiscardRequest(proceed: action, cancel: onCancel) }
        return false
    }

    func discardPendingEdits(andContinue request: PendingDiscardRequest) {
        if pendingDiscardRequest?.id == request.id { pendingDiscardRequest = nil }
        discardPendingEdits()
        request.proceed()
    }

    func keepPendingEdits(_ request: PendingDiscardRequest) {
        if pendingDiscardRequest?.id == request.id { pendingDiscardRequest = nil }
        request.cancel?()
    }

    func discardPendingEdits() {
        pendingCellEdits = [:]
        pendingRowDeletions = []
        pendingEditError = nil
        isShowingChangePreview = false
    }

    // MARK: Row deletion

    /// Whether a loaded row can be marked for deletion: a result of one editable table whose key
    /// values are all present. In a join, which table "this row" means is ambiguous, so it can't.
    func canDeleteRow(rowIndex: Int) -> Bool {
        guard !isRunning, selectedBookmark?.isReadOnly != true, result.documents == nil,
              let plan = editPlan, plan.targets.count == 1, result.rows.indices.contains(rowIndex) else { return false }
        let row = result.rows[rowIndex]
        return plan.targets[0].keyColumns.allSatisfy { key in row.cells[safe: key.resultIndex].map { !$0.isNull && !$0.isBinary } ?? false }
    }

    func isRowMarkedForDeletion(rowIndex: Int) -> Bool {
        result.rows.indices.contains(rowIndex) && pendingRowDeletions.contains(result.rows[rowIndex].id)
    }

    /// Marks or unmarks a row; a row marked for deletion drops its pending cell edits.
    func toggleRowDeletion(rowIndex: Int) {
        guard result.rows.indices.contains(rowIndex) else { return }
        let id = result.rows[rowIndex].id
        if pendingRowDeletions.remove(id) == nil {
            guard canDeleteRow(rowIndex: rowIndex) else { return }
            pendingRowDeletions.insert(id)
            pendingCellEdits = pendingCellEdits.filter { $0.key.rowID != id }
        }
        pendingEditError = nil
    }

    /// Loaded row indexes marked for deletion, for the grid.
    var pendingDeletedGridRows: Set<Int> {
        guard !pendingRowDeletions.isEmpty else { return [] }
        return Set(result.rows.indices.filter { pendingRowDeletions.contains(result.rows[$0].id) })
    }

    /// Staged values typed like their columns, keyed by loaded row and column index for the grid.
    var pendingGridCells: [ResultGridCellKey: QueryCell] {
        guard !pendingCellEdits.isEmpty else { return [:] }
        let rows = Set(pendingCellEdits.keys.map(\.rowID))
        var cells: [ResultGridCellKey: QueryCell] = [:]
        for (rowIndex, row) in result.rows.enumerated() where rows.contains(row.id) {
            for (key, field) in pendingCellEdits where key.rowID == row.id && result.columns.indices.contains(key.column) {
                cells[ResultGridCellKey(row: rowIndex, column: key.column)] = Self.stagedCell(for: field)
            }
        }
        return cells
    }

    var pendingEditedRowCount: Int { Set(pendingCellEdits.keys.map(\.rowID)).count }

    /// One statement Submit will run: a single-row UPDATE of one table's edited columns, or a DELETE.
    struct PendingWrite: Identifiable {
        enum Kind { case update, delete }
        let id = UUID()
        let kind: Kind
        let rowID: QueryRow.ID
        let keys: [PendingCellKey]
        let fields: [(index: Int, field: DataEditorField)]
        let mutation: BoundQuery
    }

    /// The statements for every pending change, in row order, or a message saying why they can't be written.
    func plannedPendingWrites() -> Result<[PendingWrite], PendingWriteError> {
        guard let bookmark = selectedBookmark else { return .failure(.init(L10n.text("Choose a server first."))) }
        do { try enforceWritableConnection(bookmark) } catch { return .failure(.init(error.localizedDescription)) }
        let missingKey = PendingWriteError(L10n.text("This row cannot be saved because the primary key context is missing."))
        guard let editPlan else { return .failure(missingKey) }
        var writes: [PendingWrite] = []
        for row in result.rows {
            if pendingRowDeletions.contains(row.id) {
                guard editPlan.targets.count == 1, let delete = deleteSQL(for: row, target: editPlan.targets[0], engine: bookmark.engine) else {
                    return .failure(missingKey)
                }
                writes.append(PendingWrite(kind: .delete, rowID: row.id, keys: [], fields: [], mutation: delete))
                continue
            }
            let entries = pendingCellEdits.filter { $0.key.rowID == row.id }
            guard !entries.isEmpty else { continue }
            // One update per row and table: a joined row's edits to two tables are two single-row updates.
            let byTarget = Dictionary(grouping: entries) { editPlan.columns[$0.key.column]?.target ?? -1 }
            for target in byTarget.keys.sorted() {
                guard target >= 0, let staged = byTarget[target] else { return .failure(missingKey) }
                var draft = editDraft(for: row, target: target, plan: editPlan)
                guard draft.mode == .update else { return .failure(missingKey) }
                var changed: [(index: Int, field: DataEditorField)] = []
                for (key, value) in staged {
                    guard let name = editPlan.editableColumn(at: key.column)?.column.name,
                          let fieldIndex = draft.fields.firstIndex(where: { $0.isEditable && $0.column.name == name }) else { continue }
                    draft.fields[fieldIndex].value = value.value
                    draft.fields[fieldIndex].isNull = value.isNull
                    changed.append((key.column, draft.fields[fieldIndex]))
                }
                if let message = DataEditorValidationService.validate(fields: changed.map(\.field), mode: .update, engine: bookmark.engine).values.first {
                    return .failure(.init(message))
                }
                guard let mutation = mutationSQL(for: draft, engine: bookmark.engine) else { return .failure(missingKey) }
                writes.append(PendingWrite(kind: .update, rowID: row.id, keys: staged.map(\.key), fields: changed, mutation: mutation))
            }
        }
        return .success(writes)
    }

    struct PendingWriteError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// A DELETE of one row by its key, matched on the key's loaded values.
    private func deleteSQL(for row: QueryRow, target: ResultEditPlan.Target, engine: DatabaseEngine) -> BoundQuery? {
        guard engine.supportsRowEditing else { return nil }
        var values: [QueryBoundValue] = []
        var predicates: [String] = []
        for key in target.keyColumns {
            guard let cell = row.cells[safe: key.resultIndex], !cell.isNull, !cell.isBinary else { return nil }
            let field = DataEditorField(column: key.column, value: cell.displayValue, originalValue: cell.displayValue, isEditable: false)
            guard let value = DataEditorValidationService.boundValue(for: field) else { return nil }
            values.append(value)
            predicates.append(sqlIdentifier(key.column.name, engine: engine) + " = " + (engine == .postgresql ? "$\(values.count)" : "?"))
        }
        guard !predicates.isEmpty else { return nil }
        let limit = engine.isMySQLFamily ? "\nLIMIT 1" : ""
        return BoundQuery(sql: "DELETE FROM \(sqlQualifiedTable(target.table, engine: engine))\nWHERE \(predicates.joined(separator: " AND "))\(limit);", values: values)
    }

    /// Writes pending changes one statement at a time, each a bound single-row update or delete in a
    /// transaction that rolls back unless exactly one row changes. Deletions are shown in the preview
    /// before they run. A failure stops the run: statements already written stay written, the rest stay pending.
    func submitPendingEdits(confirmed: Bool = false) {
        guard hasPendingChanges, !isSubmittingPendingEdits, !isRunning, let bookmark = selectedBookmark else { return }
        if !pendingRowDeletions.isEmpty && !confirmed {
            isShowingChangePreview = true
            return
        }
        let writes: [PendingWrite]
        switch plannedPendingWrites() {
        case .success(let planned): writes = planned
        case .failure(let error): pendingEditError = error.message; return
        }
        guard !writes.isEmpty else { return }
        isShowingChangePreview = false
        isSubmittingPendingEdits = true
        pendingEditError = nil
        let databaseName = activeDatabaseName
        Task {
            var saved = 0
            for write in writes {
                do {
                    let written = try await DatabaseService.shared.execute(
                        query: write.mutation.sql,
                        values: write.mutation.values,
                        profile: bookmark,
                        database: databaseName,
                        policy: .mutation(expectedAffectedRows: 1)
                    )
                    if written.wroteWithoutRollback == true { noteWriteWithoutRollback(profile: bookmark, database: databaseName) }
                    saved += 1
                    switch write.kind {
                    case .update:
                        applyWrittenEdits(rowID: write.rowID, fields: write.fields)
                        for key in write.keys { pendingCellEdits[key] = nil }
                    case .delete:
                        removeDeletedRow(write.rowID)
                    }
                } catch {
                    let message = DatabaseErrorFormatter.message(for: error)
                    pendingEditError = saved == 0 ? message : L10n.format("Saved %1$d of %2$d rows. %3$@", saved, writes.count, message)
                    break
                }
            }
            isSubmittingPendingEdits = false
            if pendingEditError == nil { reloadAfterEdit() }
        }
    }


    private func noteWriteWithoutRollback(profile: ConnectionProfile, database: String?) {
        let name = database ?? profile.trimmedDefaultDatabase
        let key = "Portbase.noRollbackNotice." + profile.id.uuidString + "." + name
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        writeWithoutRollbackNotice = L10n.format("Some tables in %@ can’t undo a failed save, such as MyISAM tables. Each save still changes at most one row.", name)
    }

    private func removeDeletedRow(_ id: QueryRow.ID) {
        pendingRowDeletions.remove(id)
        pendingCellEdits = pendingCellEdits.filter { $0.key.rowID != id }
        result.rows.removeAll { $0.id == id }
        if resultSets.indices.contains(selectedResultIndex) { resultSets[selectedResultIndex] = result }
    }

    /// Shows written values in place, so rows saved before a failure don't look unsaved while others stay pending.
    private func applyWrittenEdits(rowID: QueryRow.ID, fields: [(index: Int, field: DataEditorField)]) {
        guard let rowIndex = result.rows.firstIndex(where: { $0.id == rowID }) else { return }
        // In a join, one table row can appear on several result rows (a customer on each of their
        // orders); every row showing the same key gets the written value, not just the one edited.
        var rows = [rowIndex]
        if let plan = editPlan, let target = fields.first.flatMap({ plan.columns[$0.index]?.target }) {
            let keys = plan.targets[target].keyColumns.map(\.resultIndex)
            let key = keys.map { result.rows[rowIndex].cells[safe: $0] }
            rows = result.rows.indices.filter { index in keys.map { result.rows[index].cells[safe: $0] } == key }
        }
        for row in rows {
            for (column, field) in fields where result.rows[row].cells.indices.contains(column) {
                result.rows[row].cells[column] = Self.stagedCell(for: field)
            }
        }
        // The tab's copy of the result keeps the written values too.
        if resultSets.indices.contains(selectedResultIndex) { resultSets[selectedResultIndex] = result }
    }

    /// An Explorer page is browsed again; a console query isn't re-run on the user's behalf, since its
    /// written values are already shown in place.
    private func reloadAfterEdit() {
        if isShowingExplorerResult { browse() }
    }

    /// Drops staged edits for rows that are no longer loaded, such as after a reload or page change.
    func prunePendingCellEdits() {
        guard hasPendingChanges else { return }
        let loaded = Set(result.rows.map(\.id))
        let kept = pendingCellEdits.filter { loaded.contains($0.key.rowID) }
        if kept.count != pendingCellEdits.count { pendingCellEdits = kept }
        let keptDeletions = pendingRowDeletions.intersection(loaded)
        if keptDeletions.count != pendingRowDeletions.count { pendingRowDeletions = keptDeletions }
    }

    static func stagedCell(for field: DataEditorField) -> QueryCell {
        if field.isNull { return .null }
        switch DataEditorValidationService.valueKind(for: field.column) {
        case .integer: return .integer(field.value)
        case .decimal: return .decimal(field.value)
        case .boolean: return .boolean(["1", "true", "yes"].contains(field.value.trimmingCharacters(in: .whitespaces).lowercased()))
        case .date, .dateTime, .time: return .dateTime(field.value)
        case .json: return .json(field.value)
        case .text, .uuid, .binary: return .text(field.value)
        }
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
        // A console query's row is updated where it is shown; its SQL is never replaced or re-run.
        let consoleRow: (rowID: QueryRow.ID, columns: [(index: Int, column: ResultEditPlan.MappedColumn)])? =
            draft.mode == .update && result.isExplorerGenerated != true
                ? draft.rowID.flatMap { id in editPlan.map { (id, $0.columns(of: 0)) } } : nil
        mutationTask = Task {
            do {
                let written = try await DatabaseService.shared.execute(
                    query: mutation.sql,
                    values: mutation.values,
                    profile: bookmark,
                    database: databaseName,
                    policy: .mutation(expectedAffectedRows: 1)
                )
                await MainActor.run {
                    if written.wroteWithoutRollback == true { self.noteWriteWithoutRollback(profile: bookmark, database: databaseName) }
                    guard self.mutationToken == token else { return }
                    self.mutationToken = nil
                    self.mutationTask = nil
                    self.isSavingMutation = false
                    self.dataEditorDraft = nil
                    self.dataEditorValidation = [:]
                    if let consoleRow {
                        let written = consoleRow.columns.compactMap { index, mapped in
                            draft.fields.first { $0.column.name == mapped.column.name }.map { (index, $0) }
                        }
                        self.applyWrittenEdits(rowID: consoleRow.rowID, fields: written)
                        return
                    }
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
            // On MySQL, LIMIT 1 means the keyed update can't touch a second row even on a table that can't roll back.
            let sql = """
            UPDATE \(tableName)
            SET \(assignments.joined(separator: ", "))
            WHERE \(predicates.joined(separator: " AND "))\(engine.isMySQLFamily ? "\nLIMIT 1" : "");
            """
            return BoundQuery(sql: sql, values: values)
        }
    }

    func sqlQualifiedTable(_ table: SchemaTableDescriptor, engine: DatabaseEngine) -> String {
        let tableName = sqlIdentifier(table.name, engine: engine)
        guard !table.schemaName.isEmpty else { return tableName }
        return "\(sqlIdentifier(table.schemaName, engine: engine)).\(tableName)"
    }

    func sqlIdentifier(_ value: String, engine: DatabaseEngine) -> String {
        switch engine {
        case .mysql, .mariadb:
            return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
        default:
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    func normalizedIdentifier(_ value: String) -> String {
        value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .lowercased()
    }

    func cancelMutation() {
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
