import XCTest
@testable import PortSQL

final class HTTPDatabaseClientTests: XCTestCase {
    func testClickHouseQueriesTypesSchemaAndLimits() async throws {
        XCTAssertTrue(ClickHouseQueryService.isReadOnly("SELECT 'INSERT; SETTINGS readonly=0'"))
        for query in ["SELECT 1; DROP TABLE x", "SELECT 1 SETTINGS readonly=0", "SELECT 1 FORMAT CSV", "BACKUP TABLE x TO Disk('x')", "SET readonly=0"] {
            XCTAssertThrowsError(try ClickHouseQueryService.classify(query))
        }
        var disconnected = profile(engine: .clickhouse, port: 1)
        disconnected.isReadOnly = true
        do {
            _ = try await DatabaseService.shared.execute(query: "INSERT INTO x VALUES (1)", profile: disconnected, policy: .userQuery(confirmed: true))
            XCTFail("Read-only profiles must reject writes before connecting")
        } catch { XCTAssertTrue(error is DatabaseServiceError) }
        guard let port = Int(ProcessInfo.processInfo.environment["PORTBASE_TEST_CLICKHOUSE_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_CLICKHOUSE_PORT to the isolated ClickHouse HTTP fixture.")
        }
        let profile = profile(engine: .clickhouse, port: port)
        let table = "portbase_http_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let types = try await DatabaseService.shared.execute(query: "SELECT toUInt64('18446744073709551615') AS big, toDecimal128('12345678901234567890.123456789012345678', 18) AS amount, CAST(NULL AS Nullable(String)) AS absent, '' AS empty, toDateTime64('2024-01-02 03:04:05.123456', 6, 'UTC') AS moment",
            profile: profile, policy: .readOnly)
        let cells = try XCTUnwrap(types.rows.first?.cells)
        XCTAssertEqual(cells[0], .integer("18446744073709551615"))
        XCTAssertEqual(cells[1], .decimal("12345678901234567890.123456789012345678"))
        XCTAssertEqual(cells[2], .null)
        XCTAssertEqual(cells[3], .text(""))
        XCTAssertEqual(cells[4], .dateTime("2024-01-02 03:04:05.123456"))
        let capped = try await DatabaseService.shared.execute(query: "SELECT number FROM numbers(10023)", profile: profile, policy: .readOnly)
        XCTAssertEqual(capped.rows.count, 10_000)
        XCTAssertEqual(capped.isTruncated, true)
        _ = try await DatabaseService.shared.execute(query: "CREATE TABLE \(table) (id UInt64, note Nullable(String)) ENGINE = Memory", profile: profile, policy: .mutation())
        do {
            _ = try await DatabaseService.shared.execute(query: "INSERT INTO \(table) VALUES (1, '日本語')", profile: profile, policy: .mutation())
            let rows = try await DatabaseService.shared.execute(query: "SELECT * FROM \(table)", profile: profile, policy: .readOnly)
            XCTAssertEqual(rows.rows.first?.cells, [.integer("1"), .text("日本語")])
            let schema = try await DatabaseService.shared.loadSchema(profile: profile, database: "default")
            XCTAssertEqual(schema.first(where: { $0.name == table })?.columns.map(\.name), ["id", "note"])
            let databases = try await DatabaseService.shared.listDatabases(profile: profile)
            XCTAssertTrue(databases.contains("default"))
        } catch {
            _ = try? await DatabaseService.shared.execute(query: "DROP TABLE IF EXISTS \(table)", profile: profile, policy: .mutation())
            throw error
        }
        _ = try await DatabaseService.shared.execute(query: "DROP TABLE \(table)", profile: profile, policy: .mutation())
    }

    func testElasticsearchDocumentsMappingsAggregationsAndEndpointPolicy() async throws {
        for request in [#"{"method":"GET","path":"/_snapshot/_all"}"#, #"{"method":"GET","path":"//other.example/_search"}"#,
                        #"{"method":"GET","path":"/index/../_search"}"#, #"{"method":"POST","path":"/_search","body":{"script_fields":{"x":{"script":"1"}}}}"#] {
            XCTAssertThrowsError(try ElasticsearchQueryService.parse(request))
        }
        let precise = try HTTPJSONValue.parse(#"{"id":18446744073709551615,"value":12345678901234567890.123456789012345678}"#)
        XCTAssertEqual(precise["id"]?.cell, .integer("18446744073709551615"))
        XCTAssertEqual(precise["value"]?.cell, .decimal("12345678901234567890.123456789012345678"))
        XCTAssertThrowsError(try HTTPJSONValue.parse(#"{"a":1,"a":2}"#))
        let postRead = try ElasticsearchQueryService.parse(ElasticsearchQueryService.browse(index: "_all", limit: 100, offset: 0))
        XCTAssertTrue(postRead.isReadOnly)
        XCTAssertTrue(try ElasticsearchQueryService.parse(ElasticsearchQueryService.browse(index: "顧客-данные-équipe", limit: 100, offset: 0)).isReadOnly)
        XCTAssertFalse(ElasticsearchQueryService.validIndex("ÉQUIPE", allowPattern: false))
        XCTAssertFalse(ElasticsearchQueryService.validIndex("safe\u{200B}name", allowPattern: false))
        guard let port = Int(ProcessInfo.processInfo.environment["PORTBASE_TEST_ELASTICSEARCH_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_ELASTICSEARCH_PORT to the isolated Elasticsearch HTTP fixture.")
        }
        let profile = profile(engine: .elasticsearch, port: port)
        let index = "portbase-http-" + UUID().uuidString.lowercased()
        let create = envelope("PUT", "/\(index)", #"{"mappings":{"properties":{"category":{"type":"keyword"},"amount":{"type":"double"}}}}"#)
        do {
            _ = try await DatabaseService.shared.execute(query: create, profile: profile, policy: .readOnly)
            XCTFail("A read-only call must not create an index")
        } catch { XCTAssertTrue(error is DatabaseServiceError) }
        _ = try await DatabaseService.shared.execute(query: create, profile: profile, policy: .mutation())
        do {
            _ = try await DatabaseService.shared.execute(query: envelope("PUT", "/\(index)/_doc/one", #"{"category":"a","amount":13.25,"empty":"","absent":null,"script":"stored text","nested":{"enabled":true}}"#), profile: profile, policy: .mutation())
            let rows = try await DatabaseService.shared.execute(query: ElasticsearchQueryService.browse(index: index, limit: 100, offset: 0), profile: profile, policy: .readOnly)
            XCTAssertEqual(rows.rows.count, 1)
            let source = try HTTPJSONValue.parse(XCTUnwrap(rows.documents?.first))["_source"]
            XCTAssertEqual(source?["amount"]?.cell, .decimal("13.25"))
            XCTAssertEqual(source?["empty"]?.cell, .text(""))
            XCTAssertEqual(source?["absent"]?.cell, .null)
            let amountColumn = try XCTUnwrap(rows.columns.firstIndex(where: { $0.name == "_source.amount" }))
            XCTAssertEqual(rows.rows[0].cells[amountColumn], .decimal("13.25"))
            let schema = try await DatabaseService.shared.loadSchema(profile: profile)
            XCTAssertEqual(schema.first(where: { $0.name == index })?.columns.first(where: { $0.name == "category" })?.type, "keyword")
            let aggregation = try await DatabaseService.shared.execute(query: envelope("POST", "/\(index)/_search", #"{"size":0,"aggs":{"categories":{"terms":{"field":"category"},"aggs":{"amount":{"sum":{"field":"amount"}}}}}}"#), profile: profile, policy: .readOnly)
            XCTAssertEqual(aggregation.rows.count, 1)
            XCTAssertTrue(aggregation.columns.contains { $0.name == "amount.value" })
            _ = try await DatabaseService.shared.execute(query: envelope("POST", "/\(index)/_update/one", #"{"doc":{"amount":25}}"#), profile: profile, policy: .mutation())
            let updated = try await DatabaseService.shared.execute(query: envelope("GET", "/\(index)/_doc/one"), profile: profile, policy: .readOnly)
            XCTAssertEqual(try HTTPJSONValue.parse(XCTUnwrap(updated.documents?.first))["_source"]?["amount"]?.cell, .integer("25"))
        } catch {
            _ = try? await DatabaseService.shared.execute(query: envelope("DELETE", "/\(index)"), profile: profile, policy: .mutation())
            throw error
        }
        _ = try await DatabaseService.shared.execute(query: envelope("DELETE", "/\(index)"), profile: profile, policy: .mutation())
    }

    func testHTTPPrivateCAValidatesOriginalHostnameAndNeverDowngrades() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTBASE_TEST_HTTP_TLS_PORT"] ?? ""),
              let ca = Data(base64Encoded: ProcessInfo.processInfo.environment["PORTBASE_TEST_HTTP_CA_B64"] ?? ""),
              let pem = String(data: ca, encoding: .utf8) else {
            throw XCTSkip("Set PORTBASE_TEST_HTTP_TLS_PORT and PORTBASE_TEST_HTTP_CA_B64 to the isolated localhost TLS fixture.")
        }
        var profile = profile(engine: .clickhouse, port: port)
        profile.host = "localhost"; profile.transportSecurityMode = .privateCA; profile.privateCACertificate = pem
        let rows = try await DatabaseService.shared.execute(query: "SELECT 1", profile: profile, policy: .readOnly)
        XCTAssertEqual(rows.rows.first?.cells.first, .integer("1"))
        for mode in [TransportSecurityMode.systemCA, .preferTLS, .privateCA] {
            profile.transportSecurityMode = mode
            profile.host = mode == .privateCA ? "127.0.0.1" : "localhost"
            do {
                _ = try await DatabaseService.shared.execute(query: "SELECT 1", profile: profile, policy: .readOnly, timeoutSeconds: 3)
                XCTFail("Untrusted or mismatched certificates must fail without plaintext fallback")
            } catch { /* Expected TLS trust/identity failure. */ }
        }
    }

    private func profile(engine: DatabaseEngine, port: Int) -> ConnectionProfile {
        ConnectionProfile(name: "Disposable HTTP fixture", engine: engine, host: "127.0.0.1", port: port,
            username: engine == .clickhouse ? "default" : "", password: engine == .clickhouse ? "local_fixture_only" : "",
            database: engine == .clickhouse ? "default" : "_all", usesTLS: false)
    }

    private func envelope(_ method: String, _ path: String, _ body: String? = nil) -> String {
        "{\"method\":" + DataTransferCodec.jsonString(method) + ",\"path\":" + DataTransferCodec.jsonString(path) + (body.map { ",\"body\":" + $0 } ?? "") + "}"
    }
}
