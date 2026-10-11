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
}
