import XCTest
@testable import PortSQL

final class ConsoleStorageAndSQLTests: XCTestCase {
    @MainActor
    func testSavedLibraryRetainsAllItemsAndRestoresDeletedWork() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        for i in 0..<65 { store.saveSnippet(title: "Query \(i)", sql: "SELECT \(i)") }
        let preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "Fixture", databaseName: nil, sourceTableReference: nil)
        for i in 0..<55 {
            var chart = preset; chart.id = UUID(); chart.title = "Chart \(i)"
            store.saveVisualization(chart)
        }
        let restored = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(restored.snippets.count, 65)
        XCTAssertEqual(restored.visualizations.count, 55)
        let deleted = restored.snippets[0]
        restored.deleteSnippets(at: [0])
        let reopened = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertFalse(reopened.snippets.contains { $0.id == deleted.id })
        reopened.restore(try XCTUnwrap(reopened.trash.first))
        XCTAssertTrue(reopened.snippets.contains { $0.id == deleted.id })
        XCTAssertTrue(reopened.trash.isEmpty)
    }

    @MainActor
    func testConsolesRestoreIndependentDraftsBindingsAndClosedTabs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsoleStore(directory: directory)
        let firstID = store.active.id
        store.active.workspace.queryText = "SELECT $1"
        store.active.workspace.activeBoundQuery = BoundQuery(sql: "SELECT $1", values: [.string("日本語")])
        store.add()
        let secondID = store.active.id
        store.active.workspace.mongoDraft.collection = "orders"
        store.active.workspace.queryText = #"{"find":"orders"}"#
        store.close(firstID)
        let restored = ConsoleStore(directory: directory)
        XCTAssertEqual(restored.active.id, secondID)
        XCTAssertEqual(restored.active.workspace.mongoDraft.collection, "orders")
        restored.add(restoring: try XCTUnwrap(restored.closed.first))
        XCTAssertEqual(restored.active.id, firstID)
        XCTAssertEqual(restored.active.workspace.activeBoundQuery?.values, [.string("日本語")])
        XCTAssertEqual(restored.consoles.count, 2)
        // A corrupt latest write recovers the previous complete archive.
        restored.save()
        try Data("incomplete".utf8).write(to: directory.appendingPathComponent("consoles.json"))
        XCTAssertEqual(ConsoleStore(directory: directory).consoles.count, 2)
    }

    func testStatementSelectionAndCTEQuotedAliasCompletion() throws {
        let sql = "SELECT '🦊;'; /* ; */ SELECT $$a;b$$; SELECT 3;"
        let statements = SQLEditingService.statementRanges(in: sql, engine: .postgresql).map { String(sql[$0]) }
        XCTAssertEqual(statements.count, 3)
        let range = try XCTUnwrap(SQLEditingService.statement(in: sql, atUTF16: (sql as NSString).range(of: "$$a").location, engine: .postgresql))
        XCTAssertTrue(sql[range].contains("$$a;b$$"))
        let table = SchemaTableDescriptor(schemaName: "public", name: "Order Items", columns: [
            SchemaColumnDescriptor(name: "Item Name", type: "text", isNullable: true, isPrimaryKey: false, isUnique: false)
        ], rowCountEstimate: nil)
        let query = #"SELECT x. FROM "Order Items" AS x"#
        let cursor = (query as NSString).range(of: "x.").location + 2
        XCTAssertTrue(SQLAssistService.suggestions(for: query, catalog: [table], activeDatabase: "public", cursorOffset: cursor).contains(#"x."Item Name""#))
        let cte = "WITH totals(customer, amount) AS (SELECT customer_id, SUM(total) FROM orders GROUP BY customer_id) SELECT t. FROM totals t"
        let offset = (cte as NSString).range(of: "SELECT t.").location + "SELECT t.".utf16.count
        XCTAssertTrue(SQLAssistService.suggestions(for: cte, catalog: [], activeDatabase: "public", cursorOffset: offset).contains("t.amount"))
        XCTAssertTrue(SQLAssistService.suggestions(for: "SELECT COA", catalog: [], activeDatabase: nil, cursorOffset: 10).contains("COALESCE("))
        let users = SchemaTableDescriptor(schemaName: "public", name: "users", columns: [SchemaColumnDescriptor(name: "email", type: "text", isNullable: true, isPrimaryKey: false, isUnique: false)], rowCountEstimate: nil)
        let audit = SchemaTableDescriptor(schemaName: "public", name: "audit", columns: [SchemaColumnDescriptor(name: "action", type: "text", isNullable: true, isPrimaryKey: false, isUnique: false)], rowCountEstimate: nil)
        let nested = "SELECT u. FROM users u WHERE EXISTS (SELECT 1 FROM audit u)"
        let suggestions = SQLAssistService.suggestions(for: nested, catalog: [users, audit], activeDatabase: "public", cursorOffset: 9)
        XCTAssertTrue(suggestions.contains("u.email"))
        XCTAssertFalse(suggestions.contains("u.action"))
    }

    func testRelationalSessionsKeepTemporaryTablesAndRollbackManualChanges() async throws {
        var exercised = false
        for engine in [DatabaseEngine.mysql, .mariadb, .postgresql] {
            let key = engine == .mariadb ? "PORTBASE_TEST_MARIADB_PORT" : engine == .mysql ? "PORTSQL_TEST_MYSQL_PORT" : "PORTSQL_TEST_POSTGRES_PORT"
            guard let raw = ProcessInfo.processInfo.environment[key], let port = Int(raw) else { continue }
            exercised = true
            let profile = ConnectionProfile(name: "Disposable console fixture", engine: engine, host: "127.0.0.1", port: port,
                username: "test_username", password: "test_password", defaultDatabase: "test_database", transportSecurityMode: .plaintext)
            let service = DatabaseService.shared
            let session = UUID()
            let table = "portsql_console_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            do {
                _ = try await service.execute(query: "CREATE TEMPORARY TABLE \(table) (id INTEGER PRIMARY KEY, value INTEGER)", profile: profile,
                    policy: .userQuery(confirmed: true), sessionID: session)
                _ = try await service.execute(query: "INSERT INTO \(table) (id, value) VALUES (1, 10)", profile: profile,
                    policy: .userQuery(confirmed: true), sessionID: session)
                _ = try await service.execute(query: "UPDATE \(table) SET value = 20 WHERE id = 1", profile: profile,
                    policy: .userQuery(confirmed: true), sessionID: session, manualCommit: true)
                let pending = try await service.execute(query: "SELECT value FROM \(table)", profile: profile,
                    policy: .userQuery(confirmed: false), sessionID: session, manualCommit: true)
                XCTAssertEqual(pending.rows.first?.cells.first?.displayValue, "20")
                try await service.finishConsoleTransaction(session, commit: false)
                let rolledBack = try await service.execute(query: "SELECT value FROM \(table)", profile: profile,
                    policy: .userQuery(confirmed: false), sessionID: session)
                XCTAssertEqual(rolledBack.rows.first?.cells.first?.displayValue, "10")
                _ = try await service.execute(query: "UPDATE \(table) SET value = 30 WHERE id = 1", profile: profile,
                    policy: .userQuery(confirmed: true), sessionID: session, manualCommit: true)
                try await service.finishConsoleTransaction(session, commit: true)
                let committed = try await service.execute(query: "SELECT value FROM \(table)", profile: profile,
                    policy: .userQuery(confirmed: false), sessionID: session)
                XCTAssertEqual(committed.rows.first?.cells.first?.displayValue, "30")
                await service.closeConsole(session)
            } catch { await service.closeConsole(session); throw error }
        }
        if !exercised { throw XCTSkip("Local relational fixtures are not configured") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class ConsoleTabTitleTests: XCTestCase {
    func testArchivesWithoutTheTitleFlagStillDecode() throws {
        var draft = ConsoleDraft()
        draft.hasCustomTitle = true
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        object["hasCustomTitle"] = nil
        let legacy = try JSONDecoder().decode(ConsoleDraft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.hasCustomTitle, "Archives from before tab titles decode as unnamed")
        XCTAssertEqual(legacy.id, draft.id)
    }

    @MainActor
    func testRenameMarksTheTitleAsTheUsersAndSurvivesReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConsoleStore(directory: directory)
        XCTAssertFalse(store.active.hasCustomTitle, "New tabs show their connection's name")
        store.rename(store.selectedID, title: "Nightly report")
        store.save()
        let reopened = ConsoleStore(directory: directory)
        XCTAssertEqual(reopened.active.title, "Nightly report")
        XCTAssertTrue(reopened.active.hasCustomTitle)
    }
}
