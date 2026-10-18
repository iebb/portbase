import XCTest
@testable import PortSQL

final class SchemaDDLBuilderTests: XCTestCase {
    private let orders = SchemaObject(id: "public.orders", schema: "public", name: "orders", kind: .table)
    private let columns = [
        SchemaColumnDescriptor(name: "id", type: "integer", isNullable: false, isPrimaryKey: true, isUnique: true),
        SchemaColumnDescriptor(name: "total", type: "numeric", isNullable: false, isPrimaryKey: false, isUnique: false),
        SchemaColumnDescriptor(name: "note text", type: "text", isNullable: true, isPrimaryKey: false, isUnique: false),
    ]

    func testPostgresScriptAddsConstraintsAndOnlyIndexesThatDontBackThem() {
        var details = SchemaObjectDetails(definition: "CREATE TABLE \"public\".\"orders\" (\n  \"id\" integer NOT NULL\n);")
        details.constraints = ["CONSTRAINT \"orders_pkey\" PRIMARY KEY (id)"]
        details.indexes = [
            "CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)",
            "CREATE INDEX orders_total_idx ON public.orders USING btree (total)",
        ]
        let script = SchemaDDLBuilder.createScript(orders, details: details, engine: .postgresql)
        XCTAssertTrue(script.contains("ALTER TABLE \"public\".\"orders\" ADD CONSTRAINT \"orders_pkey\" PRIMARY KEY (id);"))
        XCTAssertTrue(script.contains("CREATE INDEX orders_total_idx ON public.orders USING btree (total);"))
        XCTAssertFalse(script.contains("CREATE UNIQUE INDEX orders_pkey"), "The primary key's own index isn't created twice")
    }

    func testSQLiteScriptAppendsIndexesAndMySQLKeepsItsStatement() {
        var details = SchemaObjectDetails(definition: "CREATE TABLE orders (id INTEGER PRIMARY KEY)")
        details.indexes = ["CREATE INDEX orders_day ON orders(day)", "UNIQUE (\"email\")"]
        let sqlite = SchemaDDLBuilder.createScript(SchemaObject(id: "o", schema: "main", name: "orders", kind: .table), details: details, engine: .sqlite)
        XCTAssertEqual(sqlite, "CREATE TABLE orders (id INTEGER PRIMARY KEY);\n\nCREATE INDEX orders_day ON orders(day);",
                       "Automatic indexes without SQL are left to the table definition")
        let mysql = SchemaDDLBuilder.createScript(orders, details: SchemaObjectDetails(definition: "CREATE TABLE `orders` (`id` int);"), engine: .mysql)
        XCTAssertEqual(mysql, "CREATE TABLE `orders` (`id` int);")
    }

    func testStatementsQuoteIdentifiersAndUseNamedParameters() {
        XCTAssertEqual(SchemaDDLBuilder.dropStatement(orders, engine: .mysql), "DROP TABLE `public`.`orders`;")
        let function = SchemaObject(id: "f", schema: "public", name: "total", kind: .function, signature: "integer, text")
        XCTAssertEqual(SchemaDDLBuilder.dropStatement(function, engine: .postgresql), "DROP FUNCTION \"public\".\"total\"(integer, text);")
        XCTAssertEqual(SchemaDDLBuilder.insertStatement(orders, columns: columns, engine: .postgresql),
                       "INSERT INTO \"public\".\"orders\" (\"id\", \"total\", \"note text\")\nVALUES (:id, :total, :note_text);")
        let update = SchemaDDLBuilder.updateStatement(orders, columns: columns, engine: .postgresql)
        XCTAssertTrue(update.hasSuffix("WHERE \"id\" = :id;"), update)
        XCTAssertTrue(update.contains("SET \"total\" = :total"))
        XCTAssertTrue(SchemaDDLBuilder.selectStatement(orders, columns: columns, engine: .sqlite).hasSuffix("FROM \"public\".\"orders\"\nLIMIT 100;"))
    }
}
