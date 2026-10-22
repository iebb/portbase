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

/// Completion and inspection run as the user types, so their cost must not grow with the square of the
/// schema or the script. The limits are loose enough for a slow test machine and far below the seconds a
/// quadratic pass took on this input.
final class EditorAssistPerformanceTests: XCTestCase {
    func testCompletionAndInspectionStayFastOnLargeSchemasAndScripts() {
        let catalog = (0..<2000).map { t in
            SchemaTableDescriptor(schemaName: "shop", name: "table_\(t)", columns: (0..<40).map { c in
                SchemaColumnDescriptor(name: c == 0 ? "id" : (c == 1 ? "customer_id" : "col_\(c)_value"), type: "int",
                                       isNullable: c != 0, isPrimaryKey: c == 0, isUnique: c == 0)
            }, rowCountEstimate: 1000)
        }
        let script = (0..<300).map { "SELECT t.col_\($0 % 30)_value, COUNT(*) FROM table_\($0) t WHERE t.id > \($0);" }.joined(separator: "\n")
        func seconds(_ body: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent(); body(); return CFAbsoluteTimeGetCurrent() - start
        }
        XCTAssertLessThan(seconds { _ = SQLInspection.hints(for: script, catalog: catalog, engine: .mysql, cursor: 5000) }, 0.5)
        XCTAssertLessThan(seconds { _ = SQLInspection.unknownColumns(in: script, catalog: catalog, engine: .mysql) }, 1.0)
        let join = "SELECT * FROM table_7 t JOIN "
        XCTAssertLessThan(seconds { _ = SQLCompletionEngine.complete(join, cursor: (join as NSString).length, catalog: catalog, activeDatabase: "shop", engine: .mysql) }, 0.5)
        XCTAssertLessThan(seconds { _ = SQLCompletionEngine.clauseSuggestions("col_3", kind: .filter, table: catalog[7], catalog: catalog, activeDatabase: "shop", engine: .mysql) }, 0.1)
        XCTAssertLessThan(seconds { _ = SQLEditorDecorations.marks(in: script, selection: NSRange(location: 5000, length: 0), engine: .mysql) }, 0.3)
    }
}
