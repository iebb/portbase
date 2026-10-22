import XCTest
@testable import PortSQL

final class SchemaComparisonTests: XCTestCase {
    private func column(_ name: String, _ type: String, nullable: Bool = true, key: Bool = false) -> SchemaColumnDescriptor {
        SchemaColumnDescriptor(name: name, type: type, isNullable: nullable, isPrimaryKey: key, isUnique: key)
    }

    private func table(_ schema: String, _ name: String, _ columns: [SchemaColumnDescriptor]) -> SchemaTableDescriptor {
        SchemaTableDescriptor(schemaName: schema, name: name, columns: columns, rowCountEstimate: nil)
    }

    func testTablesAndColumnsAreComparedByName() {
        let staging = [
            table("shop_staging", "orders", [column("id", "int", nullable: false, key: true), column("total", "decimal(10,2)"), column("coupon", "text")]),
            table("shop_staging", "customers", [column("id", "int", nullable: false, key: true)]),
            table("shop_staging", "feature_flags", [column("name", "text")]),
        ]
        let production = [
            table("shop", "Orders", [column("id", "INT", nullable: false, key: true), column("total", "decimal(12,2)", nullable: false), column("legacy_ref", "text")]),
            table("shop", "customers", [column("id", "int", nullable: false, key: true)]),
            table("shop", "audit", [column("id", "int")]),
        ]
        let comparison = SchemaComparison.compare(source: staging, target: production)
        XCTAssertEqual(comparison.identicalTables, 1, "customers matches, though the databases are named differently")
        XCTAssertEqual(comparison.onlyInSource.map(\.name), ["feature_flags"])
        XCTAssertEqual(comparison.onlyInTarget.map(\.name), ["audit"])
        let orders = comparison.changed.first
        XCTAssertEqual(orders?.name, "orders", "Table names match without case")
        XCTAssertEqual(orders?.columns.map(\.column), ["total", "coupon", "legacy_ref"], "INT and int are the same type")
        XCTAssertEqual(orders?.columns.first?.details, ["decimal(10,2) → decimal(12,2)", "NULL → NOT NULL"])
        XCTAssertEqual(orders?.columns.map(\.kind), [.changed, .onlyInSource, .onlyInTarget])
    }

    func testSchemasArePartOfTheNameWhenEitherSideHasSeveral() {
        let a = [table("public", "users", []), table("billing", "users", [])]
        let b = [table("public", "users", [])]
        let comparison = SchemaComparison.compare(source: a, target: b)
        XCTAssertEqual(comparison.onlyInSource.map(\.name), ["billing.users"])
        XCTAssertEqual(comparison.identicalTables, 1)
    }

    func testReportListsEachDifference() {
        let comparison = SchemaComparison.compare(source: [table("a", "t", [column("x", "int")])], target: [table("b", "t", [column("x", "bigint")])])
        let report = comparison.report(source: "staging", target: "production")
        XCTAssertTrue(report.contains("~ t"))
        XCTAssertTrue(report.contains("~ x  int → bigint"))
        XCTAssertTrue(SchemaComparison.compare(source: [], target: []).isIdentical)
    }

    func testSavedQueriesGroupByFolderWithUnfiledLast() {
        let queries = [
            SavedQuerySnippet(title: "a", sql: "SELECT 1", folder: "Reports"),
            SavedQuerySnippet(title: "b", sql: "SELECT 2"),
            SavedQuerySnippet(title: "c", sql: "SELECT 3", folder: "Admin"),
            SavedQuerySnippet(title: "d", sql: "SELECT 4", folder: "  "),
            SavedQuerySnippet(title: "e", sql: "SELECT 5", folder: "Reports"),
        ]
        let groups = SavedQueryGrouping.groups(queries)
        XCTAssertEqual(groups.map(\.folder), ["Admin", "Reports", nil])
        XCTAssertEqual(groups[1].snippets.map(\.title), ["a", "e"], "Order within a folder is kept")
        XCTAssertEqual(groups[2].snippets.map(\.title), ["b", "d"], "A blank folder counts as none")
        // Copies saved before folders existed still decode.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"t","sql":"SELECT 1","note":"","createdAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(SavedQuerySnippet.self, from: Data(old.utf8)).folder)
    }
}
