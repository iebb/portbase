import XCTest
@testable import PortSQL

final class CopyFormatsAndEnvironmentTests: XCTestCase {
    private let payload = ResultGridClipboard.Payload(
        columns: [QueryColumn(name: "id", type: "int"), QueryColumn(name: "note", type: "text"), QueryColumn(name: "meta", type: "json"),
                  QueryColumn(name: "active", type: "bool"), QueryColumn(name: "blob", type: "bytea"), QueryColumn(name: "id", type: "int")],
        rows: [
            QueryRow(cells: [.integer("1"), .text("O'Brien, \"Bob\"\nC:\\temp"), .json("{\"a\": 1}"), .boolean(true), .binary(Data([0x0A, 0xFF])), .integer("7")]),
            QueryRow(cells: [.decimal("2.50"), .text(""), .null, .boolean(false), .null, .integer("NaN")]),
        ]
    )

    func testCSVKeepsNullDistinctFromEmptyText() {
        let lines = ResultCopyFormatter.text(payload, format: .csv).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "id,note,meta,active,blob,id")
        XCTAssertTrue(lines[1].hasPrefix("1,\"O'Brien, \"\"Bob\"\""), lines[1])
        XCTAssertEqual(lines.last, "2.50,\"\",,false,,NaN", "NULL is an empty field; empty text is a quoted empty field")
    }

    func testJSONPreservesTypesAndDisambiguatesDuplicateColumns() throws {
        let text = ResultCopyFormatter.text(payload, format: .json)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["id"] as? Int, 1)
        XCTAssertEqual(rows[0]["id_2"] as? Int, 7)
        XCTAssertEqual((rows[0]["meta"] as? [String: Any])?["a"] as? Int, 1, "Valid JSON values are embedded, not quoted")
        XCTAssertEqual(rows[0]["active"] as? Bool, true)
        XCTAssertEqual(rows[0]["blob"] as? String, "0x0aff")
        XCTAssertTrue(rows[1]["meta"] is NSNull)
        XCTAssertEqual(rows[1]["note"] as? String, "")
        XCTAssertEqual(rows[1]["id_2"] as? String, "NaN", "Non-numeric numeric text stays a string")
    }

    func testMarkdownEscapesPipesAndAlignsNumbers() {
        let table = ResultGridClipboard.Payload(columns: [QueryColumn(name: "n", type: "int"), QueryColumn(name: "s", type: "text")],
                                                rows: [QueryRow(cells: [.integer("3"), .text("a|b\nc")]), QueryRow(cells: [.null, .null])])
        XCTAssertEqual(ResultCopyFormatter.text(table, format: .markdown), "| n | s |\n| ---: | --- |\n| 3 | a\\|b<br>c |\n| *NULL* | *NULL* |")
    }

    func testSQLInsertsUseEngineSpecificLiterals() {
        let postgres = ResultCopyFormatter.text(payload, format: .sqlInsert, engine: .postgresql, table: "public.order items")
        XCTAssertTrue(postgres.hasPrefix("INSERT INTO public.\"order items\" (id, note, meta, active, blob, id) VALUES (1, 'O''Brien, \"Bob\"\nC:\\temp', '{\"a\": 1}', TRUE, '\\x0AFF'::bytea, 7);"), postgres)
        XCTAssertTrue(postgres.contains("VALUES (2.50, '', NULL, FALSE, NULL, 'NaN');"))

        let mysql = ResultCopyFormatter.text(payload, format: .sqlInsert, engine: .mysql, table: nil)
        XCTAssertTrue(mysql.contains("INSERT INTO table_name"))
        XCTAssertTrue(mysql.contains("C:\\\\temp"), "MySQL string literals escape backslashes")
        XCTAssertTrue(mysql.contains("X'0AFF'"))
        XCTAssertEqual(ResultCopyFormatter.literal(.binary(Data([1])), engine: .clickhouse), "unhex('01')")
        XCTAssertFalse(ResultCopyFormat.available(for: .mongodb).contains(.sqlInsert))
        XCTAssertTrue(ResultCopyFormat.available(for: .sqlite).contains(.sqlInsert))
    }

    func testEnvironmentRoundTripsAndToleratesUnknownValues() throws {
        var profile = ConnectionProfile(name: "Prod", engine: .postgresql, host: "db.example.com", port: 5432,
                                        username: "app", password: "secret", defaultDatabase: "app")
        let untagged = String(data: try JSONEncoder().encode(profile), encoding: .utf8) ?? ""
        XCTAssertFalse(untagged.contains("environment"), "Untagged profiles keep their previous encoding")

        profile.environment = .production
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data).environment, .production)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("secret") ?? true)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["environment"] = "quality-assurance"
        let future = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: future)
        XCTAssertEqual(decoded.environment, ConnectionEnvironment.none, "An unknown label from a newer version doesn't drop the connection")
        XCTAssertEqual(decoded.name, "Prod")
        XCTAssertEqual(profile.duplicate().environment, .production)
    }

    func testMongoDocumentIdentifierSummaries() {
        XCTAssertEqual(MongoDocumentSummary.identifier(in: #"{"_id": {"$oid": "65f0c0ffee"}, "a": 1}"#), "65f0c0ffee")
        XCTAssertEqual(MongoDocumentSummary.identifier(in: #"{"_id": "order-42"}"#), "order-42")
        XCTAssertEqual(MongoDocumentSummary.identifier(in: #"{"_id": {"$numberInt": "7"}}"#), "7")
        XCTAssertEqual(MongoDocumentSummary.identifier(in: #"{"_id": {"b": 2, "a": 1}}"#), #"{"a":1,"b":2}"#)
        XCTAssertNil(MongoDocumentSummary.identifier(in: #"{"name": "no id"}"#))
    }
}

@MainActor
final class PinnedTablesAndTesterTests: XCTestCase {
    private func table(_ name: String) -> SchemaTableDescriptor {
        SchemaTableDescriptor(schemaName: "public", name: name, columns: [], rowCountEstimate: nil)
    }

    func testPinnedTablesPartitionInPinOrderAndPersistPerScope() throws {
        let suite = "PinnedTablesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let scope = PinnedTableStore.scope(profileID: profile, database: "orders")
        let store = PinnedTableStore(defaults: defaults)
        store.toggle("public.users", in: scope)
        store.toggle("public.audit", in: scope)

        let groups = store.partition([table("audit"), table("orders"), table("users")], in: scope)
        XCTAssertEqual(groups.pinned.map(\.name), ["users", "audit"], "Pinned tables keep the order they were pinned in")
        XCTAssertEqual(groups.others.map(\.name), ["orders"])
        XCTAssertTrue(PinnedTableStore(defaults: defaults).isPinned("public.users", in: scope), "Pins persist")
        XCTAssertFalse(store.isPinned("public.users", in: PinnedTableStore.scope(profileID: profile, database: "other")))

        store.toggle("public.users", in: scope)
        XCTAssertFalse(store.isPinned("public.users", in: scope))
        store.removeAll(for: profile)
        XCTAssertTrue(store.pins.isEmpty)
    }

    func testConnectionsCreatedTogetherKeepAStableOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let names = ["Orders", "analytics", "Cache", "Billing", "catalog"]
        let profiles = names.map { name -> ConnectionProfile in
            var profile = ConnectionProfile(name: name, engine: .postgresql, host: "db.example.com", port: 5432, username: "", password: "", defaultDatabase: "")
            profile.createdAt = created
            return profile
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: dir.appendingPathComponent("bookmarks.json"))
        let store = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        XCTAssertEqual(store.bookmarks.map(\.name), ["analytics", "Billing", "Cache", "catalog", "Orders"])
    }

    func testConnectionTestSummaries() {
        XCTAssertTrue(ConnectionTester.summary(.init(duration: 0.084, databaseCount: 3)).contains("3"))
        XCTAssertFalse(ConnectionTester.summary(.init(duration: 0.2, databaseCount: nil)).isEmpty)
    }
}
