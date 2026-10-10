import XCTest
@preconcurrency import SwiftBSON
@testable import PortSQL

final class DataTransferServiceTests: XCTestCase {
    func testCSVPreservesNullMissingEmptyTextQuotesAndMultilineValues() throws {
        let writer = try DataExportWriter(format: .csv, progress: { _ in })
        defer { writer.discard() }
        writer.setColumns(["null", "empty", "literal", "missing", "literalMissing", "quoted"].map { QueryColumn(name: $0, type: "TEXT") })
        try writer.append(QueryRow(cells: [.null, .text(""), .text("NULL"), .json(#"{"$missing":true}"#), .text(#"\M"#), .text("a,\"日本語\"\r\nsecond line")]))
        let result = try writer.finish()
        let source = try DataTransferCodec.inspect(url: XCTUnwrap(result.fileURL), format: .csv, hasHeader: true, nullToken: "NULL")
        let row = try XCTUnwrap(source.preview.first)
        XCTAssertEqual(row.fields["null"], .null)
        XCTAssertEqual(row.fields["empty"], .text(""))
        XCTAssertEqual(row.fields["literal"], .text("NULL"))
        XCTAssertNil(row.fields["missing"])
        XCTAssertEqual(row.fields["literalMissing"], .text(#"\M"#))
        XCTAssertEqual(row.fields["quoted"], .text("a,\"日本語\"\r\nsecond line"))

        let document = try MongoExtendedJSON.decode(#"{"text":"123","int":{"$numberInt":"3"},"long":{"$numberLong":"3"},"date":{"$date":{"$numberLong":"1700000000123"}},"nested":{"$missing":true}}"#)
        let mongoWriter = try DataExportWriter(format: .csv, progress: { _ in })
        defer { mongoWriter.discard() }
        mongoWriter.setColumns(document.keys.map { QueryColumn(name: $0, type: "BSON") })
        try mongoWriter.append(QueryRow(cells: document.values.map { DataTransferCodec.mongoCSVCell($0) }))
        let mongoFile = try mongoWriter.finish()
        let mongoSource = try DataTransferCodec.inspect(url: XCTUnwrap(mongoFile.fileURL), format: .csv, hasHeader: true, nullToken: "NULL")
        let restored = try DataTransferCodec.mongoDocument(record: XCTUnwrap(mongoSource.preview.first),
            mappings: mongoSource.columnNames.map { DataImportColumnMapping(sourceName: $0, targetName: $0) }, row: 1)
        XCTAssertEqual(restored, document)
    }

    func testJSONImportPreservesNumericLexemesAndBSONAndRejectsBrokenArrays() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = #"[{"unsigned":18446744073709551615,"precise":12345678901234567890.123456789012345678,"nested":{"z":1,"a":2},"_id":{"$oid":"507f1f77bcf86cd799439011"},"bytes":{"$binary":{"base64":"AAEC","subType":"80"}}}]"#
        try text.write(to: url, atomically: true, encoding: .utf8)
        let source = try DataTransferCodec.inspect(url: url, format: .json, hasHeader: true, nullToken: "NULL")
        let row = try XCTUnwrap(source.preview.first)
        XCTAssertEqual(row.fields["unsigned"], .integer("18446744073709551615"))
        XCTAssertEqual(row.fields["precise"], .decimal("12345678901234567890.123456789012345678"))
        XCTAssertEqual(try DataTransferCodec.boundValue(row.fields["precise"]!, type: .decimal, column: "precise", row: 1),
                       .string("12345678901234567890.123456789012345678"))
        let mappings = ["_id", "bytes", "nested"].map { DataImportColumnMapping(sourceName: $0, targetName: $0) }
        let document = try DataTransferCodec.mongoDocument(record: row, mappings: mappings, row: 1)
        let expected = try MongoExtendedJSON.decode(#"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"bytes":{"$binary":{"base64":"AAEC","subType":"80"}},"nested":{"z":1,"a":2}}"#)
        XCTAssertEqual(document, expected)
        for broken in ["[{},]", "[{} {}]", "{}{}", "[{}", "[1]"] {
            try broken.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try DataTransferCodec.inspect(url: url, format: .json, hasHeader: true, nullToken: "NULL"))
        }
        let plan = DataImportPlan(source: source, schemaName: "pub\"lic", tableName: "orders; DROP TABLE x", mappings: [DataImportColumnMapping(sourceName: "unsigned", targetName: "user\"value")])
        XCTAssertEqual(try plan.statement(engine: .postgresql), #"INSERT INTO "pub""lic"."orders; DROP TABLE x" ("user""value") VALUES ($1)"#)
    }

    func testTransfersRejectWritesAndUnconfirmedImportBeforeConnecting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try "id\n1\n".write(to: url, atomically: true, encoding: .utf8)
        let source = try DataTransferCodec.inspect(url: url, format: .csv, hasHeader: true, nullToken: "NULL")
        let plan = DataImportPlan(source: source, schemaName: "", tableName: "test", mappings: [DataImportColumnMapping(sourceName: "id", targetName: "id")])
        for engine in DatabaseEngine.allCases {
            var profile = ConnectionProfile(name: "No network", engine: engine, host: "127.0.0.1", port: 1,
                username: "", password: "", database: "test", usesTLS: false)
            profile.isReadOnly = true
            do {
                _ = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: "test", policy: .mutation())
                XCTFail("Read-only import must fail before opening a connection")
            } catch { XCTAssertTrue(error is DatabaseServiceError) }
            profile.isReadOnly = false
            do {
                _ = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: "test", policy: .userQuery(confirmed: true))
                XCTFail("Import requires its explicit mutation policy")
            } catch { XCTAssertTrue(error is DatabaseServiceError) }
            let sql = engine == .mongodb ? #"{"delete":"test","deletes":[{"q":{},"limit":0}]}"# : "DELETE FROM test"
            do {
                _ = try await DatabaseService.shared.exportData(query: BoundQuery(sql: sql, values: []), profile: profile, database: "test", format: .json, policy: .readOnly)
                XCTFail("Export must reject writes before connecting")
            } catch { XCTAssertTrue(error is DatabaseServiceError) }
        }
    }

    func testMongoImportAndStreamingExportExceedDisplayLimit() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_MONGODB_PORT"] ?? "") else {
            throw XCTSkip("Set PORTSQL_TEST_MONGODB_PORT to an isolated local MongoDB fixture.")
        }
        let profile = ConnectionProfile(name: "Transfer fixture", engine: .mongodb, host: "127.0.0.1", port: port,
            username: "", password: "", database: "portsql_codex_validation", usesTLS: false)
        let collection = "transfer_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let writer = try DataExportWriter(format: .csv, progress: { _ in })
        defer { writer.discard() }
        writer.setColumns([QueryColumn(name: "id", type: "INTEGER"), QueryColumn(name: "text", type: "TEXT")])
        for index in 0..<10_023 { try writer.append(QueryRow(cells: [.integer(String(index)), .text("row \(index)\n日本語")])) }
        let file = try writer.finish()
        let source = try DataTransferCodec.inspect(url: XCTUnwrap(file.fileURL), format: .csv, hasHeader: true, nullToken: "NULL")
        let plan = DataImportPlan(source: source, schemaName: "", tableName: collection,
            mappings: source.columnNames.map { DataImportColumnMapping(sourceName: $0, targetName: $0) })
        let drop = "{\"drop\":" + DataTransferCodec.jsonString(collection) + "}"
        do {
            let imported = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: "portsql_codex_validation", policy: .mutation())
            XCTAssertEqual(imported.rowCount, 10_023)
            let query = BoundQuery(sql: "{\"find\":" + DataTransferCodec.jsonString(collection) + ",\"sort\":{\"id\":1}}", values: [])
            let exported = try await DatabaseService.shared.exportData(query: query, profile: profile, database: "portsql_codex_validation", format: .json, policy: .readOnly)
            let exportURL = try XCTUnwrap(exported.fileURL)
            defer { try? FileManager.default.removeItem(at: exportURL) }
            XCTAssertEqual(exported.rowCount, 10_023)
            let reader = try JSONRecordReader(url: exportURL)
            var count = 0
            var last = ""
            while let record = try reader.next() { count += 1; last = record }
            XCTAssertEqual(count, 10_023)
            XCTAssertEqual(try MongoExtendedJSON.decode(last)["id"]?.int64Value, 10_022)
            _ = try await DatabaseService.shared.execute(query: drop, profile: profile, policy: .mutation())
        } catch {
            _ = try? await DatabaseService.shared.execute(query: drop, profile: profile, policy: .mutation())
            throw error
        }
    }
}
