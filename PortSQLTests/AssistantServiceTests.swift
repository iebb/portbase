import CryptoKit
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

    func testSettingsSyncEncryptedWithAllReferenceFiles() throws {
        let key = SymmetricKey(size: .bits256)
        var settings = AssistantSettings()
        settings.instructions = "Amounts are in cents."
        settings.documents = [AssistantContextDocument(name: "big.sql", text: String(repeating: "CREATE TABLE secret_orders (id int);\n", count: 20_000))]
        settings.updatedAt = Date(timeIntervalSince1970: 300)
        let payload = try AssistantSettingsSync.encryptedPayload(for: settings, key: key)
        XCTAssertGreaterThan(payload.count, 600 * 1_024, "Large reference files sync too, past key-value storage's limit")
        XCTAssertNil(String(data: payload, encoding: .utf8)?.range(of: "secret_orders"), "The file reveals nothing without the key")
        XCTAssertFalse(payload.range(of: Data("Amounts are in cents".utf8)) != nil)
        let decoded = try AssistantSettingsSync.settings(fromEncrypted: payload, key: key)
        XCTAssertEqual(decoded.documents.first?.text.count, settings.documents.first?.text.count)
        XCTAssertEqual(decoded.instructions, "Amounts are in cents.")
    }

    func testLegacyCopiesWithoutReferenceFilesKeepThisDevicesFiles() throws {
        var cloud = AssistantSettings()
        cloud.instructions = "Amounts are in cents."
        cloud.documentsOmitted = true
        cloud.updatedAt = Date(timeIntervalSince1970: 300)
        var other = AssistantSettings()
        other.documents = [AssistantContextDocument(name: "mine.sql", text: "CREATE TABLE t (id int);")]
        let merged = try XCTUnwrap(AssistantSettingsSync.merged(local: other, cloud: cloud))
        XCTAssertEqual(merged.documents.map(\.name), ["mine.sql"])
        XCTAssertEqual(merged.instructions, "Amounts are in cents.")
        XCTAssertFalse(merged.documentsOmitted)
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

final class DestructiveSQLTests: XCTestCase {
    func testTruncateDropAndDeleteAllAreDestructiveAndNameTheirTarget() throws {
        let truncate = try XCTUnwrap(SQLSafetyService.assessment(for: "truncate table Orders;", readOnly: false))
        XCTAssertTrue(truncate.isDestructive)
        XCTAssertEqual(truncate.target, "Orders", "The name keeps the user's spelling")
        XCTAssertEqual(truncate.actionTitle, "Truncate")

        let drop = try XCTUnwrap(SQLSafetyService.assessment(for: "DROP TABLE IF EXISTS public.\"Customers\"", readOnly: false))
        XCTAssertTrue(drop.isDestructive)
        XCTAssertEqual(drop.target, "public.Customers")

        let database = try XCTUnwrap(SQLSafetyService.assessment(for: "DROP DATABASE shop", readOnly: false, engine: .mysql))
        XCTAssertEqual(database.target, "shop")
        XCTAssertTrue(database.message.contains("DROP DATABASE"))

        let column = try XCTUnwrap(SQLSafetyService.assessment(for: "ALTER TABLE users DROP COLUMN legacy_flag", readOnly: false))
        XCTAssertTrue(column.isDestructive)
        XCTAssertEqual(column.target, "legacy_flag")

        let deleteAll = try XCTUnwrap(SQLSafetyService.assessment(for: "DELETE FROM sessions", readOnly: false))
        XCTAssertTrue(deleteAll.isDestructive)
        XCTAssertEqual(deleteAll.target, "sessions")

        let clickHouse = try XCTUnwrap(SQLSafetyService.assessment(for: "TRUNCATE TABLE events", readOnly: false, engine: .clickhouse))
        XCTAssertTrue(clickHouse.isDestructive)
    }

    func testOrdinaryWritesAndReadsAreNotTreatedAsDestructive() throws {
        let delete = try XCTUnwrap(SQLSafetyService.assessment(for: "DELETE FROM sessions WHERE expired = true", readOnly: false))
        XCTAssertFalse(delete.isDestructive)
        XCTAssertTrue(delete.requiresConfirmation)
        let dropConstraint = try XCTUnwrap(SQLSafetyService.assessment(for: "ALTER TABLE users DROP CONSTRAINT users_email_key", readOnly: false))
        XCTAssertFalse(dropConstraint.isDestructive)
        XCTAssertNil(SQLSafetyService.assessment(for: "SELECT 'DROP TABLE users'", readOnly: false), "Keywords inside literals don't count")
    }

    func testReadOnlyConnectionsStillBlockDestructiveStatements() throws {
        let blocked = try XCTUnwrap(SQLSafetyService.assessment(for: "DROP TABLE users", readOnly: true))
        XCTAssertTrue(blocked.blocksExecution)
        XCTAssertFalse(blocked.isDestructive)
    }
}

final class CloudEncryptionTests: XCTestCase {
    func testSealedDataOpensOnlyWithItsKeyAndUntouched() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try CloudEncryption.seal(Data("hello".utf8), key: key)
        XCTAssertEqual(sealed.prefix(4), Data("PBE1".utf8))
        XCTAssertEqual(try CloudEncryption.open(sealed, key: key), Data("hello".utf8))
        XCTAssertNotEqual(try CloudEncryption.seal(Data("hello".utf8), key: key), sealed, "Each seal uses a fresh nonce")

        XCTAssertThrowsError(try CloudEncryption.open(sealed, key: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? CloudEncryptionError, .wrongKeyOrDamaged)
        }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try CloudEncryption.open(tampered, key: key)) {
            XCTAssertEqual($0 as? CloudEncryptionError, .wrongKeyOrDamaged)
        }
        XCTAssertThrowsError(try CloudEncryption.open(Data("{\"plain\": true}".utf8), key: key)) {
            XCTAssertEqual($0 as? CloudEncryptionError, .unrecognizedFormat)
        }
    }

    func testTheKeyIsCreatedOnceAndReused() throws {
        defer { KeychainService.setSyncedAppSecret("", for: CloudEncryption.keyName) }
        KeychainService.setSyncedAppSecret("", for: CloudEncryption.keyName)
        XCTAssertNil(CloudEncryption.key(creatingIfMissing: false))
        let first = try XCTUnwrap(CloudEncryption.key())
        let again = try XCTUnwrap(CloudEncryption.key())
        let sealed = try CloudEncryption.seal(Data("x".utf8), key: first)
        XCTAssertEqual(try CloudEncryption.open(sealed, key: again), Data("x".utf8), "A second call returns the stored key")
    }
}

final class AssistantProviderTests: XCTestCase {
    func testSettingsFromBeforeProvidersMigrateToOneProviderWithTheExistingKey() throws {
        let legacy = #"{"provider":"openAICompatible","baseURL":"http://localhost:11434/v1","model":"llama3.1","instructions":"Be brief","includesSampleRows":false,"documents":[],"updatedAt":0,"documentsOmitted":false}"#
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.providers.count, 1)
        XCTAssertEqual(settings.activeProvider.id, AssistantProviderConfig.legacyID)
        XCTAssertEqual(settings.provider, .openAICompatible)
        XCTAssertEqual(settings.model, "llama3.1")
        XCTAssertEqual(settings.instructions, "Be brief")
        XCTAssertEqual(AssistantAPIKeyStore.account(for: AssistantProviderConfig.legacyID), "assistant.apiKey",
                       "The migrated provider keeps the key saved before providers had IDs")
        let other = UUID()
        XCTAssertEqual(AssistantAPIKeyStore.account(for: other), "assistant.apiKey." + other.uuidString)
    }

    func testProvidersRoundTripAndStillWriteTheActiveOneForEarlierVersions() throws {
        var settings = AssistantSettings()
        var ollama = AssistantProviderPreset.ollama.configuration
        ollama.model = "qwen2.5"
        settings.providers.append(ollama)
        settings.selectedProviderID = ollama.id
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: data)
        XCTAssertEqual(decoded.providers.map(\.name), ["Anthropic", "Ollama"])
        XCTAssertEqual(decoded.activeProvider.model, "qwen2.5")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "qwen2.5", "Earlier versions read the active provider's model")
        XCTAssertEqual(object["provider"] as? String, "openAICompatible")
    }

    func testDeviceOnlyKeysMoveToTheSyncedKeychainWhenRead() {
        let provider = UUID()
        let account = AssistantAPIKeyStore.account(for: provider)
        defer { AssistantAPIKeyStore.save("", for: provider); KeychainService.setAppSecret("", for: account) }
        KeychainService.setAppSecret("sk-old", for: account)
        XCTAssertEqual(AssistantAPIKeyStore.load(for: provider), "sk-old")
        XCTAssertEqual(KeychainService.syncedAppSecret(account), "sk-old", "The key now syncs through iCloud Keychain")
        XCTAssertEqual(KeychainService.appSecret(account), "", "The device-only copy is removed")
        AssistantAPIKeyStore.save("sk-new", for: provider)
        XCTAssertEqual(AssistantAPIKeyStore.load(for: provider), "sk-new")
    }

    func testEachChatCanPickItsOwnProviderAndModel() {
        var settings = AssistantSettings()
        var ollama = AssistantProviderPreset.ollama.configuration
        ollama.model = "llama3.1"
        settings.providers.append(ollama)
        let chat = settings.choosing(providerID: ollama.id, model: "qwen2.5")
        XCTAssertEqual(chat.activeProvider.id, ollama.id)
        XCTAssertEqual(chat.model, "qwen2.5")
        XCTAssertEqual(settings.activeProvider.id, AssistantProviderConfig.legacyID, "The default for new chats is unchanged")
        XCTAssertEqual(settings.providers[1].model, "llama3.1")
        XCTAssertEqual(settings.choosing(providerID: nil, model: nil), settings, "A chat without a choice uses the default")
        XCTAssertEqual(settings.choosing(providerID: UUID(), model: "gone").activeProvider.id, AssistantProviderConfig.legacyID,
                       "A removed provider falls back to the default")
    }

    func testModelsRequestsUseEachAPIsAuthentication() throws {
        let anthropic = try AssistantClient.modelsRequest(for: AssistantProviderPreset.anthropic.configuration, apiKey: "sk-ant")
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertThrowsError(try AssistantClient.modelsRequest(for: AssistantProviderPreset.anthropic.configuration, apiKey: ""))

        var router = AssistantProviderPreset.openRouter.configuration
        router.baseURL += "/"
        let openAI = try AssistantClient.modelsRequest(for: router, apiKey: "or-key")
        XCTAssertEqual(openAI.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(openAI.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
        let local = try AssistantClient.modelsRequest(for: AssistantProviderPreset.ollama.configuration, apiKey: "")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "Local servers need no key")
    }

    func testModelListsParseAndReportProviderErrors() throws {
        let anthropic = #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","type":"model"},{"id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"}],"has_more":false}"#
        let models = try AssistantClient.models(from: Data(anthropic.utf8), provider: .anthropic, statusCode: 200)
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-sonnet-5-5"], "Anthropic's newest-first order is kept")
        XCTAssertEqual(models.first?.title, "Claude Opus 5.5")

        let openAI = #"{"object":"list","data":[{"id":"gpt-z","object":"model"},{"id":"gpt-a","object":"model"}]}"#
        XCTAssertEqual(try AssistantClient.models(from: Data(openAI.utf8), provider: .openAICompatible, statusCode: 200).map(\.title), ["gpt-a", "gpt-z"])

        let failure = #"{"error":{"message":"Incorrect API key"}}"#
        XCTAssertThrowsError(try AssistantClient.models(from: Data(failure.utf8), provider: .openAICompatible, statusCode: 401)) {
            XCTAssertEqual($0 as? AssistantError, .provider("Incorrect API key"))
        }
    }
}
