import XCTest
import NIOCore
import NIOPosix
@preconcurrency import SwiftBSON
@testable import PortSQL

final class MongoQueryServiceTests: XCTestCase {
    func testFindBuilderPreservesTypesProjectionAndCompoundSort() throws {
        var draft = MongoQueryDraft()
        draft.collection = "orders\".archive"
        draft.filter = #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"value":{"$numberLong":"9223372036854775807"}}"#
        draft.projection = #"{"name":1,"totals.revenue":1}"#
        draft.sort = #"{"z":1,"a":-1}"#
        draft.skip = "25"
        let query = try MongoQueryService.parse(draft.command(fallbackCollection: nil))
        XCTAssertEqual(query.command["find"]?.stringValue, draft.collection)
        XCTAssertEqual(query.command["sort"]?.documentValue?.keys, ["z", "a"])
        XCTAssertEqual(query.command["filter"]?.documentValue?["value"]?.int64Value, Int64.max)
        XCTAssertEqual(query.command["projection"]?.documentValue?.keys, ["name", "totals.revenue"])
        draft.limit = "0"
        XCTAssertThrowsError(try draft.command(fallbackCollection: nil))
        draft.limit = "100"
        draft.filter = "[]"
        XCTAssertThrowsError(try draft.command(fallbackCollection: nil))
    }

    func testAggregationBuilderOrdersStagesAndBlocksNestedWrites() throws {
        var draft = MongoQueryDraft()
        draft.mode = .aggregate
        draft.stages = [MongoPipelineStage(operation: "$limit", body: "10", isEnabled: false),
                        MongoPipelineStage(operation: "$group", body: #"{"_id":"$category","total":{"$sum":"$amount"}}"#),
                        MongoPipelineStage(operation: "$sort", body: #"{"total":-1}"#)]
        let query = try MongoQueryService.parse(draft.command(fallbackCollection: "orders"))
        XCTAssertEqual(query.command["pipeline"]?.arrayValue?.compactMap { $0.documentValue?.keys.first }, ["$group", "$sort"])
        draft.stages.append(MongoPipelineStage(operation: "$facet", body: #"{"copy":[{"$out":"other"}]}"#))
        XCTAssertThrowsError(try draft.command(fallbackCollection: "orders"))
    }

    func testNestedFieldsRemainTypedAndChartableWithoutChangingDocumentExport() throws {
        let document: BSONDocument = ["_id": .objectID(), "category": "A", "totals": ["revenue": 42], "items": [1, 2], "literal.dot": "value"]
        let result = MongoDatabaseClient.makeResult(documents: [document, ["category": "B"]], affectedRows: nil, truncated: false, profileName: "Test")
        let preset = VisualizationService.defaultPreset(for: result, connectionProfileID: nil, connectionName: "Test", databaseName: nil, sourceTableReference: nil)
        XCTAssertEqual(preset.xField, "category")
        XCTAssertEqual(preset.yField, "totals.revenue")
        let index = try XCTUnwrap(result.columns.firstIndex { $0.name == "totals.revenue" })
        XCTAssertEqual(result.rows[0].cells[index], .integer("42"))
        XCTAssertTrue(VisualizationService.fieldDescriptors(for: result).contains { $0.name == "totals.revenue" && $0.supportsNumeric })
        XCTAssertEqual(try MongoExtendedJSON.decode(XCTUnwrap(result.documents?.first)), document)
        let collision = MongoDatabaseClient.makeResult(documents: [["a.b": 9, "a": ["b": 1]]], affectedRows: nil, truncated: false, profileName: "Test")
        let collisionIndex = try XCTUnwrap(collision.columns.firstIndex { $0.name == "a.b" })
        XCTAssertEqual(collision.rows[0].cells[collisionIndex], .integer("9"))
    }

    func testReadsAndWritesAreClassifiedByCommandNotDocumentText() throws {
        XCTAssertTrue(try MongoQueryService.parse(#"{"find":"orders","filter":{"note":"delete drop update"}}"#).isReadOnly)
        for command in [
            #"{"insert":"orders","documents":[{"name":"test"}]}"#,
            #"{"update":"orders","updates":[{"q":{},"u":{"$set":{"x":1}}}]}"#,
            #"{"delete":"orders","deletes":[{"q":{},"limit":0}]}"#,
            #"{"aggregate":"orders","pipeline":[{"$out":"copy"}],"cursor":{}}"#,
            #"{"aggregate":"orders","pipeline":[{"$merge":{"into":"copy"}}],"cursor":{}}"#
        ] {
            XCTAssertFalse(try MongoQueryService.parse(command).isReadOnly)
            XCTAssertTrue(MongoQueryService.assessment(for: command, readOnly: true)?.blocksExecution == true)
            XCTAssertTrue(MongoQueryService.assessment(for: command, readOnly: false)?.requiresConfirmation == true)
        }
    }

    func testUnsafeCommandsOptionsAndNestedJavaScriptAreRejected() {
        for text in [
            #"{"eval":"db.orders.drop()"}"#,
            #"{"find":"orders","$db":"other"}"#,
            #"{"find":"orders","delete":"orders"}"#,
            #"{"find":"orders","find":"other"}"#,
            #"{"find":"orders","filter":{"a":1,"a":2}}"#,
            #"{"find":"orders",}"#,
            #"{"find":"orders","filter":{"$where":"true"}}"#,
            #"{"aggregate":"orders","pipeline":[{"$project":{"x":{"$function":{"body":"return 1","args":[],"lang":"js"}}}}]}"#,
            #"{"aggregate":"orders","pipeline":[{"$changeStream":{}}]}"#,
            #"{"find":"orders","tailable":true}"#,
            #"{"getMore":123,"collection":"orders"}"#,
            #"{"find":"orders","lsid":{"id":"test"}}"#,
            #"{"find":"orders","autocommit":false}"#,
            #"{"aggregate":"orders","pipeline":[{"$match":{},"$out":"copy"}]}"#,
            "db.orders.find({})", "[]", "{}", String(repeating: " ", count: 1_048_577)
        ] {
            XCTAssertThrowsError(try MongoQueryService.parse(text), String(text.prefix(100)))
        }
    }

    func testExplainRejectsWritesIncludingAggregationOutput() throws {
        XCTAssertNotNil(MongoQueryService.explain(#"{"find":"orders"}"#))
        XCTAssertNil(MongoQueryService.explain(#"{"delete":"orders","deletes":[]}"#))
        XCTAssertThrowsError(try MongoQueryService.parse(#"{"explain":{"aggregate":"orders","pipeline":[{"$out":"copy"}]}}"#))
        XCTAssertThrowsError(try MongoQueryService.parse(#"{"explain":{"explain":{"find":"orders"}}}"#))
    }

    func testCommandOrderAndCompoundSortOrderArePreserved() throws {
        let query = try MongoQueryService.parse(#"{"filter":{},"sort":{"z":1,"a":-1},"find":"orders"}"#)
        XCTAssertEqual(query.command.keys.first, "find")
        XCTAssertEqual(query.command["sort"]?.documentValue?.keys, ["z", "a"])
        let formatted = MongoQueryService.pretty(query.command)
        XCTAssertEqual(try MongoQueryService.parse(formatted).command, query.command)
        XCTAssertEqual(try MongoQueryService.parse(formatted).command["sort"]?.documentValue?.keys, ["z", "a"])
        let embedded = try MongoExtendedJSON.decode(#"{"nested":{"z":1,"a":2},"long":9223372036854775807}"#)
        XCTAssertEqual(try MongoExtendedJSON.decode(MongoExtendedJSON.encode(embedded, canonical: true)), embedded)
    }

    func testBrowseTreatsCollectionNamesAsDataAndValidatesFilters() throws {
        let name = "orders\"; DROP TABLE users;"
        let text = try MongoQueryService.browse(collection: name, filter: "{}", sort: #"{"z":1,"a":-1}"#, limit: 25, skip: 50)
        let query = try MongoQueryService.parse(text)
        XCTAssertEqual(query.command["find"]?.stringValue, name)
        XCTAssertEqual(query.command["skip"]?.toInt(), 50)
        XCTAssertTrue(query.isReadOnly)
        XCTAssertThrowsError(try MongoQueryService.browse(collection: "orders", filter: "{broken", sort: "", limit: 25, skip: 0))
    }

    func testExtendedJSONPreservesAllDocumentTypesAndMissingFieldsInExport() throws {
        let json = #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"null":null,"empty":"","nested":{"x":1},"array":[1,null,""],"long":{"$numberLong":"9223372036854775807"},"decimal":{"$numberDecimal":"1234567890.123456789012345678901234"},"date":{"$date":{"$numberLong":"1700000000123"}},"bytes":{"$binary":{"base64":"AAEC","subType":"80"}}}"#
        let document = try BSONDocument(fromJSON: json)
        let result = MongoDatabaseClient.makeResult(documents: [document, ["empty": ""]], affectedRows: nil, truncated: false, profileName: "Test")
        XCTAssertEqual(result.rows[0].cells[result.columns.firstIndex { $0.name == "null" }!], .null)
        XCTAssertEqual(try MongoExtendedJSON.decode(XCTUnwrap(result.documents?.first)), document)
        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .json))
        let decoded = try ExtendedJSONDecoder().decode([BSONDocument].self, from: Data(contentsOf: url))
        XCTAssertTrue(decoded[0].equalsIgnoreKeyOrder(document))
        XCTAssertEqual(decoded[1], ["empty": ""])
        XCTAssertFalse(decoded[1].hasKey("null"))
    }

    func testNestedValuesDisplayAsReadableJSONWhileCopyAndExportKeepCanonicalTypes() throws {
        let json = #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"customer":{"id":{"$numberInt":"813"},"name":"Aisha Okafor","since":{"$date":{"$numberLong":"1700000000123"}}},"tags":["a/b",{"$numberLong":"9"},{"$numberDouble":"2.5"},{"$numberDecimal":"12.50"},null],"swatch":{"$binary":{"base64":"iVBORw==","subType":"00"}},"key":{"$binary":{"base64":"EjRWeJASNFZ4kBI0VniQEg==","subType":"04"}},"placed":{"$date":{"$numberLong":"1700000000123"}}}"#
        let document = try MongoExtendedJSON.decode(json)
        let result = MongoDatabaseClient.makeResult(documents: [document, document], affectedRows: nil, truncated: false, profileName: "Test")
        func cell(_ name: String) throws -> QueryCell { result.rows[0].cells[try XCTUnwrap(result.columns.firstIndex { $0.name == name })] }

        let customer = try cell("customer")
        XCTAssertEqual(customer.displayValue, #"{"id": 813, "name": "Aisha Okafor", "since": {"$date": "2023-11-14T22:13:20.123Z"}}"#)
        XCTAssertEqual(try cell("tags").displayValue, #"["a/b", 9, 2.5, 12.50, null]"#)
        XCTAssertEqual(try cell("_id").displayValue, #"{"$oid": "507f1f77bcf86cd799439011"}"#)
        let size = ByteCountFormatter.string(fromByteCount: 4, countStyle: .file)
        XCTAssertEqual(try cell("swatch").displayValue, L10n.format("Binary(%@, subtype %@)", size, "00"))
        XCTAssertEqual(try cell("key").displayValue, #"UUID("12345678-9012-3456-7890-123456789012")"#)
        XCTAssertEqual(try cell("placed"), .dateTime("2023-11-14T22:13:20.123Z"))

        // The exact value still carries every BSON type, so copy and export round-trip.
        for name in ["customer", "tags", "_id", "swatch", "key"] {
            let exact = try cell(name).exactValue
            XCTAssertEqual(try MongoExtendedJSON.decode("{\"v\":" + exact + "}")["v"], document[name], name)
        }
        XCTAssertTrue(customer.exactValue.contains(#""$numberInt":"813""#))
        XCTAssertTrue(try cell("swatch").exactValue.contains(#""subType":"00""#))

        let insight = ResultInsightsService.insight(column: try XCTUnwrap(result.columns.firstIndex { $0.name == "customer" }), in: result)
        XCTAssertEqual(insight.kind, .json)
        XCTAssertEqual(insight.topValues.first?.value, customer.displayValue)

        let columns = try ["customer", "swatch"].map { name in try XCTUnwrap(result.columns.firstIndex { $0.name == name }) }
        let payload = ResultGridClipboard.Payload(columns: columns.map { result.columns[$0] },
                                                  rows: [QueryRow(cells: columns.map { result.rows[0].cells[$0] })])
        for text in [ResultGridClipboard.text(payload, headers: false), ResultCopyFormatter.text(payload, format: .csv),
                     ResultCopyFormatter.text(payload, format: .json)] {
            XCTAssertTrue(text.contains("$numberInt") && text.contains("$binary"), text)
        }
        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .csv))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("$numberInt"))
        XCTAssertEqual(try JSONDecoder().decode(QueryCell.self, from: JSONEncoder().encode(customer)), customer)
    }

    func testReadableDisplayFormatsScalarsAndIndentsWhenPretty() throws {
        XCTAssertEqual(MongoExtendedJSON.display(.double(5)), "5.0")
        XCTAssertEqual(MongoExtendedJSON.display(.double(.nan)), "NaN")
        XCTAssertEqual(MongoExtendedJSON.display(.double(-.infinity)), "-Infinity")
        XCTAssertEqual(MongoExtendedJSON.display(.int64(9_223_372_036_854_775_807)), "9223372036854775807")
        XCTAssertEqual(MongoExtendedJSON.display(.null), "null")
        XCTAssertEqual(MongoExtendedJSON.display(.string("line\n\"quoted\" a/b")), #""line\n\"quoted\" a/b""#)
        XCTAssertEqual(MongoExtendedJSON.display(.document([:])), "{}")
        XCTAssertEqual(MongoExtendedJSON.display(.array([])), "[]")
        // Dates outside the years relaxed JSON writes as text keep their millisecond form.
        XCTAssertEqual(MongoExtendedJSON.display(.datetime(Date(timeIntervalSince1970: -1))), #"{"$date":{"$numberLong":"-1000"}}"#)
        XCTAssertEqual(MongoExtendedJSON.isoDate(Date(timeIntervalSince1970: -0.5)), "1969-12-31T23:59:59.500Z")

        let canonical = #"{"a":{"$numberInt":"1"},"b":[{"c":true},{"$numberLong":"2"}],"d":{}}"#
        XCTAssertEqual(MongoExtendedJSON.display(canonical: canonical, pretty: true), """
        {
          "a": 1,
          "b": [
            {
              "c": true
            },
            2
          ],
          "d": {}
        }
        """)
        XCTAssertEqual(MongoExtendedJSON.display(canonical: canonical, pretty: false), #"{"a": 1, "b": [{"c": true}, 2], "d": {}}"#)
        XCTAssertNil(MongoExtendedJSON.display(canonical: "{broken", pretty: true))
        XCTAssertEqual(MongoDatabaseClient.cell(nil), .json("{\"$missing\":true}"))
    }

    func testSQLParameterScannerDoesNotRewriteMongoJSON() throws {
        let json = #"{"find":"orders","filter":{"url":"https://host/:id","nested":{"value":null}}}"#
        XCTAssertEqual(QueryParameterService.parameters(in: json, engine: .mongodb), [])
        XCTAssertEqual(try QueryParameterService.boundQuery(sql: json, values: ["id": "bad"], engine: .mongodb).sql, json)
    }

    func testWritePolicyRejectsWritesBeforeAttemptingNetworkConnection() async {
        let profile = ConnectionProfile(name: "Test", engine: .mongodb, host: "127.0.0.1", port: 1,
                                        username: "", password: "", database: "test", usesTLS: false)
        for policy: DatabaseExecutionPolicy in [.readOnly, .userQuery(confirmed: false), .mutation(expectedAffectedRows: 1)] {
            do {
                _ = try await DatabaseService.shared.execute(query: #"{"delete":"orders","deletes":[{"q":{},"limit":0}]}"#,
                    profile: profile, policy: policy)
                XCTFail("Write must be rejected without contacting the server")
            } catch {
                XCTAssertTrue(error is DatabaseServiceError)
            }
        }
        var readOnly = profile
        readOnly.isReadOnly = true
        do {
            _ = try await DatabaseService.shared.execute(query: #"{"insert":"orders","documents":[{}]}"#,
                profile: readOnly, policy: .userQuery(confirmed: true))
            XCTFail("Read-only bookmarks must reject confirmed writes")
        } catch {
            XCTAssertTrue(error is DatabaseServiceError)
        }
    }

    func testMongoBookmarkRoundTripRedactsCredentialsAndRetainsAuthSource() throws {
        var profile = ConnectionProfile(name: "Mongo", engine: .mongodb, host: "db.example.com", port: 27017,
                                        username: "tester", password: "test-secret", database: "app")
        profile.authenticationDatabase = "identity"
        let data = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-secret"))
        let copy = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(copy.engine, .mongodb)
        XCTAssertEqual(copy.authenticationDatabase, "identity")
        XCTAssertEqual(copy.transportSecurityMode, .systemCA)
    }

    func testAdaptiveLayoutUsesWindowSpaceAndAccessibilityInsteadOfDeviceIdentity() {
        XCTAssertTrue(WorkspaceLayout.usesColumns(width: 900, height: 650, regularWidth: true, accessibilitySize: false))
        XCTAssertFalse(WorkspaceLayout.usesColumns(width: 390, height: 844, regularWidth: false, accessibilitySize: false))
        XCTAssertFalse(WorkspaceLayout.usesColumns(width: 600, height: 800, regularWidth: true, accessibilitySize: false))
        XCTAssertFalse(WorkspaceLayout.usesColumns(width: 900, height: 300, regularWidth: true, accessibilitySize: false))
        XCTAssertFalse(WorkspaceLayout.usesColumns(width: 900, height: 650, regularWidth: true, accessibilitySize: true))
    }

    func testUnicodeHighlightRangesUseUTF16Offsets() {
        let sql = "SELECT '👩🏽‍💻日本語', 42;"
        let text = sql as NSString
        let number = SQLSyntaxHighlighter.tokens(in: sql).first { $0.kind == .numberLiteral }!
        XCTAssertEqual(text.substring(with: number.range), "42")
        let json = #"{"👩🏽‍💻":"a\\\"b","number":-1.2e+3,"flag":true}"#
        let jsonText = json as NSString
        XCTAssertTrue(JSONSyntaxHighlighter.tokens(in: json).contains { $0.kind == .numberLiteral && jsonText.substring(with: $0.range) == "-1.2e+3" })
    }

    /// Recoloring only the changed range after an edit gives the same colors as coloring the whole text,
    /// even when the edit opens a string or comment that recolors everything after it.
    func testChangedHighlightRangeMatchesFullHighlighting() {
        func colors(_ tokens: [SQLToken], length: Int) -> [SQLTokenKind?] {
            var colors = [SQLTokenKind?](repeating: nil, count: length)
            for token in tokens { for index in token.range.location..<NSMaxRange(token.range) { colors[index] = token.kind } }
            return colors
        }
        let text = "SELECT id, name FROM users WHERE name = 'x' -- note\nAND id > 3;"
        let edits: [(NSRange, String)] = [
            (NSRange(location: 7, length: 0), "a"), (NSRange(location: 0, length: 1), ""), (NSRange(location: 21, length: 0), "'"),
            (NSRange(location: 21, length: 0), "-- "), (NSRange(location: 41, length: 1), ""), (NSRange(location: 52, length: 0), "/*"),
            (NSRange(location: 9, length: 0), " "), (NSRange(location: (text as NSString).length, length: 0), " LIMIT 10"),
            (NSRange(location: 7, length: 2), "count(*)"),
        ]
        for (range, replacement) in edits {
            let edited = (text as NSString).replacingCharacters(in: range, with: replacement)
            let old = SQLSyntaxHighlighter.tokens(in: text), new = SQLSyntaxHighlighter.tokens(in: edited)
            let newLength = (edited as NSString).length, inserted = (replacement as NSString).length
            // The storage after the edit: inserted text takes the color before it, as typing does.
            var shown = colors(old, length: (text as NSString).length)
            let inherited = range.location > 0 ? shown[range.location - 1] : nil
            shown.replaceSubrange(range.location..<NSMaxRange(range), with: [SQLTokenKind?](repeating: inherited, count: inserted))
            let changed = SQLSyntaxHighlighter.changedRange(from: old, to: new, oldLength: (text as NSString).length, newLength: newLength)
            let dirty = NSUnionRange(changed, NSRange(location: range.location, length: inserted))
            let full = colors(new, length: newLength)
            for index in dirty.location..<NSMaxRange(dirty) { shown[index] = full[index] }
            XCTAssertEqual(shown, full, "Editing \(range) with \"\(replacement)\"")
        }
        XCTAssertEqual(SQLSyntaxHighlighter.changedRange(from: SQLSyntaxHighlighter.tokens(in: text), to: SQLSyntaxHighlighter.tokens(in: text),
                                                         oldLength: (text as NSString).length, newLength: (text as NSString).length).length, 0)
    }
}

final class MongoIntegrationTests: XCTestCase {
    func testPrivateCATLSHostnameValidationAndNoDowngrade() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["PORTSQL_TEST_MONGODB_TLS_PORT"] ?? ""),
              let data = Data(base64Encoded: environment["PORTSQL_TEST_MONGODB_CA_B64"] ?? ""),
              let certificate = String(data: data, encoding: .utf8) else {
            throw XCTSkip("Set the local MongoDB TLS fixture port and certificate.")
        }
        var profile = ConnectionProfile(name: "TLS fixture", engine: .mongodb, host: "localhost", port: port,
                                        username: "", password: "", database: "test", transportSecurityMode: .privateCA,
                                        privateCACertificate: certificate)
        let result = try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: 5)
        XCTAssertEqual(result.rows.count, 1)
        profile.host = "127.0.0.1" // The fixture certificate has a DNS SAN only.
        do {
            _ = try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: 5)
            XCTFail("IP connections must require an IP SAN")
        } catch { }
        profile.host = "localhost"
        for mode: TransportSecurityMode in [.systemCA, .preferTLS] {
            profile.transportSecurityMode = mode
            do {
                _ = try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: 5)
                XCTFail("Untrusted certificate must fail closed")
            } catch { }
        }
    }

    func testAuthenticationUsesConfiguredDatabaseAndRejectsBadPasswords() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_MONGODB_PORT"] ?? "") else {
            throw XCTSkip("Local MongoDB fixture is not configured.")
        }
        var profile = ConnectionProfile(name: "Auth fixture", engine: .mongodb, host: "127.0.0.1", port: port,
            username: "portsql_validation", password: "local_fixture_only", database: "portsql_codex_validation", usesTLS: false)
        profile.authenticationDatabase = "portsql_codex_validation"
        _ = try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: 5)
        profile.password = "incorrect_fixture_password"
        do {
            _ = try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: 5)
            XCTFail("Incorrect password must fail authentication")
        } catch { }
    }

    func testTimeoutAndCancellationCloseSocketsDuringHandshake() async throws {
        for cancel in [false, true] {
            let connected = expectation(description: "Connected")
            let disconnected = expectation(description: "Disconnected")
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(StalledMongoHandler(connected: connected, disconnected: disconnected))
                }.bind(host: "127.0.0.1", port: 0).get()
            let port = try XCTUnwrap(server.localAddress?.port)
            let profile = ConnectionProfile(name: "Stalled handshake", engine: .mongodb, host: "127.0.0.1", port: port,
                                            username: "", password: "", database: "test", usesTLS: false)
            let start = ContinuousClock.now
            let task = Task {
                try await DatabaseService.shared.execute(query: #"{"ping":1}"#, profile: profile, policy: .readOnly, timeoutSeconds: cancel ? 30 : 0)
            }
            await fulfillment(of: [connected], timeout: 3)
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("Stalled handshake must not succeed") }
            catch { }
            await fulfillment(of: [disconnected], timeout: 3)
            XCTAssertLessThan(start.duration(to: .now), .seconds(5))
            try await server.close().get()
            try await group.shutdownGracefully()
        }
    }

    func testLiveMongoCRUDPagingAggregationAndReadOnlyProtection() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_MONGODB_PORT"] ?? "") else {
            throw XCTSkip("Set PORTSQL_TEST_MONGODB_PORT to an isolated local MongoDB test server.")
        }
        let collection = "test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = ConnectionProfile(name: "Local validation", engine: .mongodb, host: "127.0.0.1", port: port,
                                        username: "", password: "", database: "portsql_codex_validation", usesTLS: false)
        let service = DatabaseService.shared
        func run(_ command: BSONDocument, _ policy: DatabaseExecutionPolicy = .readOnly) async throws -> QueryResultTable {
            try await service.execute(query: MongoQueryService.pretty(command), profile: profile, policy: policy, timeoutSeconds: 10)
        }
        do {
            let inserted = try await run(["insert": .string(collection), "documents": .array((0..<125).map { ["_id": BSON($0), "value": BSON($0), "empty": "", "nullable": .null] })], .userQuery(confirmed: true))
            XCTAssertEqual(inserted.affectedRowCount, 125)
            let databases = try await service.listDatabases(profile: profile)
            XCTAssertTrue(databases.contains("portsql_codex_validation"))
            let catalog = try await service.loadSchema(profile: profile, database: "portsql_codex_validation")
            XCTAssertTrue(catalog.contains { $0.name == collection })
            let all = try await run(["find": .string(collection), "sort": ["_id": 1]])
            XCTAssertEqual(all.rows.count, 125, "Must fetch beyond the first 100-document batch")
            let page = try await run(["find": .string(collection), "sort": ["_id": 1], "skip": 25, "limit": 25])
            XCTAssertEqual(page.rows.count, 25)
            XCTAssertEqual(try BSONDocument(fromJSON: XCTUnwrap(page.documents?.first))["_id"]?.toInt(), 25)
            let updated = try await run(["update": .string(collection), "updates": [["q": ["_id": 0], "u": ["$set": ["value": 999]], "multi": false]]], .userQuery(confirmed: true))
            XCTAssertEqual(updated.affectedRowCount, 1)
            let aggregation = try await run(["aggregate": .string(collection), "pipeline": [["$match": ["value": 999]]], "cursor": [:]])
            XCTAssertEqual(aggregation.rows.count, 1)
            let indexes = try await run(["listIndexes": .string(collection)])
            XCTAssertFalse(indexes.rows.isEmpty)
            let explain = try await run(["explain": ["find": .string(collection)], "verbosity": "queryPlanner"])
            XCTAssertNotNil(explain.documents?.first)
            do {
                _ = try await run(["delete": .string(collection), "deletes": [["q": [:], "limit": 0]]])
                XCTFail("Browse policy must block deletion")
            } catch { XCTAssertTrue(error is DatabaseServiceError) }
            let deleted = try await run(["delete": .string(collection), "deletes": [["q": ["_id": 0], "limit": 1]]], .userQuery(confirmed: true))
            XCTAssertEqual(deleted.affectedRowCount, 1)
            let after = try await run(["find": .string(collection)])
            XCTAssertEqual(after.rows.count, 124)
            let bulkDocuments = (125..<10_006).map { "{\"_id\":\($0)}" }.joined(separator: ",")
            _ = try await service.execute(query: "{\"insert\":\"\(collection)\",\"documents\":[\(bulkDocuments)]}",
                profile: profile, policy: .userQuery(confirmed: true), timeoutSeconds: 10)
            let capped = try await run(["find": .string(collection)])
            XCTAssertEqual(capped.rows.count, 10_000)
            XCTAssertEqual(capped.isTruncated, true)
            XCTAssertEqual(capped.documents?.count, 10_000)
            _ = try await run(["drop": .string(collection)], .userQuery(confirmed: true))
        } catch {
            _ = try? await run(["drop": .string(collection)], .userQuery(confirmed: true))
            throw error
        }
    }
}

private final class StalledMongoHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let connected: XCTestExpectation
    let disconnected: XCTestExpectation
    init(connected: XCTestExpectation, disconnected: XCTestExpectation) {
        self.connected = connected
        self.disconnected = disconnected
    }
    func channelActive(context: ChannelHandlerContext) { connected.fulfill() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { }
    func channelInactive(context: ChannelHandlerContext) { disconnected.fulfill() }
}
