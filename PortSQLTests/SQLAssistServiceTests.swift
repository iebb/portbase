import XCTest
@testable import PortSQL

final class SQLAssistServiceTests: XCTestCase {
    func testSuggestionsPreferActiveDatabaseTableName() {
        let suggestions = SQLAssistService.suggestions(
            for: "SELECT * FROM or",
            catalog: [ordersTable],
            activeDatabase: "shop",
            cursorOffset: "SELECT * FROM or".count
        )

        XCTAssertEqual(suggestions.first, "orders")
        XCTAssertTrue(suggestions.contains("shop.orders"))
    }

    func testSuggestionsResolveTableColumnsAfterWhere() {
        let query = "SELECT * FROM orders WHERE "
        let suggestions = SQLAssistService.suggestions(
            for: query,
            catalog: [ordersTable],
            activeDatabase: "shop",
            cursorOffset: query.count
        )

        XCTAssertTrue(suggestions.contains("orders.total"))
        XCTAssertTrue(suggestions.contains("total"))
    }

    func testApplySuggestionReplacesActiveFragmentAndAddsKeywordSpacing() {
        let applied = SQLAssistService.applySuggestion(
            "ORDER BY",
            to: "SELECT * FROM orders ord",
            cursorOffset: "SELECT * FROM orders ord".count
        )

        XCTAssertEqual(applied.query, "SELECT * FROM orders ORDER BY ")
        XCTAssertEqual(applied.cursorOffset, applied.query.count)
    }

    func testHintsFlagBroadSelectAndUnsafeMutations() {
        let hints = SQLAssistService.hints(for: "SELECT * FROM users")
        XCTAssertTrue(hints.contains { $0.title == "Projection can be narrower" })
        XCTAssertTrue(hints.contains { $0.title == "Consider a LIMIT" })

        let deleteHints = SQLAssistService.hints(for: "DELETE FROM users")
        XCTAssertTrue(deleteHints.contains { $0.title == "DELETE without WHERE" && $0.severity == .critical })
    }

    func testFormatPromotesCommonClausesToSeparateLines() {
        let formatted = SQLAssistService.format("select id from users where active = true order by id")

        XCTAssertEqual(formatted, "SELECT id\nFROM users\nWHERE active = true\nORDER BY id")
    }

    private var ordersTable: SchemaTableDescriptor {
        SchemaTableDescriptor(
            schemaName: "shop",
            name: "orders",
            columns: [
                SchemaColumnDescriptor(name: "id", type: "integer", isNullable: false, isPrimaryKey: true, isUnique: true),
                SchemaColumnDescriptor(name: "customer_id", type: "integer", isNullable: false, isPrimaryKey: false, isUnique: false),
                SchemaColumnDescriptor(name: "total", type: "decimal", isNullable: false, isPrimaryKey: false, isUnique: false)
            ],
            rowCountEstimate: 20
        )
    }
}
