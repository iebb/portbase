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

    /// Server engines report where each result column came from, and that's enough to edit a join's
    /// tables: MySQL and MariaDB name the table directly, PostgreSQL by OID until it's looked up.
    func testServerEnginesReportColumnOriginsForEditableJoins() async throws {
        var exercised = false
        for engine in [DatabaseEngine.mysql, .mariadb, .postgresql] {
            let key = engine == .mariadb ? "PORTBASE_TEST_MARIADB_PORT" : engine == .mysql ? "PORTSQL_TEST_MYSQL_PORT" : "PORTSQL_TEST_POSTGRES_PORT"
            guard let raw = ProcessInfo.processInfo.environment[key], let port = Int(raw) else { continue }
            exercised = true
            let profile = ConnectionProfile(name: "Disposable origin fixture", engine: engine, host: "127.0.0.1", port: port,
                username: "test_username", password: "test_password", defaultDatabase: "test_database", transportSecurityMode: .plaintext)
            let service = DatabaseService.shared
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            let customers = "origin_customers_" + suffix, orders = "origin_orders_" + suffix
            do {
                for sql in ["CREATE TABLE \(customers) (id INTEGER PRIMARY KEY, name VARCHAR(40))",
                            "CREATE TABLE \(orders) (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER)",
                            "INSERT INTO \(customers) (id, name) VALUES (1, 'Ada')",
                            "INSERT INTO \(orders) (id, customer_id, total) VALUES (10, 1, 5)"] {
                    _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
                }
                let sql = "SELECT o.id, o.total AS amount, c.id AS cid, c.name, o.total * 2 AS doubled FROM \(orders) o JOIN \(customers) c ON c.id = o.customer_id"
                var result = try await service.execute(query: sql, profile: profile, database: "test_database", policy: .readOnly)
                XCTAssertNil(result.columns[4].origin, "\(engine): a computed value has no origin")
                if engine == .postgresql {
                    XCTAssertNotNil(result.columns[1].origin?.postgresTableOID)
                    result.columns = try await service.resolvePostgresColumnOrigins(result.columns, profile: profile, database: "test_database")
                }
                XCTAssertEqual(result.columns[1].origin?.table, orders, "\(engine)")
                XCTAssertEqual(result.columns[1].origin?.column, "total", "\(engine): an alias reads its real column")
                XCTAssertEqual(result.columns[3].origin?.table, customers)
                let catalog = try await service.loadSchema(profile: profile, database: "test_database")
                let plan = ResultEditPlanner.originPlan(columns: result.columns, statement: sql, catalog: catalog, engine: engine)
                XCTAssertEqual(plan?.targets.map(\.table.name).sorted(), [customers, orders].sorted(), "\(engine): both tables' keys are in the result")
                XCTAssertEqual(plan?.editableColumn(at: 1)?.column.name, "total")
                XCTAssertNil(plan?.editableColumn(at: 4))
                let union = "SELECT id, name FROM \(customers) UNION SELECT id, name FROM \(customers)"
                let unioned = try await service.execute(query: union, profile: profile, database: "test_database", policy: .readOnly)
                XCTAssertNil(ResultEditPlanner.originPlan(columns: unioned.columns, statement: union, catalog: catalog, engine: engine))
            } catch {
                for table in [orders, customers] {
                    _ = try? await service.execute(query: "DROP TABLE \(table)", profile: profile, policy: .userQuery(confirmed: true))
                }
                throw error
            }
            for table in [orders, customers] {
                _ = try? await service.execute(query: "DROP TABLE \(table)", profile: profile, policy: .userQuery(confirmed: true))
            }
        }
        if !exercised { throw XCTSkip("Local relational fixtures are not configured") }
    }

    /// The whole path on PostgreSQL: a console join runs, its columns' names arrive after the rows, and
    /// edits to both tables are written as single-row updates while the console's SQL stays as typed.
    @MainActor
    func testConsoleJoinOnPostgresIsEditableOnceOriginsResolve() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_POSTGRES_PORT"] ?? "") else {
            throw XCTSkip("Local PostgreSQL fixture is not configured")
        }
        let profile = ConnectionProfile(name: "Disposable origin fixture", engine: .postgresql, host: "127.0.0.1", port: port,
            username: "test_username", password: "test_password", defaultDatabase: "test_database", transportSecurityMode: .plaintext)
        let service = DatabaseService.shared
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let customers = "vm_customers_" + suffix, orders = "vm_orders_" + suffix
        for sql in ["CREATE TABLE \(customers) (id INTEGER PRIMARY KEY, name TEXT)",
                    "CREATE TABLE \(orders) (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER)",
                    "INSERT INTO \(customers) VALUES (1, 'Ada')", "INSERT INTO \(orders) VALUES (10, 1, 5)"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        defer {
            Task { for table in [orders, customers] { _ = try? await service.execute(query: "DROP TABLE \(table)", profile: profile, policy: .userQuery(confirmed: true)) } }
        }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        for _ in 0..<250 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(nanoseconds: 20_000_000) }
        workspace.schemaCatalog = try await service.loadSchema(profile: profile, database: "test_database")

        let sql = "SELECT o.id, o.total, c.id AS cid, c.name FROM \(orders) o JOIN \(customers) c ON c.id = o.customer_id"
        workspace.queryText = sql
        workspace.queryCursorOffset = 0
        workspace.runQuery()
        for _ in 0..<250 where workspace.isRunning || !workspace.canEditCurrentRows { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertTrue(workspace.canEditCurrentRows, "Editable once PostgreSQL's column origins have names")
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 1, text: "9"))
        XCTAssertNil(workspace.stageCellText(rowIndex: 0, columnIndex: 3, text: "Grace"))
        workspace.submitPendingEdits()
        for _ in 0..<250 where workspace.isSubmittingPendingEdits { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(workspace.pendingEditError)
        XCTAssertEqual(workspace.queryText, sql)
        let stored = try await service.execute(query: "SELECT o.total, c.name FROM \(orders) o JOIN \(customers) c ON c.id = o.customer_id",
                                               profile: profile, policy: .readOnly)
        XCTAssertEqual(stored.rows.first?.cells.map(\.displayValue), ["9", "Grace"])
        withExtendedLifetime((bookmarks, library)) {}
    }

    func testOnlyStatementsThatCanChangeOneRowRunWithoutRollback() {
        func single(_ sql: String, _ operation: String) -> Bool {
            DatabaseService.isProvablySingleRowWrite(SQLEditingService.tokens(sql, engine: .mysql), operation: operation)
        }
        XCTAssertTrue(single("UPDATE `t` SET `a` = ? WHERE `id` = ? AND `a` = ?\nLIMIT 1;", "UPDATE"))
        XCTAssertTrue(single("DELETE FROM `t` WHERE `id` = ? LIMIT 1", "DELETE"))
        XCTAssertTrue(single("INSERT INTO `t` (`a`, `b`) VALUES (?, ?);", "INSERT"))
        XCTAssertFalse(single("UPDATE `t` SET `a` = 1 WHERE `id` > 3", "UPDATE"), "No LIMIT 1")
        XCTAssertFalse(single("UPDATE `t` SET `a` = 1 LIMIT 1", "UPDATE"), "No WHERE")
        XCTAssertFalse(single("UPDATE `t` SET `a` = 1 WHERE `id` = 2 LIMIT 10", "UPDATE"))
        XCTAssertFalse(single("UPDATE `t` SET `a` = 1 WHERE `id` = 2 `LIMIT` 1", "UPDATE"), "A quoted name isn't the keyword")
        XCTAssertFalse(single("INSERT INTO `t` (`a`) VALUES (1), (2)", "INSERT"), "Two rows")
        XCTAssertFalse(single("INSERT INTO `t` (`a`) SELECT `a` FROM `u`", "INSERT"))
        XCTAssertFalse(single("INSERT INTO `t` (`a`) VALUES (1) ON DUPLICATE KEY UPDATE `a` = 2", "INSERT"))
        XCTAssertFalse(single("DELETE FROM `t` WHERE `id` = 1 LIMIT 1; DELETE FROM `t`", "DELETE"))
    }

    /// A MyISAM table can't roll back, but a keyed single-row write still goes through, says so, and
    /// a statement that could change more rows is still refused.
    func testMyISAMTablesTakeSingleRowWritesAndReportIt() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_MYSQL_PORT"] ?? "") else {
            throw XCTSkip("Local MySQL fixture is not configured")
        }
        let profile = ConnectionProfile(name: "Disposable MyISAM fixture", engine: .mysql, host: "127.0.0.1", port: port,
            username: "test_username", password: "test_password", defaultDatabase: "test_database", transportSecurityMode: .plaintext)
        let service = DatabaseService.shared
        let table = "myisam_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        for sql in ["CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name VARCHAR(20)) ENGINE=MyISAM",
                    "INSERT INTO \(table) VALUES (1, 'a'), (2, 'b')"] {
            _ = try await service.execute(query: sql, profile: profile, policy: .userQuery(confirmed: true))
        }
        defer { Task { _ = try? await service.execute(query: "DROP TABLE \(table)", profile: profile, policy: .userQuery(confirmed: true)) } }
        let written = try await service.execute(query: "UPDATE `\(table)` SET `name` = ? WHERE `id` = ? AND `name` = ?\nLIMIT 1;",
            values: [.string("z"), .integer(1), .string("a")], profile: profile, database: "test_database", policy: .mutation(expectedAffectedRows: 1))
        XCTAssertEqual(written.wroteWithoutRollback, true)
        do {
            _ = try await service.execute(query: "UPDATE `\(table)` SET `name` = ? WHERE `id` = ? AND `name` = ?\nLIMIT 1;",
                values: [.string("y"), .integer(2), .string("stale")], profile: profile, database: "test_database", policy: .mutation(expectedAffectedRows: 1))
            XCTFail("A row that no longer matches is reported")
        } catch {}
        do {
            _ = try await service.execute(query: "UPDATE `\(table)` SET `name` = 'q' WHERE `id` > 0", profile: profile,
                database: "test_database", policy: .mutation(expectedAffectedRows: 1))
            XCTFail("A statement that could change several rows is refused")
        } catch {}
        let rows = try await service.execute(query: "SELECT id, name FROM \(table) ORDER BY id", profile: profile, database: "test_database", policy: .readOnly)
        XCTAssertEqual(rows.rows.map { $0.cells.map(\.displayValue) }, [["1", "z"], ["2", "b"]])
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
