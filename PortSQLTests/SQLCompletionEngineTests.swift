import XCTest
@testable import PortSQL

final class SQLCompletionEngineTests: XCTestCase {
    private func column(_ name: String, _ type: String, key: Bool = false) -> SchemaColumnDescriptor {
        SchemaColumnDescriptor(name: name, type: type, isNullable: !key, isPrimaryKey: key, isUnique: key)
    }

    private lazy var catalog: [SchemaTableDescriptor] = [
        SchemaTableDescriptor(schemaName: "public", name: "orders", columns: [
            column("id", "integer", key: true), column("customer_id", "integer"), column("total", "numeric"),
            column("status", "text"), column("created_at", "timestamp")], rowCountEstimate: 1_200),
        SchemaTableDescriptor(schemaName: "public", name: "customers", columns: [
            column("id", "integer", key: true), column("name", "text"), column("email", "text")], rowCountEstimate: 300),
        SchemaTableDescriptor(schemaName: "public", name: "order_items", columns: [
            column("id", "integer", key: true), column("order_id", "integer"), column("quantity", "integer")], rowCountEstimate: nil),
    ]

    /// Completes at the "|" in the text.
    private func complete(_ marked: String, engine: DatabaseEngine = .postgresql) -> (text: String, result: SQLCompletionResult) {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return (text, SQLCompletionEngine.complete(text, cursor: caret, catalog: catalog, activeDatabase: "shop", engine: engine))
    }

    private func applying(_ label: String, at marked: String, engine: DatabaseEngine = .postgresql) throws -> String {
        let (text, result) = complete(marked, engine: engine)
        let item = try XCTUnwrap(result.items.first { $0.label == label }, "No \(label) in \(result.items.map(\.label))")
        let applied = SQLCompletionEngine.apply(item, to: text, result: result)
        return (applied.text as NSString).replacingCharacters(in: NSRange(location: applied.cursor, length: 0), with: "|")
    }

    func testTablesAfterFromWithDetailsAndOpenOnTheirOwn() {
        let (_, result) = complete("SELECT * FROM ord|")
        XCTAssertEqual(result.items.first?.label, "orders")
        XCTAssertEqual(result.items.first?.kind, .table)
        XCTAssertTrue(result.items.first?.detail?.contains("5") == true, "Shows the column count")
        XCTAssertTrue(complete("SELECT * FROM |").result.opensAutomatically)
        XCTAssertFalse(complete("SELECT |").result.opensAutomatically, "Doesn't pop up after every space")
    }

    func testJoinSuggestsTheRelatedTableWithAliasAndCondition() throws {
        XCTAssertEqual(try applying("customers c", at: "SELECT * FROM orders o JOIN |"),
                       "SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id|")
        XCTAssertEqual(try applying("oi.order_id = o.id", at: "SELECT * FROM orders o JOIN order_items oi ON |"),
                       "SELECT * FROM orders o JOIN order_items oi ON oi.order_id = o.id |")
    }

    func testJoinsAreNotGuessedFromATableToItself() {
        let joins = complete("SELECT * FROM orders o JOIN |").result.items.filter { $0.kind == .join }
        XCTAssertFalse(joins.contains { $0.label.hasPrefix("orders ") })
        XCTAssertEqual(joins.first { $0.label == "customers c" }?.detail, "ON c.id = o.customer_id")
    }

    func testAliasDotListsThatTablesColumnsWithTypes() throws {
        let (_, result) = complete("SELECT o.| FROM orders o")
        XCTAssertEqual(Set(result.items.map(\.label)), ["id", "customer_id", "total", "status", "created_at"])
        XCTAssertEqual(result.items.first { $0.label == "total" }?.detail, "numeric")
        XCTAssertTrue(result.opensAutomatically)
        XCTAssertEqual(try applying("total", at: "SELECT o.to| FROM orders o"), "SELECT o.total| FROM orders o")
    }

    func testFuzzyMatchingByWordStarts() {
        XCTAssertEqual(complete("SELECT cid| FROM orders").result.items.first?.label, "customer_id")
        XCTAssertEqual(complete("SELECT at| FROM orders").result.items.first?.label, "created_at", "A later word of the name matches")
        XCTAssertNotNil(SQLCompletionEngine.matchQuality(name: "customer_id", needle: "custid"))
        XCTAssertNil(SQLCompletionEngine.matchQuality(name: "total", needle: "zz"))
    }

    func testOperatorsAfterAColumnFitItsType() {
        let text = complete("SELECT * FROM orders WHERE status |").result.items.map(\.label)
        XCTAssertTrue(text.contains("LIKE"))
        XCTAssertFalse(text.contains(">"), "Text columns don't get range operators first")
        XCTAssertTrue(complete("SELECT * FROM orders WHERE total |").result.items.map(\.label).contains(">="))
    }

    func testConnectivesAfterAValue() {
        let labels = complete("SELECT * FROM orders WHERE total > 10 |").result.items.map(\.label)
        XCTAssertEqual(Array(labels.prefix(2)), ["AND", "OR"])
        XCTAssertEqual(complete("SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id |").result.items.first?.label, "AND")
    }

    func testStarExpandsToTheColumnsInScope() throws {
        XCTAssertEqual(try applying("Expand * to columns", at: "SELECT *| FROM orders"),
                       "SELECT id, customer_id, total, status, created_at| FROM orders")
    }

    func testPickingAColumnBeforeFromAddsIt() throws {
        XCTAssertEqual(try applying("total", at: "SELECT tot|"), "SELECT total| FROM orders")
    }

    func testInsertOffersTheColumnListAndPutsTheCaretInValues() throws {
        XCTAssertEqual(try applying("orders (…) VALUES (…)", at: "INSERT INTO ord|"),
                       "INSERT INTO orders (id, customer_id, total, status, created_at) VALUES (|)")
    }

    func testGroupByOffersTheColumnsThatArentAggregated() throws {
        XCTAssertEqual(try applying("status, customer_id", at: "SELECT status, customer_id, COUNT(*) AS n FROM orders GROUP BY |"),
                       "SELECT status, customer_id, COUNT(*) AS n FROM orders GROUP BY status, customer_id|")
    }

    func testFunctionsPutTheCaretInsideTheirParentheses() throws {
        XCTAssertEqual(try applying("COALESCE(…)", at: "SELECT COAL| FROM orders"), "SELECT COALESCE(|) FROM orders")
        XCTAssertTrue(complete("SELECT date_tr| FROM orders").result.items.contains { $0.label == "DATE_TRUNC(…)" })
        XCTAssertFalse(complete("SELECT date_tr| FROM orders", engine: .mysql).result.items.contains { $0.label == "DATE_TRUNC(…)" },
                       "Functions follow the engine")
    }

    func testKeywordsFollowTheStatementsCase() throws {
        XCTAssertEqual(try applying("where", at: "select * from orders o wh|"), "select * from orders o where |")
    }

    func testColumnsComeFromTheStatementAtTheCaretOnly() {
        let labels = complete("SELECT * FROM customers; SELECT * FROM orders WHERE |").result.items.map(\.label)
        XCTAssertTrue(labels.contains("total"))
        XCTAssertFalse(labels.contains("email"))
    }

    func testAmbiguousColumnsAreQualified() {
        let items = complete("SELECT | FROM orders o JOIN customers c ON c.id = o.customer_id").result.items
        XCTAssertTrue(items.contains { $0.insertion == "o.id" })
        XCTAssertTrue(items.contains { $0.insertion == "c.id" })
        XCTAssertTrue(items.contains { $0.insertion == "total" }, "A name only one table has stays short")
    }

    func testNothingInsideStringsOrComments() {
        XCTAssertTrue(complete("SELECT * FROM orders WHERE status = 'pa|'").result.items.isEmpty)
        XCTAssertTrue(complete("SELECT * FROM orders -- ord|").result.items.isEmpty)
    }

    func testUpdateSetAssignsAndValuesFitTheColumn() throws {
        XCTAssertEqual(try applying("status", at: "UPDATE orders SET sta|"), "UPDATE orders SET status = |")
        XCTAssertEqual(try applying("'…'", at: "SELECT * FROM orders WHERE status = |"), "SELECT * FROM orders WHERE status = '|'")
    }

    func testAliasesComeFromTableInitials() {
        XCTAssertEqual(SQLCompletionEngine.Context.alias(for: "order_items", avoiding: []), "oi")
        XCTAssertEqual(SQLCompletionEngine.Context.alias(for: "orders", avoiding: ["o"]), "o2")
    }
}
