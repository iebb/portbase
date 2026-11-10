import XCTest
@testable import PortSQL

/// Import and full export for ClickHouse, Elasticsearch and Redis. The live checks run against isolated
/// local fixtures and skip when their ports aren't set; never point them at a real server.
final class DataTransferEngineTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    func testStreamedLinesAndImportBatchesKeepRecordsWhole() throws {
        let lines = StreamedLines()
        var seen: [String] = []
        for chunk in ["[\"a\"", "]\n[1,", "2]\n\n[3]"] {
            try lines.consume(Data(chunk.utf8)) { seen.append(String(decoding: $0, as: UTF8.self)) }
        }
        try lines.finish { seen.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(seen, ["[\"a\"]", "[1,2]", "[3]"], "A line split across chunks arrives whole, and the last one without a newline too")

        var batch = ImportBatcher()
        for _ in 0..<ImportBatcher.maximumRecords { XCTAssertTrue(batch.fits("x")); try batch.append("x") }
        XCTAssertFalse(batch.fits("x"), "A batch holds at most 1,000 records")
        XCTAssertEqual(batch.take().count, ImportBatcher.maximumRecords)
        XCTAssertTrue(batch.isEmpty)
        XCTAssertThrowsError(try batch.append(String(repeating: "x", count: ImportBatcher.maximumBytes)))
    }

    func testImportPlansDescribeEachEngine() throws {
        let source = DataImportSource(url: URL(fileURLWithPath: "/dev/null"), format: .csv, hasHeader: true, nullToken: "NULL",
                                      columnNames: ["id", "name"], rowCount: 0, preview: [])
        let mappings = [DataImportColumnMapping(sourceName: "id", targetName: "id"), DataImportColumnMapping(sourceName: "name", targetName: "name")]
        XCTAssertEqual(try DataImportPlan(source: source, schemaName: "", tableName: "events", mappings: mappings).statement(engine: .clickhouse),
                       #"INSERT INTO "events" ("id", "name") FORMAT JSONEachRow"#)
        XCTAssertTrue(try DataImportPlan(source: source, schemaName: "", tableName: "events", mappings: mappings).statement(engine: .elasticsearch)
            .hasPrefix("POST /_bulk"))
        XCTAssertThrowsError(try DataImportPlan(source: source, schemaName: "", tableName: "Bad Index", mappings: mappings).statement(engine: .elasticsearch))
        XCTAssertThrowsError(try DataImportPlan(source: source, schemaName: "", tableName: "user:", mappings: mappings).statement(engine: .redis),
                             "Redis needs a key column")
        XCTAssertNoThrow(try DataImportPlan(source: source, schemaName: "", tableName: "user:", mappings: mappings, keyColumn: "id").statement(engine: .redis))

        let hit = try HTTPJSONValue.parse(#"{"_id":"7","_index":"i","_source":{"name":"A","address":{"city":"Oslo","zip":null},"tags":["x"]}}"#)
        let flat = ElasticsearchDataTransfer.flattened(hit)
        XCTAssertEqual(flat.map(\.0), ["_id", "address.city", "address.zip", "name", "tags"])
        XCTAssertEqual(flat.first { $0.0 == "address.zip" }?.1, .null)
    }

    // MARK: ClickHouse

    private func clickHouse() throws -> ConnectionProfile {
        guard let port = Int(environment["PORTBASE_TEST_CLICKHOUSE_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_CLICKHOUSE_PORT to the isolated ClickHouse HTTP fixture.")
        }
        return ConnectionProfile(name: "ClickHouse fixture", engine: .clickhouse, host: "127.0.0.1", port: port,
                                 username: "default", password: "local_fixture_only", database: "default", usesTLS: false)
    }

    func testClickHouseImportsInBatchesAndExportsPastTheDisplayLimit() async throws {
        let profile = try clickHouse()
        let table = "portbase_transfer_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try await DatabaseService.shared.execute(query: "CREATE TABLE \(table) (id UInt64, amount Decimal(12, 2), note Nullable(String), seen DateTime) ENGINE = Memory",
                                                     profile: profile, policy: .mutation())
        defer { Task { _ = try? await DatabaseService.shared.execute(query: "DROP TABLE IF EXISTS \(table)", profile: profile, policy: .mutation()) } }
        let rows = (1...2_500).map { "\($0),\($0).25,\($0 % 10 == 0 ? "NULL" : "\"note, \($0)\""),2026-01-02 03:04:05" }
        let file = try write("id,amount,note,seen\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
        let source = try DataTransferCodec.inspect(url: file, format: .csv, hasHeader: true, nullToken: "NULL", progress: { _ in })
        let plan = DataImportPlan(source: source, schemaName: "", tableName: table,
                                  mappings: ["id", "amount", "note", "seen"].map { DataImportColumnMapping(sourceName: $0, targetName: $0) })
        let imported = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: "default", policy: .mutation())
        XCTAssertEqual(imported.rowCount, 2_500)
        let check = try await DatabaseService.shared.execute(query: "SELECT count(), sum(amount), countIf(note IS NULL), any(note) FROM \(table) WHERE id = 11 OR id >= 0",
                                                             profile: profile, policy: .readOnly)
        XCTAssertEqual(check.rows.first?.cells[0], .integer("2500"))
        XCTAssertEqual(check.rows.first?.cells[1], .decimal("3126875"), "Decimals arrive exactly")
        XCTAssertEqual(check.rows.first?.cells[2], .integer("250"), "NULL stays NULL")

        let export = try await DatabaseService.shared.exportData(query: BoundQuery(sql: "SELECT number, toString(number) AS label FROM numbers(12005)", values: []),
                                                                 profile: profile, database: nil, format: .csv, policy: .readOnly)
        XCTAssertEqual(export.rowCount, 12_005, "Every row, past the 10,000-row display limit")
        let text = try String(contentsOf: try XCTUnwrap(export.fileURL), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("\"number\",\"label\"\r\n\"0\",\"0\"\r\n"), String(text.prefix(40)))

        do {
            _ = try await DatabaseService.shared.exportData(query: BoundQuery(sql: "SELECT throwIf(number = 2000000), toString(number) FROM numbers(3000000)", values: []),
                                                            profile: profile, database: nil, format: .json, policy: .readOnly, timeoutSeconds: 120)
            XCTFail("An error after rows started must not look like a complete export")
        } catch HTTPDatabaseError.serverMessage(let message) {
            XCTAssertTrue(message.contains("Code: 395"), message)
        }
        do {
            _ = try await DatabaseService.shared.exportData(query: BoundQuery(sql: "INSERT INTO \(table) VALUES (1, 1, NULL, now())", values: []),
                                                            profile: profile, database: nil, format: .csv, policy: .readOnly)
            XCTFail("Exports are read-only")
        } catch { }
    }

    // MARK: Elasticsearch

    private func elasticsearch() throws -> ConnectionProfile {
        guard let port = Int(environment["PORTBASE_TEST_ELASTICSEARCH_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_ELASTICSEARCH_PORT to the isolated Elasticsearch fixture.")
        }
        return ConnectionProfile(name: "Elasticsearch fixture", engine: .elasticsearch, host: "127.0.0.1", port: port,
                                 username: "", password: "", database: "_all", usesTLS: false)
    }

    func testElasticsearchBulkImportsAndScrollsEveryHit() async throws {
        let profile = try elasticsearch()
        let index = "portbase-transfer-" + UUID().uuidString.lowercased()
        defer { Task { _ = try? await DatabaseService.shared.execute(query: #"{"method":"DELETE","path":"/\#(index)"}"#, profile: profile, policy: .mutation()) } }
        _ = try await DatabaseService.shared.execute(query: #"{"method":"PUT","path":"/\#(index)","body":{"mappings":{"properties":{"n":{"type":"integer"},"name":{"type":"keyword"}}}}}"#,
                                                     profile: profile, policy: .mutation())
        let documents = (1...2_300).map { #"{"n": \#($0), "name": "doc \#($0)", "nested": {"even": \#($0 % 2 == 0)}}"# }
        let file = try write(documents.joined(separator: "\n") + "\n", extension: "json")
        let source = try DataTransferCodec.inspect(url: file, format: .json, hasHeader: true, nullToken: "NULL", progress: { _ in })
        let plan = DataImportPlan(source: source, schemaName: "", tableName: index,
                                  mappings: source.columnNames.map { DataImportColumnMapping(sourceName: $0, targetName: $0) })
        let imported = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: nil, policy: .mutation())
        XCTAssertEqual(imported.rowCount, 2_300)

        let search = BoundQuery(sql: #"{"method":"POST","path":"/\#(index)/_search","body":{"query":{"match_all":{}},"size":5}}"#, values: [])
        let json = try await DatabaseService.shared.exportData(query: search, profile: profile, database: nil, format: .json, policy: .readOnly)
        XCTAssertEqual(json.rowCount, 2_300, "The search's own size doesn't cut the export short")
        let csv = try await DatabaseService.shared.exportData(query: search, profile: profile, database: nil, format: .csv, policy: .readOnly)
        XCTAssertEqual(csv.rowCount, 2_300)
        let header = try String(contentsOf: try XCTUnwrap(csv.fileURL), encoding: .utf8).components(separatedBy: "\r\n").first
        XCTAssertEqual(header, #""_id","n","name","nested.even""#)

        let bad = try write(#"{"n": "not a number"}"# + "\n", extension: "json")
        let badSource = try DataTransferCodec.inspect(url: bad, format: .json, hasHeader: true, nullToken: "NULL", progress: { _ in })
        do {
            _ = try await DatabaseService.shared.importData(plan: DataImportPlan(source: badSource, schemaName: "", tableName: index,
                mappings: [DataImportColumnMapping(sourceName: "n", targetName: "n")]), profile: profile, database: nil, policy: .mutation())
            XCTFail("A rejected document must stop the import")
        } catch DataTransferError.partialImport(let completed, _) {
            XCTAssertEqual(completed, 0)
        }
    }

    // MARK: Redis

    private func redis() throws -> ConnectionProfile {
        guard let port = Int(environment["PORTBASE_TEST_REDIS_PORT"] ?? "") else { throw XCTSkip("Set the isolated Redis fixture port.") }
        return ConnectionProfile(name: "Redis fixture", engine: .redis, host: "127.0.0.1", port: port,
                                 username: "", password: environment["PORTBASE_TEST_REDIS_PASSWORD"] ?? "", database: "0", usesTLS: false)
    }

    func testRedisImportsHashesAndExportsCursorsAndRangesToTheEnd() async throws {
        let profile = try redis()
        let prefix = "portbase_transfer_" + UUID().uuidString + ":"
        func run(_ command: String) async throws -> QueryResultTable {
            try await DatabaseService.shared.execute(query: command, profile: profile, database: "0", policy: .mutation())
        }
        let rows = (1...1_500).map { "\($0),Name \($0),\($0 * 2)" }
        let file = try write("id,name,score\n" + rows.joined(separator: "\n") + "\n", extension: "csv")
        let source = try DataTransferCodec.inspect(url: file, format: .csv, hasHeader: true, nullToken: "NULL", progress: { _ in })
        let plan = DataImportPlan(source: source, schemaName: "", tableName: prefix + "user:",
                                  mappings: [DataImportColumnMapping(sourceName: "name", targetName: "name"),
                                             DataImportColumnMapping(sourceName: "score", targetName: "score")],
                                  keyColumn: "id")
        let imported = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: "0", policy: .mutation())
        XCTAssertEqual(imported.rowCount, 1_500)
        let field = try await DatabaseService.shared.execute(query: #"HGET "\#(prefix)user:42" score"#, profile: profile, database: "0", policy: .readOnly)
        XCTAssertEqual(field.rows.first?.cells.first, .text("84"))

        let keys = try await DatabaseService.shared.exportData(query: BoundQuery(sql: #"SCAN 0 MATCH "\#(prefix)user:*" COUNT 10"#, values: []),
                                                               profile: profile, database: "0", format: .csv, policy: .readOnly)
        XCTAssertEqual(keys.rowCount, 1_500, "Every key once, following the cursor to its end")

        for start in stride(from: 0, to: 2_500, by: 500) {
            _ = try await run("RPUSH \"\(prefix)list\" " + (start..<(start + 500)).map(String.init).joined(separator: " "))
        }
        let list = try await DatabaseService.shared.exportData(query: BoundQuery(sql: #"LRANGE "\#(prefix)list" 0 99"#, values: []),
                                                               profile: profile, database: "0", format: .csv, policy: .readOnly)
        XCTAssertEqual(list.rowCount, 100, "A bounded range exports what it names")
        let whole = try await DatabaseService.shared.exportData(query: BoundQuery(sql: #"LRANGE "\#(prefix)list" -2500 -1"#, values: []),
                                                                profile: profile, database: "0", format: .csv, policy: .readOnly)
        XCTAssertEqual(whole.rowCount, 2_500)
        let wholeText = try String(contentsOf: try XCTUnwrap(whole.fileURL), encoding: .utf8)
        XCTAssertTrue(wholeText.hasSuffix("\"2499\",\"2499\"\r\n"), "Indexes run across pages: " + String(wholeText.suffix(30)))

        for index in 0..<2_100 { _ = try await run("XADD \"\(prefix)stream\" \(index + 1)-0 n \(index)") }
        let stream = try await DatabaseService.shared.exportData(query: BoundQuery(sql: #"XRANGE "\#(prefix)stream" - + COUNT 10"#, values: []),
                                                                 profile: profile, database: "0", format: .json, policy: .readOnly)
        XCTAssertEqual(stream.rowCount, 2_100, "Each page starts just past the last entry")

        _ = try await run("UNLINK \"\(prefix)list\" \"\(prefix)stream\"")
        for start in stride(from: 1, through: 1_500, by: 500) {
            _ = try await run("UNLINK " + (start..<(start + 500)).map { "\"\(prefix)user:\($0)\"" }.joined(separator: " "))
        }
    }

    private func write(_ text: String, extension suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
