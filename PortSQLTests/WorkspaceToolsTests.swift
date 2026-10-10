import XCTest
@testable import PortSQL

final class WorkspaceToolsTests: XCTestCase {
    func testLineNavigationAndCommentsPreserveUTF16AndCRLF() throws {
        let text = "  SELECT '🦊';\r\nSELECT 2;\r\n"
        let firstLength = "  SELECT '🦊';\r\n".utf16.count
        XCTAssertEqual(SQLEditingService.lineStarts(in: text), [0, firstLength, text.utf16.count])
        let edit = try XCTUnwrap(SQLEditingService.toggleLineComments(text, selection: NSRange(location: 0, length: firstLength)))
        XCTAssertEqual(edit.text, "  -- SELECT '🦊';\r\nSELECT 2;\r\n")
        let restored = try XCTUnwrap(SQLEditingService.toggleLineComments(edit.text, selection: edit.selection))
        XCTAssertEqual(restored.text, text)
        XCTAssertNil(SQLEditingService.toggleLineComments(text, selection: NSRange(location: text.utf16.count + 1, length: 0)))
    }

    func testCommentedWriteIsReadOnlyAcrossSupportedSQLDialects() throws {
        for engine in [DatabaseEngine.mysql, .mariadb, .postgresql, .sqlite, .clickhouse] {
            let original = "UPDATE users SET active = 1;\nSELECT 1;"
            let edit = try XCTUnwrap(SQLEditingService.toggleLineComments(original, selection: NSRange(location: 0, length: 0)))
            XCTAssertEqual(edit.text, "-- UPDATE users SET active = 1;\nSELECT 1;")
            XCTAssertTrue(SQLSafetyService.isReadOnlySQL(edit.text, engine: engine))
            XCTAssertFalse(SQLSafetyService.isReadOnlySQL(original, engine: engine))
        }
    }

    func testLoadedRowFilteringDistinguishesNullEmptyTextAndEmptyBinary() {
        var result = QueryResultTable.empty
        result.columns = [QueryColumn(name: "id", type: "integer"), QueryColumn(name: "value", type: "text")]
        result.rows = [QueryRow(cells: [.integer("1"), .null]), QueryRow(cells: [.integer("2"), .text("")]),
                       QueryRow(cells: [.integer("3"), .text("NULL")]), QueryRow(cells: [.integer("4"), .binary(Data())]),
                       QueryRow(cells: [.integer("5"), .text("Hello 🦊")])]
        XCTAssertEqual(LoadedResultFilter(column: 1, mode: .null).matchingRows(in: result), [0])
        XCTAssertEqual(LoadedResultFilter(column: 1, mode: .emptyText).matchingRows(in: result), [1])
        XCTAssertEqual(LoadedResultFilter(column: 1, mode: .equals, text: "NULL").matchingRows(in: result), [2])
        let indices = LoadedResultFilter(column: 1, text: "hello").matchingRows(in: result)
        XCTAssertEqual(indices, [4])
        var filtered = result; filtered.rows = indices.map { result.rows[$0] }
        let copied = ResultGridClipboard.payload(result: filtered, visibleColumns: [1, 0], selection: .init(anchor: .init(row: 0, column: 0), end: .init(row: 0, column: 1)))
        XCTAssertEqual(copied.rows[0].cells, [.text("Hello 🦊"), .integer("5")])
        XCTAssertEqual(filtered.rows[0].id, result.rows[4].id)
    }

    func testJSONFormattingPreservesNumericTokensFieldOrderAndStringEscapes() {
        let json = #"{"z":9223372036854775807123,"a":1.2300e+50,"text":"a \" b","array":[null,""]}"#
        let formatted = ResultInspectionService.formattedJSON(json)
        XCTAssertTrue(formatted.contains("9223372036854775807123"))
        XCTAssertTrue(formatted.contains("1.2300e+50"))
        XCTAssertTrue(formatted.contains(#""text": "a \" b""#))
        XCTAssertLessThan(formatted.range(of: "\"z\"")!.lowerBound, formatted.range(of: "\"a\"")!.lowerBound)
        let deep = String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100)
        XCTAssertEqual(ResultInspectionService.formattedJSON(deep), deep)
    }

    func testScriptImportChecksEncodingSizeAndExportsEngineExtensions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("\u{FEFF}SELECT '🦊';\r\n".utf8).write(to: file)
        XCTAssertEqual(try ScriptFileService.read(file), "SELECT '🦊';\r\n")
        try Data([0, 255, 254]).write(to: file)
        XCTAssertThrowsError(try ScriptFileService.read(file))
        try Data(repeating: 65, count: ScriptFileService.maximumBytes + 1).write(to: file)
        XCTAssertThrowsError(try ScriptFileService.read(file))
        for (engine, suffix) in [(DatabaseEngine.postgresql, "sql"), (.mongodb, "json"), (.redis, "redis")] {
            let exported = try ScriptFileService.export("example\n", engine: engine)
            defer { try? FileManager.default.removeItem(at: exported) }
            XCTAssertEqual(exported.pathExtension, suffix)
            XCTAssertEqual(try ScriptFileService.read(exported), "example\n")
        }
        let bytes = Data([0, 255, 128])
        let binary = try ResultInspectionService.export(.binary(bytes))
        defer { try? FileManager.default.removeItem(at: binary) }
        XCTAssertEqual(try Data(contentsOf: binary), bytes)
    }

    func testDuplicatedConnectionHasIndependentIdentityAndRedactedSecrets() throws {
        let original = ConnectionProfile(name: "Production", engine: .postgresql, host: "db.example", port: 5432,
            username: "reader", password: "fixture-password", database: "app", transportSecurityMode: .privateCA,
            privateCACertificate: "fixture-ca", isReadOnly: true, usesSSHTunnel: true, sshPrivateKey: "fixture-key")
        let copy = original.duplicate()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.password, original.password)
        XCTAssertEqual(copy.privateCACertificate, original.privateCACertificate)
        XCTAssertEqual(copy.sshPrivateKey, original.sshPrivateKey)
        XCTAssertTrue(copy.isReadOnly)
        let encoded = String(decoding: try JSONEncoder().encode(copy), as: UTF8.self)
        for secret in ["fixture-password", "fixture-ca", "fixture-key"] { XCTAssertFalse(encoded.contains(secret)) }
    }

    @MainActor func testLibraryMigratesOldEntriesAndPersistsEditedContextAndOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snippetID = UUID()
        let old = "[{\"id\":\"\(snippetID)\",\"title\":\"Old\",\"sql\":\"SELECT 1\",\"note\":\"\",\"createdAt\":\"2026-09-22T00:00:00Z\"}]"
        try Data(old.utf8).write(to: directory.appendingPathComponent("query-snippets.json"))
        let store = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        var snippet = try XCTUnwrap(store.snippets.first)
        XCTAssertNil(snippet.engine)
        snippet.title = "New title"; snippet.note = "Useful note"; snippet.bookmarkID = UUID(); snippet.database = "test"; snippet.engine = .postgresql
        store.updateSnippet(snippet)
        store.addHistory(QueryHistoryEntry(title: "Query", sql: "SELECT 1", connectionName: "Fixture", summary: "OK", duration: 0.125, outcome: .succeeded))
        store.addHistory(QueryHistoryEntry(title: "Query", sql: "SELECT 1", connectionName: "Fixture", summary: "Error", duration: 0.25, outcome: .failed))
        let reloaded = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        var expected = snippet
        expected.updatedAt = reloaded.snippets.first?.updatedAt
        XCTAssertNotNil(expected.updatedAt)
        XCTAssertEqual(reloaded.snippets.first, expected)
        XCTAssertEqual(reloaded.history.map(\.outcome), [.failed, .succeeded])
        XCTAssertEqual(reloaded.history.first?.duration, 0.25)
    }

    @MainActor func testUnavailableQueryContextDoesNotReplaceTheActiveDraft() {
        let workspace = WorkspaceViewModel()
        workspace.queryText = "SELECT 'active draft'"
        let missing = QueryHistoryEntry(title: "Missing", sql: "DROP TABLE users", connectionName: "Gone", summary: "", bookmarkID: UUID(), database: "other", engine: .mysql)
        XCTAssertFalse(workspace.apply(history: missing))
        XCTAssertEqual(workspace.queryText, "SELECT 'active draft'")
        XCTAssertNotNil(workspace.errorMessage)
    }

    func testMongoIndexInspectorPreservesCompoundKeyOrderAndOptions() throws {
        let json = #"{"name":"region_date","key":{"region":1,"date":-1},"unique":true,"sparse":false,"hidden":true,"expireAfterSeconds":{"$numberLong":"3600"},"partialFilterExpression":{"active":true}}"#
        let index = try MongoIndexDescriptor(json: json)
        XCTAssertEqual(index.fields.map(\.name), ["region", "date"])
        XCTAssertEqual(index.fields.map(\.direction), ["1", "-1"])
        XCTAssertTrue(index.unique); XCTAssertTrue(index.hidden); XCTAssertFalse(index.sparse)
        XCTAssertEqual(index.expiration, "3600")
        XCTAssertEqual(index.json, json)
        XCTAssertTrue(try MongoIndexDescriptor(json: #"{"name":"_id_","key":{"_id":1}}"#).unique)
        let query = MongoQueryService.template("listIndexes", collection: "a\"b")
        XCTAssertTrue(SQLSafetyService.isReadOnlySQL(query, engine: .mongodb))
        XCTAssertThrowsError(try MongoIndexDescriptor(json: #"{"name":"broken"}"#))
    }
}
