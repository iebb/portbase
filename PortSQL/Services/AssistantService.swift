import CryptoKit
import Foundation

// MARK: - Configuration

/// The kind of API an assistant endpoint speaks.
enum AssistantProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    /// OpenAI's chat completions API, also served by OpenRouter, Ollama, LM Studio, and others.
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAICompatible: L10n.text("OpenAI-compatible")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openAICompatible: ""
        }
    }
}

/// A text file the user attached as standing context, such as DDL, ORM models, or notes.
struct AssistantContextDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

/// A model a provider offers, as its models endpoint lists it.
struct AssistantModelInfo: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String?
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? id }
}

/// One configured AI provider: what API it speaks, where, and which model to use. Its API key is in
/// the Keychain under the provider's ID, never here.
struct AssistantProviderConfig: Codable, Identifiable, Equatable {
    /// The provider settings from before providers could be added migrate to this ID, which keeps
    /// using the API key already saved for them.
    static let legacyID = UUID(uuidString: "1F0A6E52-7C1B-4B8E-9C2D-5A7E3F9B1C01")!

    var id = UUID()
    var name: String
    var kind: AssistantProvider
    var baseURL: String
    var model: String
    /// The models the provider listed when last asked, newest list wins.
    var models: [AssistantModelInfo] = []

    init(id: UUID = UUID(), name: String, kind: AssistantProvider, baseURL: String, model: String, models: [AssistantModelInfo] = []) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.model = model; self.models = models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? container.decode(AssistantProvider.self, forKey: .kind)) ?? .openAICompatible
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? kind.title
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? kind.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        models = (try? container.decodeIfPresent([AssistantModelInfo].self, forKey: .models)).flatMap { $0 } ?? []
    }

    static var defaultAnthropic: AssistantProviderConfig {
        AssistantProviderConfig(id: legacyID, name: "Anthropic", kind: .anthropic,
                                baseURL: AssistantProvider.anthropic.defaultBaseURL, model: AssistantProvider.anthropic.defaultModel)
    }

    /// Whether requests can be sent; a local OpenAI-compatible server may not need a key.
    func isConfigured(apiKey: String) -> Bool {
        guard URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return kind == .openAICompatible || !apiKey.isEmpty
    }
}

/// Ready-made provider settings for adding a provider.
enum AssistantProviderPreset: String, CaseIterable, Identifiable {
    case anthropic, openAI, openRouter, ollama, lmStudio, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: L10n.text("Other OpenAI-compatible")
        }
    }

    var configuration: AssistantProviderConfig {
        switch self {
        case .anthropic: AssistantProviderConfig(name: title, kind: .anthropic, baseURL: AssistantProvider.anthropic.defaultBaseURL,
                                                 model: AssistantProvider.anthropic.defaultModel)
        case .openAI: AssistantProviderConfig(name: title, kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "")
        case .openRouter: AssistantProviderConfig(name: title, kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "")
        case .ollama: AssistantProviderConfig(name: title, kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "")
        case .lmStudio: AssistantProviderConfig(name: title, kind: .openAICompatible, baseURL: "http://localhost:1234/v1", model: "")
        case .custom: AssistantProviderConfig(name: title, kind: .openAICompatible, baseURL: "", model: "")
        }
    }
}

/// When the assistant may run the queries it writes. Changes to data or schema always ask, whatever
/// the mode, and destructive ones ask with the stronger confirmation.
enum AssistantApprovalMode: String, Codable, CaseIterable, Identifiable {
    /// The assistant writes queries; the user runs them from the console.
    case suggestOnly
    /// Every query waits for the user's approval.
    case askEveryQuery
    /// Read-only queries run on their own, in a read-only session; anything else asks.
    case autoReadOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggestOnly: L10n.text("Suggest Only")
        case .askEveryQuery: L10n.text("Ask Every Time")
        case .autoReadOnly: L10n.text("Run Read-Only")
        }
    }

    var summary: String {
        switch self {
        case .suggestOnly: L10n.text("Writes queries for you to run; never runs them.")
        case .askEveryQuery: L10n.text("Asks before running each query.")
        case .autoReadOnly: L10n.text("Runs read-only queries; asks before anything that changes data.")
        }
    }

    var runsQueries: Bool { self != .suggestOnly }
}

/// Assistant settings. Stored in user defaults; API keys live in the Keychain, never here.
struct AssistantSettings: Codable, Equatable {
    static let storageKey = "Portbase.assistant.settings"
    /// Per attached document, so a stray large file can't flood every request.
    static let maximumDocumentBytes = 200 * 1_024
    static let maximumDocuments = 8

    var providers: [AssistantProviderConfig] = [.defaultAnthropic]
    var selectedProviderID: UUID?
    /// Standing instructions, such as naming conventions or which tables matter.
    var instructions: String = ""
    /// Off by default: sample rows send real data to the provider.
    var includesSampleRows = false
    /// Asking before every query is the default; results of queries the assistant runs go to the provider.
    var approvalMode: AssistantApprovalMode = .askEveryQuery
    var documents: [AssistantContextDocument] = []
    /// When these settings last changed on any device; the newest copy wins when syncing.
    var updatedAt: Date = .distantPast
    /// Set on the iCloud copy when the reference files were too large to sync with it.
    var documentsOmitted = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case providers, selectedProviderID, instructions, includesSampleRows, approvalMode, documents, updatedAt, documentsOmitted
        // The single provider of earlier versions, still written for them.
        case provider, baseURL, model
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let providers = try container.decodeIfPresent([AssistantProviderConfig].self, forKey: .providers), !providers.isEmpty {
            self.providers = providers
        } else {
            let kind = (try? container.decodeIfPresent(AssistantProvider.self, forKey: .provider)).flatMap { $0 } ?? .anthropic
            providers = [AssistantProviderConfig(
                id: AssistantProviderConfig.legacyID, name: kind.title, kind: kind,
                baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL) ?? kind.defaultBaseURL,
                model: try container.decodeIfPresent(String.self, forKey: .model) ?? kind.defaultModel)]
        }
        selectedProviderID = try container.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        includesSampleRows = try container.decodeIfPresent(Bool.self, forKey: .includesSampleRows) ?? false
        approvalMode = (try? container.decodeIfPresent(AssistantApprovalMode.self, forKey: .approvalMode)).flatMap { $0 } ?? .askEveryQuery
        documents = try container.decodeIfPresent([AssistantContextDocument].self, forKey: .documents) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        documentsOmitted = try container.decodeIfPresent(Bool.self, forKey: .documentsOmitted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(selectedProviderID, forKey: .selectedProviderID)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(includesSampleRows, forKey: .includesSampleRows)
        try container.encode(approvalMode, forKey: .approvalMode)
        try container.encode(documents, forKey: .documents)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(documentsOmitted, forKey: .documentsOmitted)
        try container.encode(provider, forKey: .provider)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
    }

    private var activeIndex: Int { providers.firstIndex { $0.id == selectedProviderID } ?? 0 }

    /// The provider requests go to: the selected one, or the first.
    var activeProvider: AssistantProviderConfig {
        get { providers.isEmpty ? .defaultAnthropic : providers[activeIndex] }
        set {
            if providers.isEmpty { providers = [newValue] } else { providers[activeIndex] = newValue }
        }
    }

    var provider: AssistantProvider {
        get { activeProvider.kind }
        set { activeProvider.kind = newValue }
    }

    var baseURL: String {
        get { activeProvider.baseURL }
        set { activeProvider.baseURL = newValue }
    }

    var model: String {
        get { activeProvider.model }
        set { activeProvider.model = newValue }
    }

    static func load(from defaults: UserDefaults = .standard) -> AssistantSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data) else { return AssistantSettings() }
        return settings
    }

    /// Saves locally and, outside tests, pushes the settings to iCloud for the user's other devices.
    func save(to defaults: UserDefaults = .standard, syncing: Bool = !WorkspaceFileStore.isTestHost) {
        var stamped = self
        stamped.updatedAt = .now
        stamped.documentsOmitted = false
        if let data = try? JSONEncoder().encode(stamped) { defaults.set(data, forKey: Self.storageKey) }
        if syncing { AssistantSettingsSync.push(stamped) }
    }

    /// These settings with one chat's choice of provider and model, which may differ from the default
    /// for new chats. A provider that has since been removed falls back to the default.
    func choosing(providerID: UUID?, model: String?) -> AssistantSettings {
        var chosen = self
        if let providerID, providers.contains(where: { $0.id == providerID }) {
            chosen.selectedProviderID = providerID
            if let model, !model.isEmpty { chosen.activeProvider.model = model }
        }
        return chosen
    }

    /// Whether requests can be sent with the active provider.
    func isConfigured(apiKey: String) -> Bool { activeProvider.isConfigured(apiKey: apiKey) }
}

extension Notification.Name {
    /// Posted on the main thread after newer assistant settings arrived from another device.
    static let assistantSettingsDidChange = Notification.Name("Portbase.assistantSettingsDidChange")
}

/// Syncs assistant settings as an encrypted file in the app's iCloud Drive folder, with the key in
/// iCloud Keychain (see `CloudEncryption`), so reading the iCloud Drive folder reveals nothing and the
/// settings, reference files included, aren't held to key-value storage's small limit. A tiny revision
/// value in key-value storage tells other devices when to read the file. API keys are never part of it.
enum AssistantSettingsSync {
    /// The plaintext copy earlier versions kept in key-value storage; read once to migrate, then removed.
    static let legacyCloudKey = "portbase.assistant.settings.v1"
    static let revisionKey = "portbase.assistant.settings.revision"
    static let fileName = "assistant-settings.pbenc"

    static func encryptedPayload(for settings: AssistantSettings, key: SymmetricKey) throws -> Data {
        try CloudEncryption.seal(JSONEncoder().encode(settings), key: key)
    }

    static func settings(fromEncrypted data: Data, key: SymmetricKey) throws -> AssistantSettings {
        try JSONDecoder().decode(AssistantSettings.self, from: CloudEncryption.open(data, key: key))
    }

    /// The local settings after taking in an iCloud copy, or nil when the local copy is as new.
    /// When a legacy iCloud copy left out the reference files, this device keeps its own.
    static func merged(local: AssistantSettings, cloud: AssistantSettings) -> AssistantSettings? {
        guard cloud.updatedAt > local.updatedAt else { return nil }
        var merged = cloud
        if cloud.documentsOmitted { merged.documents = local.documents }
        merged.documentsOmitted = false
        return merged
    }

    private static let queue = DispatchQueue(label: "Portbase.AssistantSettingsSync", qos: .utility)
    /// Looked up once, on `queue`: finding the iCloud Drive folder can take a moment.
    nonisolated(unsafe) private static var folderLookup: URL??

    private static func folder() -> URL? {
        if let folderLookup { return folderLookup }
        let url = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("PortSQL", isDirectory: true)
        if let url { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        folderLookup = .some(url)
        return url
    }

    static func push(_ settings: AssistantSettings) {
        queue.async {
            guard let folder = folder(), let key = CloudEncryption.key(),
                  let payload = try? encryptedPayload(for: settings, key: key) else { return }
            let url = folder.appendingPathComponent(fileName)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                try? payload.write(to: target, options: .atomic)
            }
            let store = NSUbiquitousKeyValueStore.default
            store.set(settings.updatedAt.timeIntervalSince1970, forKey: revisionKey)
            // The plaintext copy earlier versions kept isn't written anymore, and is removed.
            store.removeObject(forKey: legacyCloudKey)
            store.synchronize()
        }
    }

    /// Reads the iCloud copy in the background and adopts it when it's newer, posting
    /// `assistantSettingsDidChange` so open screens reload.
    static func pull() {
        guard !WorkspaceFileStore.isTestHost else { return }
        queue.async {
            guard let cloud = encryptedCopy() ?? legacyCopy() else { return }
            DispatchQueue.main.async {
                guard let merged = merged(local: .load(), cloud: cloud),
                      let encoded = try? JSONEncoder().encode(merged) else { return }
                UserDefaults.standard.set(encoded, forKey: AssistantSettings.storageKey)
                NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
            }
        }
    }

    private static func encryptedCopy() -> AssistantSettings? {
        guard let folder = folder() else { return nil }
        let url = folder.appendingPathComponent(fileName)
        // A file another device wrote may not be on this device yet: ask for it and read it next time,
        // rather than wait on the download.
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        if let status, status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            data = try? Data(contentsOf: source)
        }
        // Without the key yet (iCloud Keychain still syncing it), the file is read on a later pull.
        guard let data, let key = CloudEncryption.key(creatingIfMissing: false) else { return nil }
        return try? settings(fromEncrypted: data, key: key)
    }

    private static func legacyCopy() -> AssistantSettings? {
        NSUbiquitousKeyValueStore.default.data(forKey: legacyCloudKey).flatMap { try? JSONDecoder().decode(AssistantSettings.self, from: $0) }
    }
}

/// Each provider's API key, kept in iCloud Keychain so it reaches the user's other devices end-to-end
/// encrypted, the way the provider settings sync through iCloud. Keys saved on this device only by
/// earlier versions move to iCloud Keychain the first time they're read.
enum AssistantAPIKeyStore {
    static func account(for providerID: UUID) -> String {
        // The provider migrated from earlier versions keeps the key saved before providers had IDs.
        providerID == AssistantProviderConfig.legacyID ? "assistant.apiKey" : "assistant.apiKey." + providerID.uuidString
    }

    static func load(for providerID: UUID = AssistantProviderConfig.legacyID) -> String {
        let account = account(for: providerID)
        let synced = KeychainService.syncedAppSecret(account)
        if !synced.isEmpty { return synced }
        let local = KeychainService.appSecret(account)
        if !local.isEmpty, KeychainService.setSyncedAppSecret(local, for: account) {
            KeychainService.setAppSecret("", for: account)
        }
        return local
    }

    static func save(_ key: String, for providerID: UUID = AssistantProviderConfig.legacyID) {
        let account = account(for: providerID)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if KeychainService.setSyncedAppSecret(trimmed, for: account) {
            KeychainService.setAppSecret("", for: account)
        } else {
            // iCloud Keychain unavailable: keep the key on this device rather than lose it.
            KeychainService.setAppSecret(trimmed, for: account)
        }
    }
}

// MARK: - Context

/// What the assistant is told about the workspace. Connection hosts, users, and secrets are never part of it.
struct AssistantContext: Equatable {
    var engine: DatabaseEngine
    var database: String?
    var tables: [SchemaTableDescriptor]
    var foreignKeys: [SchemaForeignKey] = []
    var currentQuery: String = ""
    var resultColumns: [QueryColumn] = []
    /// Only filled when the user allows sample rows.
    var sampleRows: [[String]] = []
    /// The connection only allows reading; the assistant shouldn't attempt changes.
    var isReadOnly = false
    /// The connection's environment label, such as Production, when it has one.
    var environment: String?
}

enum AssistantPromptBuilder {
    static let maximumTables = 300
    static let maximumSampleRows = 5
    static let maximumSampleValueLength = 80

    /// The standing instructions sent as the system prompt on every request: a database expert for the
    /// connection's engine, told whether it can run queries and how changes are confirmed.
    static func systemPrompt(context: AssistantContext, settings: AssistantSettings, toolsEnabled: Bool = false) -> String {
        let dialect = dialect(context.engine)
        var parts = [
            """
            You are Portbase's database expert: a senior \(dialect) engineer and data analyst, working inside Portbase, \
            a database client, on the user's database described below.

            How you work:
            - Ground every answer in the schema below. Use exact table and column names and quote identifiers the way \(dialect) \
            requires. If something the user asks about isn't in the schema, say so instead of guessing.
            - Write correct, efficient \(dialect): list the columns you need, keep WHERE clauses index-friendly, LIMIT exploratory \
            queries, and point out when a query would scan a large table or would benefit from an index.
            - Be explicit about assumptions such as time zones, NULL handling, duplicates, and units.
            - Keep explanations short and concrete. Lead with the answer, then the query.
            - When a chart would answer the question, add one fenced block tagged ```chart containing JSON: \
            {"title": "...", "type": "bar" | "line" | "area" | "point" | "pie", "x": "<result column>", \
            "y": ["<numeric result column>", ...], "query": "<the SQL that produces those columns>"}.
            """
        ]
        if toolsEnabled {
            parts.append("""
            Running queries:
            - You can run queries with the run_query tool, one statement per call. Use it to check real data when that makes the \
            answer more accurate: distinct values, counts, date ranges, a few sample rows. Keep these queries small, read-only, \
            and LIMITed.
            - Results come back truncated to the first rows. Say when an answer depends on rows you didn't see.
            - The user approves queries according to their approval mode. If a query is declined or blocked, don't try to work \
            around it; explain what you'd need instead.
            - Changes to data or schema (INSERT, UPDATE, DELETE, DDL) always need the user's confirmation, and destructive ones \
            (DROP, TRUNCATE, DELETE without WHERE) need a second, stronger one. Only run a change when the user asked for it. \
            First show what it affects, for example with a SELECT of the rows involved, and state exactly what will change.
            - After running queries, answer the question in prose. Put the final query you recommend in a fenced ```sql block so \
            the user can open it in the console.
            """)
        } else {
            parts.append("""
            Queries:
            - Put each query in its own fenced block tagged ```sql, written for \(dialect).
            - Portbase never runs your queries itself in this mode; the user reviews and runs them.
            - Prefer read-only queries. When the user asks for a change, write it, but say plainly that it modifies data, and \
            for destructive statements say what is lost.
            """)
        }
        if context.isReadOnly {
            parts.append("This connection is read-only. Don't attempt changes; if the user asks for one, write the statement for them to run elsewhere.")
        }
        if let environment = context.environment {
            parts.append("This connection is labeled \(environment). Be conservative" + (environment.lowercased().contains("prod") ? ", since it is production data." : "."))
        }
        let instructions = settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            parts.append("Instructions from the user:\n" + instructions)
        }
        parts.append(contextDescription(context: context, settings: settings))
        return parts.joined(separator: "\n\n")
    }

    /// The workspace description included in the system prompt; also shown to the user as "What's sent".
    static func contextDescription(context: AssistantContext, settings: AssistantSettings) -> String {
        var parts = ["Database engine: \(context.engine.rawValue)"]
        if let database = context.database, !database.isEmpty { parts.append("Current database: \(database)") }
        parts.append("Schema:\n" + schemaSummary(tables: context.tables, foreignKeys: context.foreignKeys))
        for document in settings.documents where !document.text.isEmpty {
            parts.append("Reference file \(document.name):\n" + document.text)
        }
        let query = context.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append("Query in the editor:\n" + query) }
        if !context.resultColumns.isEmpty {
            parts.append("Columns of the last result: " + context.resultColumns.map { "\($0.name) (\($0.type))" }.joined(separator: ", "))
        }
        if settings.includesSampleRows, !context.sampleRows.isEmpty, !context.resultColumns.isEmpty {
            let rows = context.sampleRows.prefix(maximumSampleRows).map { row in
                row.map { value in value.count > maximumSampleValueLength ? String(value.prefix(maximumSampleValueLength)) + "…" : value }
                    .joined(separator: " | ")
            }
            parts.append("Sample rows from the last result:\n" + context.resultColumns.map(\.name).joined(separator: " | ") + "\n" + rows.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// One line per table and one per column, compact enough for large schemas.
    static func schemaSummary(tables: [SchemaTableDescriptor], foreignKeys: [SchemaForeignKey] = []) -> String {
        guard !tables.isEmpty else { return "(no tables loaded)" }
        var lines: [String] = []
        for table in tables.prefix(maximumTables) {
            var header = "\(table.objectKind == .view ? "view" : "table") \(table.displayName)"
            if let estimate = table.rowCountEstimate { header += " (~\(estimate) rows)" }
            lines.append(header)
            for column in table.columns {
                var line = "  \(column.name) \(column.type)"
                if column.isPrimaryKey { line += " PRIMARY KEY" } else if column.isUnique { line += " UNIQUE" }
                if !column.isNullable { line += " NOT NULL" }
                lines.append(line)
            }
        }
        if tables.count > maximumTables { lines.append("… \(tables.count - maximumTables) more tables not listed") }
        for key in foreignKeys { lines.append("foreign key " + key.summary) }
        return lines.joined(separator: "\n")
    }

    private static func dialect(_ engine: DatabaseEngine) -> String {
        switch engine {
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .sqlite: "SQLite"
        case .clickhouse: "ClickHouse SQL"
        case .mongodb: "MongoDB shell"
        case .redis: "Redis command"
        case .elasticsearch: "Elasticsearch request"
        }
    }
}

// MARK: - Requests

/// A tool call the model asked for, such as running a query.
struct AssistantToolCall: Codable, Equatable {
    var id: String
    var name: String
    var arguments: [String: String]
}

/// What a tool call produced, sent back to the model.
struct AssistantToolResult: Codable, Equatable {
    var callID: String
    var content: String
    var isError = false
}

struct AssistantMessage: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
    /// An assistant turn's tool calls.
    var toolCalls: [AssistantToolCall] = []
    /// A user turn carrying the results of the previous turn's tool calls.
    var toolResults: [AssistantToolResult] = []
}

/// A model's reply: its text and any tools it wants to use.
struct AssistantReply: Equatable {
    var text: String
    var toolCalls: [AssistantToolCall]
}

/// The tools Portbase offers the model.
enum AssistantTools {
    static let runQuery = "run_query"
    static let runQueryDescription = "Runs one query on the user's current database connection and returns the result's columns and first rows. The user approves queries according to their settings; changes to data always need their confirmation."

    static var runQueryParameters: [String: Any] { [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "One statement in the connection's query language."],
            "purpose": ["type": "string", "description": "A short note for the user on why this query helps."],
        ],
        "required": ["query"],
    ] }
}

enum AssistantError: LocalizedError, Equatable {
    case notConfigured
    case invalidResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L10n.text("Set up an AI provider in Settings first.")
        case .invalidResponse: L10n.text("The AI provider returned a response Portbase couldn't read.")
        case .provider(let message): message
        }
    }
}

enum AssistantClient {
    static let maximumOutputTokens = 4_096

    /// Builds the HTTP request for the configured provider, offering the run_query tool when `tools` is set.
    static func request(settings: AssistantSettings, apiKey: String, system: String, messages: [AssistantMessage], tools: Bool = false) throws -> URLRequest {
        guard settings.isConfigured(apiKey: apiKey) else { throw AssistantError.notConfigured }
        var base = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path = settings.provider == .anthropic ? "/messages" : "/chat/completions"
        guard let url = URL(string: base + path) else { throw AssistantError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        switch settings.provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var anthropic: [String: Any] = [
                "model": model,
                "max_tokens": maximumOutputTokens,
                "system": system,
                "messages": messages.map(anthropicMessage),
            ]
            if tools {
                anthropic["tools"] = [["name": AssistantTools.runQuery, "description": AssistantTools.runQueryDescription,
                                       "input_schema": AssistantTools.runQueryParameters]]
            }
            body = anthropic
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
            var openAI: [String: Any] = [
                "model": model,
                "messages": [["role": "system", "content": system]] + messages.flatMap(openAIMessages),
            ]
            if tools {
                openAI["tools"] = [["type": "function", "function": ["name": AssistantTools.runQuery, "description": AssistantTools.runQueryDescription,
                                                                    "parameters": AssistantTools.runQueryParameters]]]
            }
            body = openAI
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A message in Anthropic's format: tool calls as tool_use blocks, their results as tool_result blocks.
    private static func anthropicMessage(_ message: AssistantMessage) -> [String: Any] {
        guard !message.toolCalls.isEmpty || !message.toolResults.isEmpty else {
            return ["role": message.role.rawValue, "content": message.text]
        }
        var blocks: [[String: Any]] = message.toolResults.map {
            ["type": "tool_result", "tool_use_id": $0.callID, "content": $0.content, "is_error": $0.isError]
        }
        if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
        blocks += message.toolCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.arguments] }
        return ["role": message.role.rawValue, "content": blocks]
    }

    /// Messages in OpenAI's format: tool calls on the assistant message, each result as a "tool" message.
    private static func openAIMessages(_ message: AssistantMessage) -> [[String: Any]] {
        var messages: [[String: Any]] = message.toolResults.map { ["role": "tool", "tool_call_id": $0.callID, "content": $0.content] }
        if !message.toolCalls.isEmpty {
            messages.append([
                "role": "assistant",
                "content": message.text.isEmpty ? NSNull() : message.text as Any,
                "tool_calls": message.toolCalls.map { call in
                    let arguments = (try? JSONSerialization.data(withJSONObject: call.arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments]] as [String: Any]
                },
            ])
        } else if !message.text.isEmpty || message.toolResults.isEmpty {
            messages.append(["role": message.role.rawValue, "content": message.text])
        }
        return messages
    }

    /// Reads a reply's text and tool calls, or the provider's error message.
    static func reply(from data: Data, provider: AssistantProvider, statusCode: Int) throws -> AssistantReply {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200..<300).contains(statusCode) {
            let message = (object?["error"] as? [String: Any])?["message"] as? String
                ?? object?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw AssistantError.provider(message)
        }
        guard let object else { throw AssistantError.invalidResponse }
        var text = ""
        var calls: [AssistantToolCall] = []
        switch provider {
        case .anthropic:
            for block in object["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text": text += (text.isEmpty ? "" : "\n") + (block["text"] as? String ?? "")
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    calls.append(AssistantToolCall(id: id, name: name, arguments: stringArguments(block["input"])))
                default: break
                }
            }
        case .openAICompatible:
            let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
            for call in message?["tool_calls"] as? [[String: Any]] ?? [] {
                guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let arguments = (function["arguments"] as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                calls.append(AssistantToolCall(id: id, name: name, arguments: stringArguments(arguments)))
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { throw AssistantError.invalidResponse }
        return AssistantReply(text: text, toolCalls: calls)
    }

    private static func stringArguments(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        return dictionary.compactMapValues { $0 as? String ?? ($0 as? CustomStringConvertible)?.description }
    }

    static func respond(settings: AssistantSettings, apiKey: String, system: String, messages: [AssistantMessage], tools: Bool) async throws -> AssistantReply {
        let request = try request(settings: settings, apiKey: apiKey, system: system, messages: messages, tools: tools)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try reply(from: data, provider: settings.provider, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Reads the reply text, or the provider's error message.
    static func replyText(from data: Data, provider: AssistantProvider, statusCode: Int) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200..<300).contains(statusCode) {
            let message = (object?["error"] as? [String: Any])?["message"] as? String
                ?? object?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw AssistantError.provider(message)
        }
        guard let object else { throw AssistantError.invalidResponse }
        switch provider {
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            guard !text.isEmpty else { throw AssistantError.invalidResponse }
            return text
        case .openAICompatible:
            guard let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String, !text.isEmpty else { throw AssistantError.invalidResponse }
            return text
        }
    }

    /// The request that lists a provider's models: GET /models, authenticated the way its API expects.
    static func modelsRequest(for provider: AssistantProviderConfig, apiKey: String) throws -> URLRequest {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + (provider.kind == .anthropic ? "/models?limit=1000" : "/models")), url.host != nil else {
            throw AssistantError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        switch provider.kind {
        case .anthropic:
            guard !apiKey.isEmpty else { throw AssistantError.notConfigured }
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    /// Reads a models list: {"data": [{"id": …, "display_name"?: …}]}, as both APIs return it.
    static func models(from data: Data, provider: AssistantProvider, statusCode: Int) throws -> [AssistantModelInfo] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if !(200..<300).contains(statusCode) {
            let message = (object?["error"] as? [String: Any])?["message"] as? String
                ?? object?["error"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw AssistantError.provider(message)
        }
        guard let entries = object?["data"] as? [[String: Any]] else { throw AssistantError.invalidResponse }
        let models = entries.compactMap { entry -> AssistantModelInfo? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return AssistantModelInfo(id: id, name: entry["display_name"] as? String ?? entry["name"] as? String)
        }
        // Anthropic lists newest first; other servers list in no particular order.
        return provider == .anthropic ? models : models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func listModels(for provider: AssistantProviderConfig, apiKey: String) async throws -> [AssistantModelInfo] {
        let (data, response) = try await URLSession.shared.data(for: modelsRequest(for: provider, apiKey: apiKey))
        return try models(from: data, provider: provider.kind, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func send(settings: AssistantSettings, apiKey: String, system: String, messages: [AssistantMessage]) async throws -> String {
        let request = try request(settings: settings, apiKey: apiKey, system: system, messages: messages)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try replyText(from: data, provider: settings.provider, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// A query result as the model sees it: column types, the row count, and the first rows, cut short so a
/// wide or long result doesn't flood the conversation.
enum AssistantToolOutput {
    static let maximumRows = 50
    static let maximumValueLength = 120
    static let maximumCharacters = 16_000

    static func summary(_ result: QueryResultTable) -> String {
        guard !result.columns.isEmpty else {
            let affected = result.affectedRowCount.map { "Rows affected: \($0)." } ?? ""
            return [result.executionSummary, affected].filter { !$0.isEmpty }.joined(separator: " ")
        }
        var lines = ["Columns: " + result.columns.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")]
        var count = "Rows: \(result.rows.count)"
        if result.isTruncated == true { count += " (cut off at Portbase's row limit)" }
        if result.rows.count > maximumRows { count += "; the first \(maximumRows) follow" }
        lines.append(count)
        lines.append(result.columns.map(\.name).joined(separator: " | "))
        for row in result.rows.prefix(maximumRows) {
            lines.append(row.cells.map { cell in
                if cell.isNull { return "NULL" }
                let value = cell.displayValue.replacingOccurrences(of: "\n", with: " ")
                return value.count > maximumValueLength ? String(value.prefix(maximumValueLength)) + "…" : value
            }.joined(separator: " | "))
        }
        var text = lines.joined(separator: "\n")
        if text.count > maximumCharacters { text = String(text.prefix(maximumCharacters)) + "\n… (output shortened)" }
        return text
    }
}

/// Runs the assistant's queries on the current connection, always through `DatabaseService` with an
/// explicit policy: read-only queries in a read-only session, approved changes as confirmed user queries.
struct AssistantQueryRunner {
    let engine: DatabaseEngine
    let isReadOnly: Bool
    let environment: ConnectionEnvironment
    let run: (String, DatabaseExecutionPolicy) async throws -> QueryResultTable

    /// Engines whose queries Portbase can classify as read-only or not before running them.
    static func supports(_ engine: DatabaseEngine) -> Bool { engine.isSQL || engine == .mongodb || engine == .redis }
}

// MARK: - Replies

/// A chart the assistant proposed: the query to run and how to plot its columns.
struct AssistantChartSuggestion: Codable, Equatable {
    var title: String?
    var type: String?
    var x: String
    var y: [String]
    var query: String

    var chartType: VisualizationChartType {
        VisualizationChartType(rawValue: (type ?? "").lowercased()) ?? .bar
    }
}

/// A piece of an assistant reply: prose, a query to insert, or a chart to build.
enum AssistantReplySegment: Equatable {
    case text(String)
    case code(language: String, code: String)
    case chart(AssistantChartSuggestion)
}

enum AssistantReplyParser {
    /// Splits a reply on fenced code blocks. ```chart blocks with valid JSON become chart suggestions.
    static func segments(_ reply: String) -> [AssistantReplySegment] {
        var segments: [AssistantReplySegment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            prose = []
        }

        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = language {
                if trimmed.hasPrefix("```") {
                    let body = code.joined(separator: "\n")
                    if open == "chart", let data = body.data(using: .utf8),
                       let chart = try? JSONDecoder().decode(AssistantChartSuggestion.self, from: data) {
                        segments.append(.chart(chart))
                    } else {
                        segments.append(.code(language: open, code: body))
                    }
                    code = []
                    language = nil
                } else {
                    code.append(line)
                }
            } else if trimmed.hasPrefix("```") {
                flushProse()
                language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            } else {
                prose.append(line)
            }
        }
        // An unterminated block still shows its content.
        if let open = language { segments.append(.code(language: open, code: code.joined(separator: "\n"))) }
        flushProse()
        return segments
    }
}
