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

    func testFormattingPreservesLiteralsIdentifiersCommentsAndDollarQuotedBodies() {
        let sql = "select 'select  from where', \"order by\", $body$select from; \nwhere$body$, E'it\\'s from' from users -- where select\nwhere id = 1 /* outer /* where */ select */"
        let formatted = SQLAssistService.format(sql)
        for protected in ["'select  from where'", "\"order by\"", "$body$select from; \nwhere$body$", "E'it\\'s from'", "-- where select\n", "/* outer /* where */ select */"] {
            XCTAssertTrue(formatted.contains(protected), protected)
        }
        XCTAssertTrue(formatted.hasPrefix("SELECT"))
        XCTAssertEqual(SQLAssistService.format(#"select 'a\' from t where x = 'b'"#, engine: .mysql), #"select 'a\' from t where x = 'b'"#)
    }

    func testUnicodeSelectionAndCompletionDoNotRewriteOtherText() throws {
        let sql = "SELECT '👩🏽‍💻  日本語'; SELECT * FROM ord"
        let applied = SQLAssistService.applySuggestion("orders", to: sql, cursorOffset: sql.utf16.count)
        XCTAssertEqual(applied.query, "SELECT '👩🏽‍💻  日本語'; SELECT * FROM orders")
        XCTAssertEqual(applied.cursorOffset, applied.query.utf16.count)
        let range = (sql as NSString).range(of: "SELECT * FROM ord")
        let selection = try XCTUnwrap(SQLEditingService.selection(in: sql, offset: range.location, length: range.length))
        XCTAssertEqual(String(sql[selection]), "SELECT * FROM ord")
        XCTAssertNil(SQLEditingService.selection(in: sql, offset: sql.utf16.count, length: 1))
        XCTAssertTrue(SQLAssistService.suggestions(for: "SELECT 'from'", catalog: [], activeDatabase: nil, cursorOffset: 10).isEmpty)
        XCTAssertEqual(SQLAssistService.applySuggestion("id", to: "SELECT ", cursorOffset: 7).query, "SELECT id")
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
