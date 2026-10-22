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
}
