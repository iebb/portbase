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

final class SQLEditorSmartsTests: XCTestCase {
    private func column(_ name: String, _ type: String, key: Bool = false) -> SchemaColumnDescriptor {
        SchemaColumnDescriptor(name: name, type: type, isNullable: !key, isPrimaryKey: key, isUnique: key)
    }

    private lazy var catalog: [SchemaTableDescriptor] = [
        SchemaTableDescriptor(schemaName: "public", name: "orders", columns: [column("id", "integer", key: true), column("total", "numeric"),
            column("created_at", "timestamp")], rowCountEstimate: nil),
        SchemaTableDescriptor(schemaName: "public", name: "customers", columns: [column("id", "integer", key: true), column("name", "text")], rowCountEstimate: nil),
    ]

    private func complete(_ marked: String, engine: DatabaseEngine = .postgresql, usage: [String: Int] = [:]) -> SQLCompletionResult {
        let caret = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        return SQLCompletionEngine.complete(text, cursor: caret, catalog: catalog, activeDatabase: "shop", engine: engine, usage: usage)
    }

    func testDerivedTablesExposeTheirColumns() {
        let labels = complete("SELECT t.| FROM (SELECT id, total AS amount FROM orders) t").items.map(\.label)
        XCTAssertEqual(Set(labels), ["id", "amount"])
    }

    func testSignatureHintFollowsTheArgument() {
        let first = complete("SELECT DATE_TRUNC(|) FROM orders").signature
        XCTAssertEqual(first?.name, "DATE_TRUNC")
        XCTAssertEqual(first?.argument, 0)
        XCTAssertEqual(complete("SELECT DATE_TRUNC('day', |) FROM orders").signature?.argument, 1)
        XCTAssertEqual(complete("SELECT COALESCE(LOWER(name), |) FROM customers").signature?.name, "COALESCE", "The innermost open call wins")
        XCTAssertNil(complete("SELECT COUNT(*) |FROM orders").signature)
    }

    func testTypesAfterCastsFollowTheEngine() {
        XCTAssertTrue(complete("SELECT total::|").items.contains { $0.label == "NUMERIC" })
        XCTAssertTrue(complete("SELECT CAST(total AS |) FROM orders", engine: .mysql).items.contains { $0.label == "DECIMAL" })
    }

    func testHavingPutsAggregatesFirst() {
        let first = complete("SELECT name, COUNT(*) FROM customers GROUP BY name HAVING |").items.first
        XCTAssertEqual(first?.kind, .function)
    }

    func testOftenUsedItemsRiseWithinTheirKind() {
        let plain = complete("SELECT | FROM orders").items.filter { $0.kind == .column }.map(\.label)
        XCTAssertEqual(plain.first, "id")
        let used = complete("SELECT | FROM orders", usage: ["column|created_at": 5]).items.filter { $0.kind == .column }.map(\.label)
        XCTAssertEqual(used.first, "created_at")
    }

    func testUnknownTablesAreFlaggedWithTheClosestName() {
        let unknown = SQLInspection.unknownTables(in: "SELECT * FROM ordres o JOIN custmers c ON c.id = o.id", catalog: catalog, engine: .postgresql)
        XCTAssertEqual(unknown, [.init(name: "ordres", suggestion: "orders"), .init(name: "custmers", suggestion: "customers")])
        XCTAssertTrue(SQLInspection.unknownTables(in: "WITH recent AS (SELECT * FROM orders) SELECT * FROM recent", catalog: catalog, engine: .postgresql).isEmpty,
                      "CTEs aren't tables")
        XCTAssertTrue(SQLInspection.unknownTables(in: "SELECT * FROM generate_series(1, 3); SELECT * FROM pg_catalog.pg_tables", catalog: catalog, engine: .postgresql).isEmpty,
                      "Table functions and system schemas aren't checked")
        XCTAssertTrue(SQLInspection.unknownTables(in: "SELECT * FROM ordres", catalog: [], engine: .postgresql).isEmpty, "Nothing to check against yet")
        XCTAssertEqual(SQLInspection.distance("ordres", "orders"), 1, "A swap is one edit")
    }

    func testBracketsAndQuotesPairWhereTheyShould() {
        func action(_ character: Character, _ marked: String, selecting length: Int = 0) -> EditorAutoPairs.Action {
            let caret = (marked as NSString).range(of: "|").location
            let text = (marked as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
            return EditorAutoPairs.action(typing: character, in: text, selection: NSRange(location: caret, length: length))
        }
        XCTAssertEqual(action("(", "SELECT COUNT|"), .pair("()"))
        XCTAssertEqual(action("'", "WHERE status = |"), .pair("''"))
        XCTAssertEqual(action(")", "SELECT COUNT(*|)"), .stepOver)
        XCTAssertEqual(action("'", "WHERE status = 'paid|'"), .stepOver)
        XCTAssertEqual(action("(", "SELECT |total"), .insert, "Not right before a word")
        XCTAssertEqual(action("'", "WHERE note = 'don|"), .insert, "Not an apostrophe inside a string")
        XCTAssertEqual(action("'", "SELECT name|"), .insert, "Not right after a word")
        XCTAssertEqual(action("(", "SELECT |total", selecting: 5), .wrap("(", ")"))
        let script = "SELECT \"customer_id\", \"name\"\nFROM \"main\".\"customers\"\nLIMIT 100\nOFFSET 0;\nSELECT * FROM orders o JOIN customers c ON c.customer_id ;\nSELECT strftime| = o.customer_id WHERE c."
        XCTAssertEqual(action("(", script), .pair("()"), "Mid-line, before a space")
        XCTAssertTrue(EditorAutoPairs.deletesPair(in: "COUNT()", at: 6))
        XCTAssertFalse(EditorAutoPairs.deletesPair(in: "COUNT(*)", at: 6))
    }
}
