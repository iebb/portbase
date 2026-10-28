import XCTest
@testable import PortSQL

final class ResultEditPlannerTests: XCTestCase {
    private func column(_ name: String, key: Bool = false, generated: Bool = false) -> SchemaColumnDescriptor {
        var column = SchemaColumnDescriptor(name: name, type: "text", isNullable: !key, isPrimaryKey: key, isUnique: key)
        column.isGenerated = generated
        return column
    }

    private lazy var catalog: [SchemaTableDescriptor] = [
        SchemaTableDescriptor(schemaName: "public", name: "orders", columns: [column("id", key: true), column("customer_id"), column("total"),
                                                                              column("total_with_tax", generated: true)], rowCountEstimate: nil),
        SchemaTableDescriptor(schemaName: "public", name: "customers", columns: [column("id", key: true), column("name")], rowCountEstimate: nil),
        SchemaTableDescriptor(schemaName: "public", name: "notes", columns: [column("body")], rowCountEstimate: nil),
        SchemaTableDescriptor(schemaName: "audit", name: "customers", columns: [column("id", key: true), column("name")], rowCountEstimate: nil),
    ]

    private func result(_ columns: [(String, (String, String)?)]) -> [QueryColumn] {
        columns.map { name, origin in
            QueryColumn(name: name, type: "text", origin: origin.map { QueryColumnOrigin(schema: "public", table: $0.0, column: $0.1) })
        }
    }

    func testJoinsEditEachTableWhoseKeyIsInTheResult() {
        let columns = result([("order_id", ("orders", "id")), ("amount", ("orders", "total")), ("id", ("customers", "id")),
                              ("name", ("customers", "name")), ("n", nil)])
        let plan = ResultEditPlanner.originPlan(columns: columns, statement: "SELECT o.id AS order_id, o.total AS amount, c.id, c.name, 1 AS n FROM orders o JOIN customers c ON c.id = o.customer_id",
                                                catalog: catalog, engine: .postgresql)
        XCTAssertEqual(plan?.targets.map(\.table.name).sorted(), ["customers", "orders"])
        XCTAssertEqual(plan?.editableColumn(at: 1)?.column.name, "total", "An alias edits the column it names")
        XCTAssertEqual(plan.map { $0.targets[$0.columns[3]!.target].table.name }, "customers")
        XCTAssertNil(plan?.editableColumn(at: 0), "Keys aren't edited in place")
        XCTAssertEqual(plan?.columns[0]?.column.name, "id", "but are part of the row")
        XCTAssertNil(plan?.columns[4], "Computed values have no origin")
    }

    func testTablesWithoutTheirKeyOrReadTwiceStayReadOnly() {
        let noKey = result([("total", ("orders", "total"))])
        XCTAssertNil(ResultEditPlanner.originPlan(columns: noKey, statement: "SELECT total FROM orders", catalog: catalog, engine: .postgresql))
        let selfJoin = result([("id", ("orders", "id")), ("total", ("orders", "total")), ("id", ("orders", "id"))])
        XCTAssertNil(ResultEditPlanner.originPlan(columns: selfJoin, statement: "SELECT a.id, a.total, b.id FROM orders a JOIN orders b ON true",
                                                  catalog: catalog, engine: .postgresql))
        let keyless = result([("body", ("notes", "body"))])
        XCTAssertNil(ResultEditPlanner.originPlan(columns: keyless, statement: "SELECT body FROM notes", catalog: catalog, engine: .postgresql),
                     "A table with no key can't name one row")
    }

    func testSetOperationsAndGeneratedColumnsStayReadOnly() {
        let columns = result([("id", ("orders", "id")), ("total", ("orders", "total")), ("total_with_tax", ("orders", "total_with_tax"))])
        XCTAssertNil(ResultEditPlanner.originPlan(columns: columns, statement: "SELECT id, total, total_with_tax FROM orders UNION SELECT 1, 2, 3",
                                                  catalog: catalog, engine: .postgresql))
        let plan = ResultEditPlanner.originPlan(columns: columns, statement: "SELECT id, total, total_with_tax FROM orders", catalog: catalog, engine: .postgresql)
        XCTAssertNotNil(plan?.editableColumn(at: 1))
        XCTAssertNil(plan?.editableColumn(at: 2), "Generated columns are the database's")
    }

    func testANamedSchemaMustMatchExactly() {
        let columns = [QueryColumn(name: "id", type: "int", origin: QueryColumnOrigin(schema: "audit", table: "customers", column: "id")),
                       QueryColumn(name: "name", type: "text", origin: QueryColumnOrigin(schema: "audit", table: "customers", column: "name"))]
        XCTAssertEqual(ResultEditPlanner.originPlan(columns: columns, statement: "SELECT id, name FROM audit.customers", catalog: catalog, engine: .postgresql)?
            .targets.first?.table.schemaName, "audit")
        let elsewhere = columns.map { column -> QueryColumn in
            var copy = column; copy.origin?.schema = "archive"; return copy
        }
        XCTAssertNil(ResultEditPlanner.originPlan(columns: elsewhere, statement: "SELECT id, name FROM archive.customers", catalog: catalog, engine: .postgresql),
                     "A same-named table in another schema is a different table")
        let unresolved = [QueryColumn(name: "id", type: "int", origin: QueryColumnOrigin(postgresTableOID: 16384, postgresAttributeNumber: 1))]
        XCTAssertNil(ResultEditPlanner.originPlan(columns: unresolved, statement: "SELECT id FROM t", catalog: catalog, engine: .postgresql),
                     "Nothing is editable until the origin has names")
    }

    func testExplorerPlansKeepTheirByNameRules() {
        let table = catalog[0]
        let plan = ResultEditPlanner.explorerPlan(table: table, columns: ["id", "customer_id", "total"].map { QueryColumn(name: $0, type: "text") })
        XCTAssertEqual(plan?.targets.first?.keyColumns.map(\.resultIndex), [0])
        XCTAssertEqual(Set((0..<3).filter { plan?.editableColumn(at: $0) != nil }), [1, 2])
        XCTAssertNil(ResultEditPlanner.explorerPlan(table: table, columns: ["total"].map { QueryColumn(name: $0, type: "text") }))
    }

    func testThePreviewWritesValuesInWithoutTouchingQuotedText() {
        let mysql = BoundQuery(sql: "UPDATE `t` SET `note` = ? WHERE `id` = ? AND `label` = '?';", values: [.string("it's"), .integer(7)])
        XCTAssertEqual(PendingChangesPreview.readable(mysql, engine: .mysql), "UPDATE `t` SET `note` = 'it''s' WHERE `id` = 7 AND `label` = '?';")
        let postgres = BoundQuery(sql: "UPDATE t SET a = $1, b = $10 WHERE id = $2", values: (1...10).map { .integer(Int64($0)) })
        XCTAssertEqual(PendingChangesPreview.readable(postgres, engine: .postgresql), "UPDATE t SET a = 1, b = 10 WHERE id = 2")
    }

    // MARK: Grid editing

    func testPastedTextReadsWhatTheGridCopies() {
        let payload = ResultGridClipboard.Payload(
            columns: [QueryColumn(name: "a", type: "text"), QueryColumn(name: "b", type: "text")],
            rows: [QueryRow(cells: [.text("tab\there"), .null]), QueryRow(cells: [.text("say \"hi\"\nbye"), .text("NULL")]),
                   QueryRow(cells: [.text(""), .integer("7")])])
        let text = ResultGridClipboard.text(payload, headers: false)
        XCTAssertEqual(ResultGridClipboard.parse(text), [["tab\there", nil], ["say \"hi\"\nbye", "NULL"], ["", "7"]],
                       "Quoted values keep tabs, line breaks and the text NULL; a bare NULL is SQL NULL")
        XCTAssertEqual(ResultGridClipboard.parse("1\tx\r\n2\ty\n"), [["1", "x"], ["2", "y"]], "Spreadsheet text, with a final line break")
        XCTAssertEqual(ResultGridClipboard.parse("one value"), [["one value"]])
        XCTAssertEqual(ResultGridClipboard.parse("a\t\tc"), [["a", "", "c"]], "An empty field between tabs is empty text")
    }

    func testShortcutsRunTheirEnabledMenuItem() {
        var ran: [String] = []
        let items: [ResultGridMenuItem] = [
            .action("Off", enabled: false, shortcut: .setNull) { ran.append("off") },
            .submenu("More", nil, [.action("Null", shortcut: .setNull) { ran.append("null") }]),
            .action("Revert", shortcut: .revert) { ran.append("revert") },
        ]
        ResultGridMenuItem.action(for: .setNull, in: items)?()
        ResultGridMenuItem.action(for: .revert, in: items)?()
        XCTAssertNil(ResultGridMenuItem.action(for: .cloneRow, in: items))
        XCTAssertEqual(ran, ["null", "revert"], "A disabled item doesn't take its shortcut from an enabled one in a submenu")
    }

    @MainActor
    func testSelectionValuesStageTogetherAndRowsDeleteAndRevertTogether() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grid-\(UUID().uuidString)")
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
        workspace.schemaCatalog = [SchemaTableDescriptor(schemaName: "main", name: "people", columns: columns, rowCountEstimate: 3, objectKind: .table)]
        workspace.result = QueryResultTable(columns: columns.map { QueryColumn(name: $0.name, type: $0.type) },
                                            rows: [QueryRow(cells: [.integer("1"), .text("Ada"), .integer("3")]),
                                                   QueryRow(cells: [.integer("2"), .text("Lin"), .null]),
                                                   QueryRow(cells: [.integer("3"), .text("Kay"), .integer("1")])],
                                            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "main.people",
                                            sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: true)

        // A pasted block: each cell its own value, NULL where the clipboard had NULL.
        XCTAssertNil(workspace.stageGridValues([(.init(row: 0, column: 1), "Grace"), (.init(row: 0, column: 2), nil),
                                                (.init(row: 1, column: 1), "Linus"), (.init(row: 1, column: 2), "5")]))
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 0, column: 2)], .null)
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 1, column: 2)], .integer("5"))
        XCTAssertEqual(workspace.pendingCellEdits.count, 4)

        // One bad cell stages none of them, and says which column.
        let failure = workspace.stageGridValues([(.init(row: 2, column: 2), "8"), (.init(row: 2, column: 1), nil)])
        XCTAssertEqual(failure?.hasPrefix("name"), true)
        XCTAssertNil(workspace.pendingGridCells[.init(row: 2, column: 2)])
        XCTAssertNotNil(workspace.stageGridValues([(.init(row: 2, column: 0), "9")]), "Keys aren't edited in place")
        XCTAssertNotNil(workspace.pendingEditError)

        // Revert Selected drops the staged values inside the selection only.
        workspace.revertGridCells([.init(row: 0, column: 1), .init(row: 0, column: 2)], rows: [0])
        XCTAssertNil(workspace.pendingGridCells[.init(row: 0, column: 1)])
        XCTAssertEqual(workspace.pendingGridCells[.init(row: 1, column: 1)], .text("Linus"))

        // Delete Selected Rows marks each row, dropping its staged values; again restores them all.
        XCTAssertTrue(workspace.canToggleRowsDeletion([1, 2]))
        workspace.toggleRowsDeletion([1, 2])
        XCTAssertEqual(workspace.pendingDeletedGridRows, [1, 2])
        XCTAssertTrue(workspace.pendingCellEdits.isEmpty)
        workspace.toggleRowsDeletion([0, 1])
        XCTAssertEqual(workspace.pendingDeletedGridRows, [0, 1, 2], "A selection that isn't all marked is marked")
        workspace.toggleRowsDeletion([0, 1])
        XCTAssertEqual(workspace.pendingDeletedGridRows, [2])
        workspace.revertGridCells([], rows: [2])
        XCTAssertFalse(workspace.hasPendingChanges)
        withExtendedLifetime((bookmarks, library)) {}
    }

#if canImport(UIKit)
    /// A row's referencing rows: the foreign keys pointing at its table, opened with the row's key bound.
    @MainActor
    func testReferencingRowsOpenThroughForeignKeysPointingHere() async throws {
        let file = try await SQLiteFileStore.shared.create(name: "refs-\(UUID().uuidString.prefix(8))")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refs-\(UUID().uuidString)")
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
        for sql in ["CREATE TABLE tags (id INTEGER PRIMARY KEY, label TEXT)", "INSERT INTO tags VALUES (1, 'a'), (2, 'b')",
                    "CREATE TABLE notes (id INTEGER PRIMARY KEY, tag_id INTEGER REFERENCES tags(id))",
                    "INSERT INTO notes VALUES (10, 1), (11, 2), (12, 1)"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        let catalog = try await service.loadSchema(profile: profile, database: "main")
        workspace.schemaCatalog = catalog
        let tags = try XCTUnwrap(catalog.first { $0.name == "tags" })
        let references = try await service.schemaReferencingKeys(table: tags, catalog: catalog, profile: profile, database: "main")
        XCTAssertEqual(references.map(\.table), ["notes"])
        XCTAssertEqual(references.first?.key.columns, ["tag_id"])

        let rows = try await service.execute(query: "SELECT id, label FROM tags ORDER BY id", profile: profile, policy: .readOnly)
        workspace.result = rows
        workspace.followReference(try XCTUnwrap(references.first), row: rows.rows[0])
        for _ in 0..<250 where workspace.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(workspace.activeBoundQuery?.values, [.integer(1)], "The row's key is bound, never written into the SQL")
        XCTAssertEqual(Set(workspace.result.rows.map { $0.cells[0] }), [.integer("10"), .integer("12")])
        withExtendedLifetime((bookmarks, library)) {}
    }
#endif
}
