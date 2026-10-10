import Foundation
import NIOCore

enum ClickHouseDatabaseClient {
    static func execute(query: String, values: [QueryBoundValue] = [], profile: ConnectionProfile,
                        database: String?, policy: DatabaseExecutionPolicy, timeoutSeconds: Int = 30,
                        eventLoopGroup: EventLoopGroup) async throws -> QueryResultTable {
        guard profile.httpAuthentication != .apiKey else { throw DatabaseServiceError.unsupported }
        guard values.isEmpty else { throw HTTPDatabaseError.unsupportedParameters }
        let isRead = try ClickHouseQueryService.classify(query)
        try enforcePolicy(isReadOnly: isRead, profile: profile, policy: policy)
        let timeout = min(300, max(1, timeoutSeconds))
        var settings = ["default_format": "JSONCompact", "readonly": isRead ? "1" : "0",
            "max_execution_time": String(timeout), "timeout_overflow_mode": "throw",
            "max_result_rows": "10001", "max_result_bytes": "0",
            "result_overflow_mode": "break", "max_block_size": "1000", "wait_end_of_query": "1",
            "buffer_size": "1048576", "output_format_json_quote_64bit_integers": "1",
            "output_format_json_quote_decimals": "1", "output_format_json_quote_denormals": "1"]
        if isRead { settings["cancel_http_readonly_queries_on_client_close"] = "1" }
        let selected = database?.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseName = selected?.isEmpty == false ? selected! : profile.trimmedDefaultDatabase
        if !databaseName.isEmpty { settings["database"] = databaseName }
        let response: HTTPDatabaseResponse
        do {
            response = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: "/",
                queryItems: settings.keys.sorted().map { URLQueryItem(name: $0, value: settings[$0]) }, body: Data(query.utf8),
                timeoutSeconds: timeout, eventLoopGroup: eventLoopGroup)
        } catch {
            if !isRead { throw HTTPDatabaseError.unconfirmedWrite }
            throw error
        }
        guard response.headers["x-clickhouse-exception-code"].map({ $0 == "0" }) ?? true else {
            throw isRead ? HTTPDatabaseError.invalidResponse : HTTPDatabaseError.unconfirmedWrite
        }
        if response.body.allSatisfy({ [9, 10, 13, 32].contains($0) }), !isRead {
            let count = response.headers["x-clickhouse-summary"].flatMap { (try? HTTPJSONValue.parse($0))?["written_rows"]?.integer }
            let summary = count.map { L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: $0)) }
                ?? L10n.text("Statement executed successfully.")
            return QueryResultTable(columns: [], rows: [], executionSummary: summary, generatedMutation: nil,
                profiles: [], sourceTableReference: nil, affectedRowCount: count)
        }
        do { return try materialize(HTTPJSONValue.parse(response.body), profileName: profile.name) }
        catch { if !isRead { throw HTTPDatabaseError.unconfirmedWrite }; throw error }
    }

    static func enforcePolicy(isReadOnly: Bool, profile: ConnectionProfile, policy: DatabaseExecutionPolicy) throws {
        if profile.isReadOnly && !isReadOnly { throw DatabaseServiceError.readOnlyViolation }
        switch policy {
        case .readOnly where !isReadOnly: throw DatabaseServiceError.readOnlyQueryRequired
        case .userQuery(let confirmed) where !isReadOnly && !confirmed: throw DatabaseServiceError.unsafeQueryRequiresConfirmation
        case .mutation(let expected) where expected != nil: throw DatabaseServiceError.unsupported
        default: break
        }
    }

    static func materialize(_ json: HTTPJSONValue, profileName: String) throws -> QueryResultTable {
        guard let metadata = json["meta"]?.array, let data = json["data"]?.array,
              metadata.count <= 4_096 else { throw HTTPDatabaseError.invalidResponse }
        let columns = try metadata.map { field -> QueryColumn in
            guard let name = field["name"]?.string, let type = field["type"]?.string else { throw HTTPDatabaseError.invalidResponse }
            return QueryColumn(name: name, type: type)
        }
        let rows = try data.prefix(10_000).map { value -> QueryRow in
            guard let cells = value.array, cells.count == columns.count else { throw HTTPDatabaseError.invalidResponse }
            return QueryRow(cells: zip(cells, columns).map { cell($0.0, type: $0.1.type) })
        }
        let truncated = data.count > 10_000
        let summary = truncated
            ? L10n.format("Showing the first %@ from %@; additional rows were truncated.", L10n.plural("row_count", count: rows.count), profileName)
            : L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: rows.count), profileName)
        return QueryResultTable(columns: columns, rows: rows, executionSummary: summary, generatedMutation: nil,
            profiles: DatabaseService.makeProfiles(columns: columns, rows: rows), sourceTableReference: nil, isTruncated: truncated)
    }

    private static func cell(_ value: HTTPJSONValue, type: String) -> QueryCell {
        if value == .null { return .null }
        var base = type
        while ["Nullable(", "LowCardinality("].contains(where: base.hasPrefix), base.hasSuffix(")"), let open = base.firstIndex(of: "(") {
            base = String(base[base.index(after: open)..<base.index(before: base.endIndex)])
        }
        if base.hasPrefix("Int") || base.hasPrefix("UInt"), let text = value.scalar { return .integer(text) }
        if ["Decimal", "Float", "BFloat"].contains(where: base.hasPrefix), let text = value.scalar { return .decimal(text) }
        if base == "Bool" {
            if case .bool(let bool) = value { return .boolean(bool) }
            if let text = value.scalar { return .boolean(text == "1" || text == "true") }
        }
        if base.hasPrefix("Date"), let text = value.scalar { return .dateTime(text) }
        return value.cell
    }

    static func listDatabases(profile: ConnectionProfile, eventLoopGroup: EventLoopGroup) async throws -> [String] {
        let result = try await execute(query: "SHOW DATABASES", profile: profile, database: nil, policy: .readOnly, eventLoopGroup: eventLoopGroup)
        return result.rows.compactMap { $0.cells.first?.displayValue }
    }

    static func loadSchema(profile: ConnectionProfile, database: String?, eventLoopGroup: EventLoopGroup) async throws -> [SchemaTableDescriptor] {
        let result = try await execute(query: "SELECT table, name, type, is_in_primary_key FROM system.columns WHERE database = currentDatabase() ORDER BY table, position",
            profile: profile, database: database, policy: .readOnly, eventLoopGroup: eventLoopGroup)
        var tables: [String: [SchemaColumnDescriptor]] = [:]
        for row in result.rows where row.cells.count == 4 {
            let name = row.cells[0].displayValue, type = row.cells[2].displayValue
            tables[name, default: []].append(.init(name: row.cells[1].displayValue, type: type,
                isNullable: type.contains("Nullable("), isPrimaryKey: row.cells[3].displayValue == "1", isUnique: false))
        }
        guard result.isTruncated != true else { throw HTTPDatabaseError.responseTooLarge }
        return tables.keys.sorted().map { .init(schemaName: "", name: $0, columns: tables[$0]!, rowCountEstimate: nil) }
    }
}
