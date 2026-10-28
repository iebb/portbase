import XCTest
@testable import PortSQL

final class QueryPlanAndDuplicateTests: XCTestCase {
    private func result(_ columns: [String], _ rows: [[QueryCell]], source: String) -> QueryResultTable {
        QueryResultTable(columns: columns.map { QueryColumn(name: $0, type: "text") }, rows: rows.map { QueryRow(cells: $0) },
                         executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil,
                         sourceQuery: source, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: false)
    }

    func testPostgresPlanBuildsTreeWithCostsDetailsAndWarnings() throws {
        let lines = [
            "Sort  (cost=1.27..1.28 rows=3 width=72)",
            "  Sort Key: o.placed_at DESC",
            "  ->  Hash Join  (cost=1.09..1.25 rows=3 width=72)",
            "        Hash Cond: (o.customer_id = c.id)",
            "        ->  Seq Scan on orders o  (cost=0.00..1.12 rows=12 width=48)",
            "        ->  Hash  (cost=1.04..1.04 rows=4 width=36)",
            "              ->  Index Scan using customers_pkey on customers c  (cost=0.15..1.04 rows=4 width=36)",
        ]
        let table = result(["QUERY PLAN"], lines.map { [.text($0)] }, source: "EXPLAIN SELECT 1")
        XCTAssertTrue(QueryPlanService.isExplainResult(table))
        let plan = try XCTUnwrap(QueryPlanService.plan(from: table, engine: .postgresql))
        XCTAssertEqual(plan.nodes.map(\.title), ["Sort", "Hash Join", "Seq Scan on orders o", "Hash",
                                                 "Index Scan using customers_pkey on customers c"])
        XCTAssertEqual(plan.nodes.map(\.depth), [0, 1, 2, 2, 3])
        XCTAssertEqual(plan.nodes[0].details, ["Sort Key: o.placed_at DESC"])
        XCTAssertEqual(plan.nodes[1].details, ["Hash Cond: (o.customer_id = c.id)"])
        XCTAssertEqual(plan.nodes[2].totalCost, 1.12)
        XCTAssertEqual(plan.nodes[2].estimatedRows, 12)
        XCTAssertEqual(plan.nodes[2].warning, .fullScan)
        XCTAssertEqual(plan.nodes[0].warning, .temporarySort)
        XCTAssertNil(plan.nodes[4].warning)
        XCTAssertEqual(plan.maximumCost, 1.28)
        XCTAssertEqual(plan.warningCount, 2)
    }

    func testSQLiteAndMySQLPlans() throws {
        let sqlite = result(["id", "parent", "notused", "detail"], [
            [.integer("2"), .integer("0"), .integer("0"), .text("SCAN o")],
            [.integer("5"), .integer("0"), .integer("0"), .text("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)")],
            [.integer("9"), .integer("0"), .integer("0"), .text("USE TEMP B-TREE FOR ORDER BY")],
        ], source: "EXPLAIN QUERY PLAN SELECT 1")
        let sqlitePlan = try XCTUnwrap(QueryPlanService.plan(from: sqlite, engine: .sqlite))
        XCTAssertEqual(sqlitePlan.nodes.map(\.warning), [.fullScan, nil, .temporarySort])

        let mysql = result(["id", "select_type", "table", "type", "possible_keys", "key", "rows", "filtered", "Extra"], [
            [.integer("1"), .text("SIMPLE"), .text("orders"), .text("ALL"), .null, .null, .integer("1200"), .decimal("100"), .text("Using filesort")],
            [.integer("1"), .text("SIMPLE"), .text("customers"), .text("eq_ref"), .text("PRIMARY"), .text("PRIMARY"), .integer("1"), .decimal("100"), .null],
        ], source: "EXPLAIN SELECT 1")
        let mysqlPlan = try XCTUnwrap(QueryPlanService.plan(from: mysql, engine: .mysql))
        XCTAssertEqual(mysqlPlan.nodes[0].title, "SIMPLE · ALL · orders")
        XCTAssertEqual(mysqlPlan.nodes[0].warning, .fullScan)
        XCTAssertEqual(mysqlPlan.nodes[0].estimatedRows, 1200)
        XCTAssertNil(mysqlPlan.nodes[1].warning)
        XCTAssertTrue(mysqlPlan.nodes[1].details.contains { $0.contains("PRIMARY") })

        XCTAssertFalse(QueryPlanService.isExplainResult(result(["a"], [[.text("x")]], source: "SELECT 1")))
        let costs = QueryPlanService.splitCost("Limit  (cost=0.00..0.41 rows=10 width=4)")
        XCTAssertEqual(costs.0, "Limit")
        XCTAssertEqual(costs.2, 0.41)
    }

    @MainActor
    func testDuplicateRowCopiesValuesButLeavesKeysUniqueColumnsAndBytesEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Local", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = "missing.sqlite"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        // The view model holds its stores weakly, so the test keeps them alive.
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id

        let columns = [
            SchemaColumnDescriptor(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true, isUnique: true),
            SchemaColumnDescriptor(name: "email", type: "TEXT", isNullable: true, isPrimaryKey: false, isUnique: true),
            SchemaColumnDescriptor(name: "name", type: "TEXT", isNullable: false, isPrimaryKey: false, isUnique: false),
            SchemaColumnDescriptor(name: "note", type: "TEXT", isNullable: true, isPrimaryKey: false, isUnique: false),
            SchemaColumnDescriptor(name: "avatar", type: "BLOB", isNullable: true, isPrimaryKey: false, isUnique: false),
        ]
        workspace.schemaCatalog = [SchemaTableDescriptor(schemaName: "main", name: "people", columns: columns, rowCountEstimate: 1, objectKind: .table)]
        var loaded = QueryResultTable(columns: columns.map { QueryColumn(name: $0.name, type: $0.type) },
                                      rows: [QueryRow(cells: [.integer("7"), .text("a@example.com"), .text("Ada"), .null, .binary(Data([1, 2]))])],
                                      executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "main.people",
                                      sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: true)
        loaded.isExplorerGenerated = true
        workspace.result = loaded
        XCTAssertTrue(workspace.canInsertIntoCurrentTable)

        workspace.prepareDuplicate(row: loaded.rows[0])
        let draft = try XCTUnwrap(workspace.dataEditorDraft)
        XCTAssertEqual(draft.mode, .insert)
        let fields = Dictionary(uniqueKeysWithValues: draft.fields.map { ($0.column.name, $0) })
        XCTAssertEqual(fields["id"]?.value, "", "Primary keys are left for the database to assign")
        XCTAssertEqual(fields["email"]?.value, "", "Unique values aren't copied")
        XCTAssertEqual(fields["name"]?.value, "Ada")
        XCTAssertEqual(fields["note"]?.isNull, true, "NULL stays NULL rather than becoming empty text")
        XCTAssertEqual(fields["avatar"]?.value, "", "Binary values aren't copied into the form")
        withExtendedLifetime((bookmarks, library)) {}
    }

    @MainActor
    func testGridEditsStageUntilSubmitAndValidateByColumnType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Local", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = "missing.sqlite"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id

        let columns = [
            SchemaColumnDescriptor(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true, isUnique: true),
            SchemaColumnDescriptor(name: "name", type: "TEXT", isNullable: false, isPrimaryKey: false, isUnique: false),
            SchemaColumnDescriptor(name: "visits", type: "INTEGER", isNullable: true, isPrimaryKey: false, isUnique: false),
        ]
        workspace.schemaCatalog = [SchemaTableDescriptor(schemaName: "main", name: "people", columns: columns, rowCountEstimate: 2, objectKind: .table)]
        let loaded = QueryResultTable(columns: columns.map { QueryColumn(name: $0.name, type: $0.type) },
                                      rows: [QueryRow(cells: [.integer("1"), .text("Ada"), .integer("3")]),
                                             QueryRow(cells: [.integer("2"), .text("Lin"), .null])],
                                      executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "main.people",
                                      sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: true)
        workspace.result = loaded

        let rectangle = [ResultGridCellKey(row: 0, column: 1), .init(row: 0, column: 2),
                         .init(row: 1, column: 1), .init(row: 1, column: 2)]
        let bulk = try XCTUnwrap(workspace.cellsEdit(cells: rectangle))
        XCTAssertFalse(bulk.allowsNull, "One required column rules out setting the selection to NULL")
        XCTAssertNotNil(bulk.validationMessage(value: "many", isNull: false))
        XCTAssertThrowsError(try workspace.stageCells(cells: rectangle, value: "many", isNull: false))
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty, "Invalid cells prevent the whole selection from staging")
        try bulk.save("7", false)
        XCTAssertEqual(workspace.pendingCellEdits.count, 4)
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 0, column: 1)], .text("7"))
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 1, column: 2)], .integer("7"))
        let plannedBulk = try workspace.plannedPendingWrites().get()
        XCTAssertEqual(plannedBulk.count, 2, "Columns of each row share one single-row UPDATE")
        XCTAssertTrue(plannedBulk.allSatisfy { $0.fields.count == 2 })
        XCTAssertEqual(workspace.result, loaded, "Bulk Apply only stages; Submit writes the database")
        XCTAssertThrowsError(try workspace.stageCells(cells: rectangle, value: "", isNull: true))
        XCTAssertEqual(workspace.pendingCellEdits.count, 4, "A failed batch preserves existing edits")
        XCTAssertThrowsError(try workspace.stageCells(cells: rectangle + [.init(row: 0, column: 0)], value: "8", isNull: false))
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 0, column: 1)], .text("7"), "A key in the selection prevents every change")
        workspace.discardPendingEdits()
        let names = [ResultGridCellKey(row: 0, column: 1), .init(row: 1, column: 1)]
        try workspace.stageCells(cells: names, value: "", isNull: false)
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 0, column: 1)], .text(""), "Empty text stays distinct from NULL")
        let visits = [ResultGridCellKey(row: 0, column: 2), .init(row: 1, column: 2)]
        try workspace.stageCells(cells: visits, value: "", isNull: true)
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 0, column: 2)], .null)
        XCTAssertNil(workspace.pendingGridCells[.init(row: 1, column: 2)], "Restoring the original NULL removes its edit")
        workspace.discardPendingEdits()
        workspace.toggleRowDeletion(rowIndex: 1)
        XCTAssertNil(workspace.cellsEdit(cells: names), "Rows marked for deletion cannot receive edits")
        XCTAssertThrowsError(try bulk.save("9", false), "An open editor rechecks all destinations")
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty)
        workspace.discardPendingEdits()

        XCTAssertNil(workspace.editableField(rowIndex: 0, columnIndex: 0), "Key columns identify the row and aren't edited in place")
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "Grace"))
        XCTAssertNotNil(workspace.stageCellText(rowIndex: 0, columnIndex: 2, text: "many"), "Integers are validated before staging")
        XCTAssertNotNil(workspace.pendingEditError)
        workspace.stageCellNull(rowIndex: 0, columnIndex: 2)
        XCTAssertEqual(workspace.pendingCellEdits.count, 2)
        XCTAssertEqual(workspace.pendingEditedRowCount, 1)
        XCTAssertNil(workspace.pendingEditError)
        XCTAssertEqual(workspace.pendingGridCells[ResultGridCellKey(row: 0, column: 1)], .text("Grace"))
        XCTAssertEqual(workspace.pendingGridCells[ResultGridCellKey(row: 0, column: 2)], .null)
        XCTAssertEqual(workspace.result.rows[0].cells[1], .text("Ada"), "Nothing is written or shown as loaded until Submit")
        XCTAssertEqual(workspace.editableField(rowIndex: 0, columnIndex: 1)?.value, "Grace", "The value editor opens with the staged value")
        XCTAssertEqual(workspace.editableField(rowIndex: 0, columnIndex: 1)?.originalValue, "Ada")

        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "Ada"))
        XCTAssertNil(workspace.pendingGridCells[ResultGridCellKey(row: 0, column: 1)], "Typing the loaded value back drops the edit")
        XCTAssertNil(workspace.stageCellText(rowIndex: 1, columnIndex: 2, text: "5"))
        XCTAssertEqual(workspace.pendingGridCells[ResultGridCellKey(row: 1, column: 2)], .integer("5"))
        workspace.revertPendingCell(rowIndex: 1, columnIndex: 2)
        XCTAssertEqual(workspace.pendingCellEdits.count, 1)

        // Anything that would replace the loaded rows asks first and changes nothing until the edits are discarded.
        let clause = workspace.explorerOrderByClause
        workspace.sortExplorer(by: "name", descending: true)
        let sortRequest = try XCTUnwrap(workspace.pendingDiscardRequest)
        XCTAssertEqual(workspace.explorerOrderByClause, clause)
        workspace.keepPendingEdits(sortRequest)
        XCTAssertNil(workspace.pendingDiscardRequest)
        XCTAssertEqual(workspace.pendingCellEdits.count, 1, "Keep Editing leaves the staged edits")

        let people = try XCTUnwrap(workspace.schemaCatalog.first)
        let other = SchemaTableDescriptor(schemaName: "main", name: "orders", columns: columns, rowCountEstimate: 0, objectKind: .table)
        workspace.schemaCatalog.append(other)
        workspace.selectedExplorerTableID = other.id
        workspace.selectExplorerTable(other)
        workspace.keepPendingEdits(try XCTUnwrap(workspace.pendingDiscardRequest))
        XCTAssertEqual(workspace.selectedExplorerTableID, people.id, "Keeping the edits returns to their table")
        workspace.schemaCatalog.removeLast()

        workspace.sortExplorer(by: "name", descending: true)
        workspace.discardPendingEdits(andContinue: try XCTUnwrap(workspace.pendingDiscardRequest))
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty)
        XCTAssertTrue(workspace.explorerOrderByClause.hasSuffix("DESC"), "Discarding runs the held action")
        workspace.cancelQuery()
        workspace.result = loaded
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "Grace"))
        workspace.isRunning = true
        XCTAssertNil(workspace.editableField(rowIndex: 0, columnIndex: 2), "Cells can't be edited while a query is replacing the rows")
        workspace.isRunning = false

        workspace.result = QueryResultTable(columns: loaded.columns, rows: [QueryRow(cells: [.integer("1"), .text("Ada"), .integer("3")])],
                                            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "main.people",
                                            sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: true)
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty, "Edits for rows that are no longer loaded are dropped")
        XCTAssertThrowsError(try bulk.save("9", false), "An editor opened for old row identities cannot affect replacement results")
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty)

        // A read-only server, loaded from its own bookmark file so nothing touches the Keychain.
        var readOnly = profile
        readOnly.isReadOnly = true
        let readOnlyDir = dir.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        try encoder.encode([readOnly]).write(to: readOnlyDir.appendingPathComponent("bookmarks.json"))
        let readOnlyBookmarks = BookmarkStore(directory: readOnlyDir, cloudSyncEnabled: false)
        let readOnlyWorkspace = WorkspaceViewModel()
        readOnlyWorkspace.configure(bookmarkStore: readOnlyBookmarks, libraryStore: library)
        readOnlyWorkspace.selectedBookmarkID = readOnly.id
        readOnlyWorkspace.schemaCatalog = workspace.schemaCatalog
        readOnlyWorkspace.result = loaded
        XCTAssertNil(readOnlyWorkspace.editableField(rowIndex: 0, columnIndex: 1), "Read-only servers can't edit in place")
        XCTAssertNotNil(readOnlyWorkspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "Grace"))
        XCTAssertTrue(readOnlyWorkspace.pendingCellEdits.isEmpty)
        XCTAssertNil(readOnlyWorkspace.cellsEdit(cells: names))
        XCTAssertThrowsError(try readOnlyWorkspace.stageCells(cells: names, value: "Grace", isNull: false))
        XCTAssertTrue(readOnlyWorkspace.pendingCellEdits.isEmpty)
        withExtendedLifetime((bookmarks, library, readOnlyBookmarks)) {}
    }

#if canImport(UIKit)
    @MainActor
    func testBulkValuesSubmitAsBoundSingleRowUpdates() async throws {
        let file = try await SQLiteFileStore.shared.create(name: "bulk-\(UUID().uuidString.prefix(8))")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Scratch", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }
        let service = DatabaseService.shared
        for sql in ["CREATE TABLE notes (id INTEGER PRIMARY KEY, label TEXT, body TEXT)",
                    "INSERT INTO notes VALUES (1, 'a', 'first'), (2, 'b', 'second'), (3, 'c', 'untouched')"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        workspace.schemaCatalog = try await service.loadSchema(profile: profile, database: "main")
        let sql = "SELECT id, label, body FROM notes ORDER BY id"
        var loaded = try await service.execute(query: sql, profile: profile, policy: .readOnly)
        loaded.sourceQuery = sql
        workspace.result = loaded
        workspace.queryText = sql
        let rectangle = ResultGridSelection(anchor: .init(row: 0, column: 0), end: .init(row: 1, column: 1))
        let cells = rectangle.loadedCells(rowIndices: [1, 0, 2], visibleColumns: [2, 1])
        let edit = try XCTUnwrap(workspace.cellsEdit(cells: cells))
        let text = "it's ?; DROP TABLE notes; --"
        try edit.save(text, false)
        let writes = try workspace.plannedPendingWrites().get()
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { !$0.mutation.sql.contains(text) && $0.mutation.values.contains(.string(text)) })
        workspace.submitPendingEdits()
        XCTAssertThrowsError(try edit.save("changed during submit", false))
        for _ in 0..<200 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.pendingEditError)
        XCTAssertFalse(workspace.hasPendingChanges)
        XCTAssertEqual(workspace.queryText, sql)
        let stored = try await service.execute(query: sql, profile: profile, policy: .readOnly)
        XCTAssertEqual(stored.rows.map(\.cells), [
            [.integer("1"), .text(text), .text(text)], [.integer("2"), .text(text), .text(text)],
            [.integer("3"), .text("c"), .text("untouched")],
        ])
        XCTAssertEqual(workspace.result.rows.map(\.cells), stored.rows.map(\.cells), "Console results update without rerunning the query")
        withExtendedLifetime((bookmarks, library)) {}
    }

    /// Writes through a scratch SQLite file in the simulator's app container, then removes it.
    @MainActor
    func testSubmitWritesEachEditedRowAndReportsAFailedRow() async throws {
        let file = try await SQLiteFileStore.shared.create(name: "submit-test-\(UUID().uuidString.prefix(8))")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("submit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Scratch", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        // Selecting the bookmark starts reading the file; writing to it at the same time can find it busy.
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }

        let service = DatabaseService.shared
        _ = try await service.execute(query: "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, visits INTEGER)",
                                      profile: profile, policy: .userQuery(confirmed: true))
        _ = try await service.execute(query: "INSERT INTO people (id, name, visits) VALUES (1, 'Ada', 3), (2, 'Lin', NULL), (3, 'Kay', 1)",
                                      profile: profile, policy: .userQuery(confirmed: true))
        let columns = [
            SchemaColumnDescriptor(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true, isUnique: true),
            SchemaColumnDescriptor(name: "name", type: "TEXT", isNullable: false, isPrimaryKey: false, isUnique: false),
            SchemaColumnDescriptor(name: "visits", type: "INTEGER", isNullable: true, isPrimaryKey: false, isUnique: false),
        ]
        // Let any load started by selecting the bookmark finish, so it can't replace the rows edited below.
        for _ in 0..<200 where workspace.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        workspace.schemaCatalog = [SchemaTableDescriptor(schemaName: "main", name: "people", columns: columns, rowCountEstimate: 3, objectKind: .table)]
        // Row 3's loaded id no longer exists, so its update matches no row and must fail without writing.
        workspace.result = QueryResultTable(columns: columns.map { QueryColumn(name: $0.name, type: $0.type) },
                                            rows: [QueryRow(cells: [.integer("1"), .text("Ada"), .integer("3")]),
                                                   QueryRow(cells: [.integer("2"), .text("Lin"), .null]),
                                                   QueryRow(cells: [.integer("99"), .text("Gone"), .null])],
                                            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "main.people",
                                            sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: true)
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "Grace"))
        workspace.stageCellNull(rowIndex: 0, columnIndex: 2)
        XCTAssertNil(workspace.stageCellText(rowIndex: 1, columnIndex: 2, text: "8"))
        XCTAssertNil(workspace.stageCellText(rowIndex: 2, columnIndex: 1, text: "Nobody"))

        workspace.submitPendingEdits()
        for _ in 0..<200 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(workspace.isSubmittingPendingEdits)
        XCTAssertNotNil(workspace.pendingEditError, "The row that matches nothing is reported")
        XCTAssertEqual(workspace.pendingCellEdits.count, 1, "Only the failed row stays pending")
        XCTAssertEqual(workspace.result.rows[0].cells[1], .text("Grace"), "Written rows show their new values in place")
        XCTAssertEqual(workspace.result.rows[0].cells[2], .null)

        let stored = try await service.execute(query: "SELECT id, name, visits FROM people ORDER BY id", profile: profile, policy: .readOnly)
        XCTAssertEqual(stored.rows.map { $0.cells.map(\.displayValue) }, [["1", "Grace", ""], ["2", "Lin", "8"], ["3", "Kay", "1"]])
        XCTAssertTrue(stored.rows[0].cells[2].isNull)
        withExtendedLifetime((bookmarks, library)) {}
    }

    /// A console join's results are editable through the column origins SQLite reports: each table whose
    /// key is in the result, by its real column names, with computed values left alone.
    @MainActor
    func testConsoleJoinResultsEditEachTableThroughColumnOrigins() async throws {
        let file = try await SQLiteFileStore.shared.create(name: "join-edit-\(UUID().uuidString.prefix(8))")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Scratch", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        // Selecting the bookmark starts reading the file; writing to it at the same time can find it busy.
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }
        let service = DatabaseService.shared
        for sql in ["CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
                    "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER)",
                    "INSERT INTO customers VALUES (1, 'Ada'), (2, 'Lin')",
                    "INSERT INTO orders VALUES (10, 1, 5), (11, 2, 7)"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        // Let the load started by selecting the bookmark finish, so it can't replace what's set below.
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }
        workspace.schemaCatalog = try await service.loadSchema(profile: profile, database: "main")

        let sql = "SELECT o.id, o.total AS amount, c.id AS cid, c.name, o.total * 2 AS doubled FROM orders o JOIN customers c ON c.id = o.customer_id ORDER BY o.id"
        var loaded = try await service.execute(query: sql, profile: profile, policy: .readOnly)
        XCTAssertEqual(loaded.columns[1].origin?.column, "total", "SQLite reports the column an alias reads")
        XCTAssertNil(loaded.columns[4].origin, "and nothing for a computed value")
        loaded.sourceQuery = sql
        workspace.queryText = sql
        workspace.result = loaded
        XCTAssertTrue(workspace.canEditCurrentRows)
        XCTAssertEqual(workspace.resultKeyColumnNames, ["id", "cid"])
        XCTAssertNotNil(workspace.editableField(rowIndex: 0, columnIndex: 1), "orders.total, through its alias")
        XCTAssertNotNil(workspace.editableField(rowIndex: 0, columnIndex: 3), "customers.name")
        XCTAssertNil(workspace.editableField(rowIndex: 0, columnIndex: 4), "A computed value can't be written back")
        XCTAssertNil(workspace.editableField(rowIndex: 0, columnIndex: 0), "Keys name the row")

        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "9"))
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 3, text: "Grace"))
        workspace.submitPendingEdits()
        for _ in 0..<200 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.pendingEditError)
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty)
        XCTAssertEqual(workspace.result.rows[0].cells[1], .integer("9"))
        XCTAssertEqual(workspace.queryText, sql, "The console's SQL is left as it was")

        let orders = try await service.execute(query: "SELECT id, total FROM orders ORDER BY id", profile: profile, policy: .readOnly)
        XCTAssertEqual(orders.rows.map { $0.cells.map(\.displayValue) }, [["10", "9"], ["11", "7"]])
        let customers = try await service.execute(query: "SELECT id, name FROM customers ORDER BY id", profile: profile, policy: .readOnly)
        XCTAssertEqual(customers.rows.map { $0.cells.map(\.displayValue) }, [["1", "Grace"], ["2", "Lin"]])

        // A customer shown on two orders: writing their name updates both rows on screen.
        _ = try await service.execute(query: "INSERT INTO orders VALUES (12, 1, 3)", profile: profile, policy: .userQuery(confirmed: true))
        let both = "SELECT o.id, c.id AS cid, c.name FROM orders o JOIN customers c ON c.id = o.customer_id WHERE c.id = 1 ORDER BY o.id"
        var twice = try await service.execute(query: both, profile: profile, policy: .readOnly)
        twice.sourceQuery = both
        workspace.result = twice
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 2, text: "Ada L."))
        workspace.submitPendingEdits()
        for _ in 0..<200 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(workspace.result.rows.map { $0.cells[2] }, [.text("Ada L."), .text("Ada L.")])

        // A union or a self-join can't say which row a value belongs to.
        var union = try await service.execute(query: "SELECT id, name FROM customers UNION SELECT id, name FROM customers", profile: profile, policy: .readOnly)
        union.sourceQuery = "SELECT id, name FROM customers UNION SELECT id, name FROM customers"
        workspace.result = union
        XCTAssertFalse(workspace.canEditCurrentRows)
        let selfJoin = "SELECT a.id, a.name, b.id FROM customers a JOIN customers b ON b.id <> a.id"
        var paired = try await service.execute(query: selfJoin, profile: profile, policy: .readOnly)
        paired.sourceQuery = selfJoin
        workspace.result = paired
        XCTAssertFalse(workspace.canEditCurrentRows)
        withExtendedLifetime((bookmarks, library)) {}
    }

    /// Rows of a single-table result can be deleted, only after the preview is confirmed, one row per
    /// statement; a join's rows can't, since which table "this row" means is ambiguous.
    @MainActor
    func testDeletingRowsNeedsConfirmationAndRemovesExactlyThoseRows() async throws {
        let file = try await SQLiteFileStore.shared.create(name: "delete-\(UUID().uuidString.prefix(8))")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var profile = ConnectionProfile(name: "Scratch", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }
        let service = DatabaseService.shared
        for sql in ["CREATE TABLE tags (id INTEGER PRIMARY KEY, label TEXT)", "INSERT INTO tags VALUES (1, 'a'), (2, 'b'), (3, 'c')",
                    "CREATE TABLE notes (id INTEGER PRIMARY KEY, tag_id INTEGER)", "INSERT INTO notes VALUES (10, 1)"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        workspace.schemaCatalog = try await service.loadSchema(profile: profile, database: "main")

        let sql = "SELECT id, label FROM tags ORDER BY id"
        var tags = try await service.execute(query: sql, profile: profile, policy: .readOnly)
        tags.sourceQuery = sql
        workspace.result = tags
        XCTAssertTrue(workspace.canDeleteRow(rowIndex: 0))
        workspace.toggleRowDeletion(rowIndex: 0)
        workspace.toggleRowDeletion(rowIndex: 2)
        XCTAssertEqual(workspace.pendingDeletedGridRows, [0, 2])
        XCTAssertNil(workspace.stageCellText(rowIndex: 1, columnIndex: 1, text: "B"))
        XCTAssertEqual(workspace.pendingChangeCount, 3)

        let planned = try workspace.plannedPendingWrites().get()
        XCTAssertEqual(planned.map(\.kind), [.delete, .update, .delete])
        XCTAssertEqual(PendingChangesPreview.readable(planned[0].mutation, engine: .sqlite), "DELETE FROM \"main\".\"tags\"\nWHERE \"id\" = 1;")

        workspace.submitPendingEdits()
        XCTAssertTrue(workspace.isShowingChangePreview, "Deletions wait for the preview")
        XCTAssertFalse(workspace.isSubmittingPendingEdits)
        workspace.submitPendingEdits(confirmed: true)
        for _ in 0..<200 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.pendingEditError)
        XCTAssertFalse(workspace.hasPendingChanges)
        XCTAssertEqual(workspace.result.rows.map { $0.cells.map(\.displayValue) }, [["2", "B"]], "Deleted rows leave the results")
        let stored = try await service.execute(query: sql, profile: profile, policy: .readOnly)
        XCTAssertEqual(stored.rows.map { $0.cells.map(\.displayValue) }, [["2", "B"]])

        let join = "SELECT n.id, t.id AS tid, t.label FROM notes n JOIN tags t ON t.id = n.tag_id"
        var joined = try await service.execute(query: join, profile: profile, policy: .readOnly)
        joined.sourceQuery = join
        workspace.result = joined
        XCTAssertFalse(workspace.canDeleteRow(rowIndex: 0), "A join's row belongs to two tables")
        withExtendedLifetime((bookmarks, library)) {}
    }
#endif
}
