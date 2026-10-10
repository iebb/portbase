import XCTest
import SQLite3
@testable import PortSQL

final class SQLiteDatabaseClientTests: XCTestCase {
    func testTypedBindingsNativeSafetyAndExpectedCountRollback() async throws {
        let script = "SELECT '🦊;'; CREATE TRIGGER audit AFTER UPDATE ON items BEGIN INSERT INTO history VALUES ('a;'); UPDATE history SET id = 1; END; SELECT 3;"
        let statements = SQLiteStatementService.statementRanges(in: script)
        XCTAssertEqual(statements.count, 3)
        let triggerCursor = (script as NSString).range(of: "UPDATE history").location
        XCTAssertEqual(SQLEditingService.statement(in: script, atUTF16: triggerCursor, engine: .sqlite), statements.dropFirst().first)
        let file = try await SQLiteFileStore.shared.create(name: "Typed SQLite fixture")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        var profile = ConnectionProfile(name: "SQLite fixture", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        _ = try await SQLiteDatabaseClient.execute(query: "CREATE TABLE items(id INTEGER PRIMARY KEY, label TEXT, amount REAL, enabled BOOLEAN, stamp DATETIME, bytes BLOB, upper_label TEXT GENERATED ALWAYS AS (upper(label)) VIRTUAL)",
            profile: profile, policy: .mutation())
        _ = try await SQLiteDatabaseClient.execute(query: "INSERT INTO items(id, label, amount, enabled, stamp, bytes) VALUES (?, ?, ?, ?, ?, X'0001FF')",
            values: [.integer(1), .string(""), .decimal("12.5"), .boolean(true), .string("2026-09-22 14:30:01.123456+09:00")], profile: profile, policy: .mutation(expectedAffectedRows: 1))
        _ = try await SQLiteDatabaseClient.execute(query: "INSERT INTO items(id, label) VALUES (?, ?)", values: [.integer(2), .null], profile: profile, policy: .mutation(expectedAffectedRows: 1))
        let result = try await SQLiteDatabaseClient.execute(query: "SELECT label, amount, enabled, stamp, bytes FROM items ORDER BY id", profile: profile, policy: .readOnly)
        XCTAssertEqual(result.rows[0].cells, [.text(""), .decimal("12.5"), .boolean(true), .dateTime("2026-09-22 14:30:01.123456+09:00"), .binary(Data([0, 1, 255]))])
        XCTAssertEqual(result.rows[1].cells[0], .null)
        let schema = try await SQLiteDatabaseClient.loadSchema(profile: profile)
        XCTAssertEqual(schema.first?.columns.first { $0.name == "upper_label" }?.isGenerated, true)
        do {
            _ = try await SQLiteDatabaseClient.execute(query: "UPDATE items SET label = 'changed'", profile: profile, policy: .mutation(expectedAffectedRows: 1))
            XCTFail("A mismatched row count must roll back")
        } catch DatabaseServiceError.unexpectedAffectedRowCount(let expected, let actual) {
            XCTAssertEqual(expected, 1); XCTAssertEqual(actual, 2)
        }
        let unchanged = try await SQLiteDatabaseClient.execute(query: "SELECT label FROM items ORDER BY id", profile: profile, policy: .readOnly)
        XCTAssertEqual(unchanged.rows.map(\.cells), [[.text("")], [.null]])
        for sql in ["DELETE FROM items", "ATTACH DATABASE ':memory:' AS escaped", "PRAGMA writable_schema = ON", "SELECT load_extension('/tmp/extension')", "BEGIN", "SELECT 1; DELETE FROM items"] {
            do {
                _ = try await SQLiteDatabaseClient.execute(query: sql, profile: profile, policy: .readOnly)
                XCTFail("Read-only SQLite accepted \(sql)")
            } catch { }
        }
        let large = try await SQLiteDatabaseClient.execute(query: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 10001) SELECT x FROM n", profile: profile, policy: .readOnly)
        XCTAssertEqual(large.rows.count, 10_000)
        XCTAssertEqual(large.isTruncated, true)
        let export = try await SQLiteDatabaseClient.exportData(query: .init(sql: "SELECT id, label FROM items ORDER BY id", values: []), profile: profile, format: .json, policy: .readOnly)
        defer { if let url = export.fileURL { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(export.rowCount, 2)
    }

    func testSnapshotIncludesWALAndManagedFilePathsCannotEscape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE source(id INTEGER); INSERT INTO source VALUES (42)", nil, nil, nil), SQLITE_OK)
        let snapshot = try await SQLiteFileStore.shared.importDatabase(from: source)
        defer { try? SQLiteFileStore.shared.remove(fileName: snapshot.fileName) }
        var profile = ConnectionProfile(name: "Snapshot", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = snapshot.fileName
        let result = try await SQLiteDatabaseClient.execute(query: "SELECT id FROM source", profile: profile, policy: .readOnly)
        XCTAssertEqual(result.rows.first?.cells, [.integer("42")])
        let lease = try SQLiteFileStore.shared.acquire(fileName: snapshot.fileName)
        XCTAssertThrowsError(try SQLiteFileStore.shared.remove(fileName: snapshot.fileName))
        lease.release()
        XCTAssertThrowsError(try SQLiteFileStore.shared.acquire(fileName: "../source.sqlite"))
        XCTAssertThrowsError(try SQLiteFileStore.shared.acquire(fileName: source.path))
    }
}
