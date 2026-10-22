import XCTest
@testable import PortSQL

final class SchemaDiagramLayoutTests: XCTestCase {
    private func table(_ name: String, _ columns: [String], key: String = "id") -> SchemaTableDescriptor {
        SchemaTableDescriptor(schemaName: "public", name: name, columns: columns.map {
            SchemaColumnDescriptor(name: $0, type: "integer", isNullable: $0 != key, isPrimaryKey: $0 == key, isUnique: $0 == key)
        }, rowCountEstimate: nil)
    }

    private func link(_ from: String, _ column: String, to: String) -> SchemaRelationship {
        SchemaRelationship(schema: "public", table: from, key: SchemaForeignKey(id: from + "." + column, name: from + "_" + column + "_fkey",
            columns: [column], referencedSchema: "public", referencedTable: to, referencedColumns: ["id"]))
    }

    private lazy var catalog = [
        table("customers", ["id", "name", "email"]),
        table("orders", ["id", "customer_id", "product_id", "total"]),
        table("products", ["id", "name"]),
        table("audit_log", ["id", "message"]),
        table("wide", (1...12).map { "c\($0)" }, key: "c1"),
    ]

    func testRelatedTablesAreLaidOutInColumnsFromTheBusiestTable() {
        let layout = SchemaDiagramLayout.make(catalog: catalog, relationships: [link("orders", "customer_id", to: "customers"),
                                                                               link("orders", "product_id", to: "products")],
                                              includeUnrelated: false)
        XCTAssertEqual(Set(layout.nodes.map(\.id)), ["public.orders", "public.customers", "public.products"], "Unrelated tables left out")
        let orders = layout.nodes.first { $0.id == "public.orders" }!
        let customers = layout.nodes.first { $0.id == "public.customers" }!
        XCTAssertLessThan(orders.frame.minX, customers.frame.minX, "The table with the most links starts the first column")
        XCTAssertEqual(orders.columns.map(\.name).prefix(3), ["id", "customer_id", "product_id"], "Keys, then foreign keys, first")
        XCTAssertEqual(layout.edges.count, 2)
        XCTAssertEqual(layout.edges.first { $0.to == "public.customers" }?.fromRow, 1, "The line leaves from the foreign key's row")
        XCTAssertEqual(layout.edges.first { $0.to == "public.customers" }?.toRow, 0, "and arrives at the referenced key")
        for (a, b) in zip(layout.nodes, layout.nodes.dropFirst()) { XCTAssertFalse(a.frame.intersects(b.frame), "Tables don't overlap") }
        XCTAssertTrue(layout.nodes.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0.frame) })
    }

    func testUnrelatedTablesFollowInAGridAndLongTablesAreCut() {
        let layout = SchemaDiagramLayout.make(catalog: catalog, relationships: [link("orders", "customer_id", to: "customers")], includeUnrelated: true)
        XCTAssertEqual(layout.nodes.count, 5)
        let wide = layout.nodes.first { $0.id == "public.wide" }!
        XCTAssertEqual(wide.columns.count, SchemaDiagramLayout.maximumRows)
        XCTAssertEqual(wide.hiddenColumns, 12 - SchemaDiagramLayout.maximumRows)
        let related = layout.nodes.filter { $0.id == "public.orders" || $0.id == "public.customers" }.map(\.frame.maxY).max()!
        XCTAssertGreaterThan(wide.frame.minY, related, "Unrelated tables come after the related ones")
    }

    func testKeysToTablesOutsideTheCatalogAreSkipped() {
        let layout = SchemaDiagramLayout.make(catalog: catalog, relationships: [link("orders", "customer_id", to: "elsewhere")], includeUnrelated: false)
        XCTAssertTrue(layout.nodes.isEmpty)
        XCTAssertTrue(layout.edges.isEmpty)
    }
}
