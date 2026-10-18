import XCTest
@testable import PortSQL

final class AssistantServiceTests: XCTestCase {
    private let columns = [
        SchemaColumnDescriptor(name: "id", type: "bigint", isNullable: false, isPrimaryKey: true, isUnique: true),
        SchemaColumnDescriptor(name: "email", type: "text", isNullable: false, isPrimaryKey: false, isUnique: true),
        SchemaColumnDescriptor(name: "created_at", type: "timestamp", isNullable: true, isPrimaryKey: false, isUnique: false),
    ]

    private func context(sampleRows: [[String]] = []) -> AssistantContext {
        AssistantContext(
            engine: .postgresql,
            database: "storefront",
            tables: [SchemaTableDescriptor(schemaName: "public", name: "users", columns: columns, rowCountEstimate: 1200, objectKind: .table)],
            currentQuery: "SELECT 1",
            resultColumns: [QueryColumn(name: "email", type: "text")],
            sampleRows: sampleRows
        )
    }

    func testSchemaSummaryListsKeysTypesAndEstimates() {
        let summary = AssistantPromptBuilder.schemaSummary(tables: context().tables)
        XCTAssertTrue(summary.contains("table public.users (~1200 rows)"))
        XCTAssertTrue(summary.contains("  id bigint PRIMARY KEY NOT NULL"))
        XCTAssertTrue(summary.contains("  email text UNIQUE NOT NULL"))
        XCTAssertTrue(summary.contains("  created_at timestamp"))
        XCTAssertEqual(AssistantPromptBuilder.schemaSummary(tables: []), "(no tables loaded)")
    }

    func testSystemPromptCarriesDialectInstructionsFilesAndQuery() {
        var settings = AssistantSettings()
        settings.instructions = "Amounts are in cents."
        settings.documents = [AssistantContextDocument(name: "schema.sql", text: "CREATE TABLE users (...);")]
        let prompt = AssistantPromptBuilder.systemPrompt(context: context(), settings: settings)
        XCTAssertTrue(prompt.contains("PostgreSQL"))
        XCTAssertTrue(prompt.contains("```sql"))
        XCTAssertTrue(prompt.contains("```chart"))
        XCTAssertTrue(prompt.contains("Amounts are in cents."))
        XCTAssertTrue(prompt.contains("Reference file schema.sql"))
        XCTAssertTrue(prompt.contains("Query in the editor:\nSELECT 1"))
        XCTAssertTrue(prompt.contains("never runs your queries"))
    }

    func testSampleRowsAreOnlySentWhenAllowedAndAreTruncated() {
        let long = String(repeating: "x", count: 200)
        let withRows = context(sampleRows: [["a@example.com"], [long]])
        var settings = AssistantSettings()
        XCTAssertFalse(settings.includesSampleRows, "Sharing row data is opt-in")
        XCTAssertFalse(AssistantPromptBuilder.contextDescription(context: withRows, settings: settings).contains("a@example.com"))
        settings.includesSampleRows = true
        let description = AssistantPromptBuilder.contextDescription(context: withRows, settings: settings)
        XCTAssertTrue(description.contains("a@example.com"))
        XCTAssertFalse(description.contains(long), "Long values are cut short")
    }

    @MainActor
    func testWorkspaceContextNeverIncludesConnectionSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = ConnectionProfile(name: "prod", engine: .postgresql, host: "secret-host.example", port: 5432,
                                        username: "admin-user", password: "", defaultDatabase: "storefront")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([profile]).write(to: dir.appendingPathComponent("bookmarks.json"))
        let bookmarks = BookmarkStore(directory: dir, cloudSyncEnabled: false)
        let library = WorkspaceLibraryStore(directory: dir, cloudSyncEnabled: false)
        let workspace = WorkspaceViewModel()
        workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        workspace.selectedBookmarkID = profile.id
        workspace.schemaCatalog = context().tables
        workspace.result = QueryResultTable(columns: [QueryColumn(name: "email", type: "text")], rows: [QueryRow(cells: [.text("a@example.com")])],
                                            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil,
                                            sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: false)

        let withoutRows = try XCTUnwrap(workspace.assistantContext(includingSampleRows: false))
        XCTAssertTrue(withoutRows.sampleRows.isEmpty)
        var settings = AssistantSettings()
        settings.includesSampleRows = true
        let prompt = AssistantPromptBuilder.systemPrompt(context: try XCTUnwrap(workspace.assistantContext(includingSampleRows: true)), settings: settings)
        XCTAssertTrue(prompt.contains("a@example.com"))
        XCTAssertFalse(prompt.contains("secret-host.example"))
        XCTAssertFalse(prompt.contains("admin-user"))
        withExtendedLifetime((bookmarks, library)) {}
    }

    func testAnthropicRequestUsesMessagesAPIAndKeyHeader() throws {
        var settings = AssistantSettings()
        settings.baseURL = "https://api.anthropic.com/v1/"
        let request = try AssistantClient.request(settings: settings, apiKey: "sk-test", system: "SYSTEM",
                                                  messages: [AssistantMessage(role: .user, text: "hi")])
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["system"] as? String, "SYSTEM")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "hi")
    }

    func testOpenAICompatibleRequestPutsSystemFirstAndKeyIsOptional() throws {
        var settings = AssistantSettings()
        settings.provider = .openAICompatible
        settings.baseURL = "http://localhost:11434/v1"
        settings.model = "llama3.1"
        let request = try AssistantClient.request(settings: settings, apiKey: "", system: "SYSTEM",
                                                  messages: [AssistantMessage(role: .user, text: "hi")])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        let keyed = try AssistantClient.request(settings: settings, apiKey: "key", system: "", messages: [])
        XCTAssertEqual(keyed.value(forHTTPHeaderField: "Authorization"), "Bearer key")
    }

    func testAnthropicNeedsAKeyAndEveryProviderNeedsAModel() {
        XCTAssertThrowsError(try AssistantClient.request(settings: AssistantSettings(), apiKey: "", system: "", messages: [])) {
            XCTAssertEqual($0 as? AssistantError, .notConfigured)
        }
        var settings = AssistantSettings()
        settings.provider = .openAICompatible
        settings.model = ""
        XCTAssertFalse(settings.isConfigured(apiKey: "key"))
    }

    func testRepliesAndProviderErrorsAreRead() throws {
        let anthropic = #"{"content":[{"type":"text","text":"Hello"},{"type":"text","text":"World"}]}"#
        XCTAssertEqual(try AssistantClient.replyText(from: Data(anthropic.utf8), provider: .anthropic, statusCode: 200), "Hello\nWorld")
        let openAI = #"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#
        XCTAssertEqual(try AssistantClient.replyText(from: Data(openAI.utf8), provider: .openAICompatible, statusCode: 200), "Hi")
        let failure = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertThrowsError(try AssistantClient.replyText(from: Data(failure.utf8), provider: .anthropic, statusCode: 401)) {
            XCTAssertEqual($0 as? AssistantError, .provider("invalid x-api-key"))
        }
        XCTAssertThrowsError(try AssistantClient.replyText(from: Data("{}".utf8), provider: .openAICompatible, statusCode: 200)) {
            XCTAssertEqual($0 as? AssistantError, .invalidResponse)
        }
    }

    func testReplyParserSeparatesProseQueriesAndCharts() {
        let reply = """
        Here is the query:
        ```sql
        SELECT region, count(*) AS orders
        FROM orders GROUP BY region;
        ```
        And a chart:
        ```chart
        {"title": "Orders by region", "type": "line", "x": "region", "y": ["orders"], "query": "SELECT region, count(*) AS orders FROM orders GROUP BY region"}
        ```
        ```chart
        not json
        ```
        ```sql
        SELECT 1
        """
        let segments = AssistantReplyParser.segments(reply)
        XCTAssertEqual(segments.count, 6)
        XCTAssertEqual(segments[0], .text("Here is the query:"))
        XCTAssertEqual(segments[1], .code(language: "sql", code: "SELECT region, count(*) AS orders\nFROM orders GROUP BY region;"))
        XCTAssertEqual(segments[2], .text("And a chart:"))
        guard case .chart(let chart) = segments[3] else { return XCTFail("Expected a chart") }
        XCTAssertEqual(chart.chartType, .line)
        XCTAssertEqual(chart.x, "region")
        XCTAssertEqual(chart.y, ["orders"])
        XCTAssertEqual(segments[4], .code(language: "chart", code: "not json"), "Invalid chart JSON stays visible as code")
        XCTAssertEqual(segments[5], .code(language: "sql", code: "SELECT 1"), "An unterminated block keeps its content")
    }

    @MainActor
    func testChartSuggestionBecomesAnEditorPresetOnceItsQueryHasRun() {
        let workspace = WorkspaceViewModel()
        workspace.result = QueryResultTable(columns: [QueryColumn(name: "region", type: "text"), QueryColumn(name: "orders", type: "integer")],
                                            rows: [QueryRow(cells: [.text("Japan"), .integer("4")]), QueryRow(cells: [.text("Brazil"), .integer("7")])],
                                            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil,
                                            sourceQuery: nil, affectedRowCount: nil, isTruncated: false, isExplorerGenerated: false)
        workspace.pendingAssistantChart = AssistantChartSuggestion(title: "Orders by region", type: "point", x: "region", y: ["orders", "missing"], query: "")
        let preset = workspace.consumeAssistantChart()
        XCTAssertNil(workspace.pendingAssistantChart)
        XCTAssertEqual(preset?.chartType, .point)
        XCTAssertEqual(preset?.xField, "region")
        XCTAssertEqual(preset?.resolvedYFields, ["orders"], "Columns the result doesn't have are dropped")
        XCTAssertEqual(preset?.title, "Orders by region")
        XCTAssertNil(workspace.consumeAssistantChart())
    }

    @MainActor
    func testAssistantQueriesAreInsertedOrReplacedWithoutRunning() {
        let workspace = WorkspaceViewModel()
        workspace.queryText = "SELECT 1;"
        workspace.queryCursorOffset = 9
        workspace.applyAssistantQuery("SELECT 2;", replacing: false)
        XCTAssertTrue(workspace.queryText.hasPrefix("SELECT 1;"))
        XCTAssertTrue(workspace.queryText.contains("\nSELECT 2;"), "The new query goes on its own line after the existing one")
        workspace.applyAssistantQuery("SELECT 3;", replacing: true)
        XCTAssertEqual(workspace.queryText, "SELECT 3;")
        XCTAssertFalse(workspace.isRunning)
    }
}

final class AssistantSettingsSyncTests: XCTestCase {
    func testNewerCloudCopyWinsAndOlderOneIsIgnored() throws {
        var local = AssistantSettings()
        local.model = "local-model"
        local.updatedAt = Date(timeIntervalSince1970: 100)
        var cloud = local
        cloud.model = "cloud-model"
        cloud.updatedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(AssistantSettingsSync.merged(local: local, cloud: cloud)?.model, "cloud-model")
        XCTAssertNil(AssistantSettingsSync.merged(local: cloud, cloud: local), "An older iCloud copy doesn't replace newer local settings")
    }

    func testLargeReferenceFilesStayOnTheDeviceThatAddedThem() throws {
        var settings = AssistantSettings()
        settings.instructions = "Amounts are in cents."
        settings.documents = [AssistantContextDocument(name: "big.sql", text: String(repeating: "x", count: 300 * 1_024))]
        settings.updatedAt = Date(timeIntervalSince1970: 300)
        let payload = try XCTUnwrap(AssistantSettingsSync.cloudPayload(for: settings))
        XCTAssertLessThan(payload.count, AssistantSettingsSync.documentBudget)
        let cloud = try JSONDecoder().decode(AssistantSettings.self, from: payload)
        XCTAssertTrue(cloud.documents.isEmpty)
        XCTAssertTrue(cloud.documentsOmitted)
        XCTAssertEqual(cloud.instructions, "Amounts are in cents.")

        var other = AssistantSettings()
        other.documents = [AssistantContextDocument(name: "mine.sql", text: "CREATE TABLE t (id int);")]
        let merged = try XCTUnwrap(AssistantSettingsSync.merged(local: other, cloud: cloud))
        XCTAssertEqual(merged.documents.map(\.name), ["mine.sql"], "A device keeps its own files when the iCloud copy left them out")
        XCTAssertEqual(merged.instructions, "Amounts are in cents.")
        XCTAssertFalse(merged.documentsOmitted)

        settings.documents = [AssistantContextDocument(name: "small.sql", text: "CREATE TABLE t (id int);")]
        let small = try JSONDecoder().decode(AssistantSettings.self, from: try XCTUnwrap(AssistantSettingsSync.cloudPayload(for: settings)))
        XCTAssertEqual(small.documents.map(\.name), ["small.sql"], "Small files sync with the settings")
    }

    func testSettingsAreSavedWithoutTheAPIKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-\(UUID().uuidString)"))
        var settings = AssistantSettings()
        settings.model = "m"
        settings.save(to: defaults, syncing: false)
        let raw = try XCTUnwrap(defaults.data(forKey: AssistantSettings.storageKey))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).localizedCaseInsensitiveContains("apikey"))
        XCTAssertEqual(AssistantSettings.load(from: defaults).model, "m")
        XCTAssertGreaterThan(AssistantSettings.load(from: defaults).updatedAt, .distantPast)
    }
}
