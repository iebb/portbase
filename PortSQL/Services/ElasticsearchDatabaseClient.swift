import Foundation
import NIOCore

enum ElasticsearchDatabaseClient {
    static func execute(command: ElasticsearchCommand, profile: ConnectionProfile, database: String?,
                        policy: DatabaseExecutionPolicy, timeoutSeconds: Int = 30, eventLoopGroup: EventLoopGroup) async throws -> QueryResultTable {
        // Reparse at the client boundary: callers cannot forge isReadOnly on a command value.
        let command = try ElasticsearchQueryService.parse(command.preview)
        try ClickHouseDatabaseClient.enforcePolicy(isReadOnly: command.isReadOnly, profile: profile, policy: policy)
        let timeout = min(300, max(1, timeoutSeconds))
        var body = command.body
        var clippedSize = false
        if command.isSearch {
            var fields = body?.object ?? [:]
            let requestedSize = fields["size"]?.integer ?? 100
            guard (fields["size"] == nil || fields["size"]?.integer != nil), requestedSize >= 0,
                  fields["from"] == nil || (fields["from"]?.integer ?? -1) >= 0 else { throw HTTPDatabaseError.invalidRequest }
            clippedSize = requestedSize > 10_000
            fields["size"] = .number(String(min(requestedSize, 10_000)))
            let existingTimeout = try fields["timeout"].map { try timeoutMilliseconds($0) } ?? timeout * 1000
            fields["timeout"] = .string("\(min(existingTimeout, timeout * 1000))ms")
            body = .object(fields)
        }
        let items = command.isReadOnly || command.path.split(separator: "/").count == 1 ? [] : [URLQueryItem(name: "refresh", value: "wait_for")]
        let response: HTTPDatabaseResponse
        do {
            response = try await HTTPDatabaseTransport.request(profile: profile, method: command.method, path: command.path,
                queryItems: items, body: body.map { Data($0.json().utf8) }, timeoutSeconds: timeout, eventLoopGroup: eventLoopGroup)
        } catch {
            if !command.isReadOnly { throw HTTPDatabaseError.unconfirmedWrite }
            throw error
        }
        let json: HTTPJSONValue
        do { json = try HTTPJSONValue.parse(response.body) }
        catch { if !command.isReadOnly { throw HTTPDatabaseError.unconfirmedWrite }; throw error }
        let partial = json["timed_out"] == .bool(true) || (json["_shards"]?["failed"]?.integer ?? 0) > 0
        var documents: [HTTPJSONValue]
        if let hits = json["hits"]?["hits"]?.array, !hits.isEmpty || json["aggregations"] == nil {
            documents = hits
        } else if let aggregations = json["aggregations"]?.object {
            documents = aggregationRows(aggregations)
        } else { documents = [json] }
        let truncated = documents.count > 10_000 || (clippedSize && documents.count == 10_000)
        documents = Array(documents.prefix(10_000))
        let affected: Int? = command.isReadOnly ? nil : (["created", "updated", "deleted"].contains(json["result"]?.string ?? "") ? 1 : nil)
        return materialize(documents: documents, profileName: profile.name, truncated: truncated, partial: partial, affectedRows: affected)
    }

    private static func timeoutMilliseconds(_ value: HTTPJSONValue) throws -> Int {
        guard let text = value.string else { throw HTTPDatabaseError.invalidRequest }
        let multiplier = text.hasSuffix("ms") ? 1 : text.hasSuffix("s") ? 1000 : 0
        guard multiplier != 0, let number = Int(text.dropLast(multiplier == 1 ? 2 : 1)), (1...300_000).contains(number) else {
            throw HTTPDatabaseError.invalidRequest
        }
        return min(300_000, number * multiplier)
    }

    static func materialize(documents: [HTTPJSONValue], profileName: String, truncated: Bool = false,
                            partial: Bool = false, affectedRows: Int? = nil) -> QueryResultTable {
        var names: [String] = [], paths: [[String]] = [], seen = Set<String>()
        // Include root objects for inspection, followed by scalar paths for sorting and charts.
        for document in documents {
            for key in document.object?.keys.sorted() ?? [] where names.count < 256 {
                if seen.insert(key).inserted { names.append(key); paths.append([key]) }
            }
        }
        func visit(_ value: HTTPJSONValue, prefix: [String]) {
            guard prefix.count < 8, names.count < 256, let fields = value.object else { return }
            for key in fields.keys.sorted() {
                let path = prefix + [key], name = path.joined(separator: ".")
                if fields[key]?.object != nil { visit(fields[key]!, prefix: path) }
                else if path.count > 1, names.count < 256, seen.insert(name).inserted { names.append(name); paths.append(path) }
            }
        }
        for document in documents { visit(document, prefix: []) }
        let columns = names.map { QueryColumn(name: $0, type: "JSON") }
        let rows = documents.map { document in
            QueryRow(cells: paths.map { path in
                path.reduce(Optional(document)) { $0?[$1] }?.cell ?? .json("{\"$missing\":true}")
            })
        }
        let summary: String
        if partial { summary = L10n.text("Elasticsearch returned partial results. A shard failed or the search timed out.") }
        else if truncated { summary = L10n.format("Showing the first %@ from %@; additional rows were truncated.", L10n.plural("row_count", count: rows.count), profileName) }
        else if let affectedRows { summary = L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: affectedRows)) }
        else { summary = L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: rows.count), profileName) }
        var result = QueryResultTable(columns: columns, rows: rows, executionSummary: summary, generatedMutation: nil,
            profiles: DatabaseService.makeProfiles(columns: columns, rows: rows), sourceTableReference: nil,
            affectedRowCount: affectedRows, isTruncated: truncated || partial)
        result.documents = documents.map { $0.json() }
        return result
    }

    private static func aggregationRows(_ fields: [String: HTTPJSONValue]) -> [HTTPJSONValue] {
        var rows: [HTTPJSONValue] = []
        for name in fields.keys.sorted() {
            guard let aggregation = fields[name] else { continue }
            if let buckets = aggregation["buckets"]?.array {
                for bucket in buckets.prefix(10_001 - rows.count) {
                    var fields = bucket.object ?? ["value": bucket]
                    fields["aggregation"] = .string(name)
                    rows.append(.object(fields))
                }
            } else if let buckets = aggregation["buckets"]?.object {
                for key in buckets.keys.sorted().prefix(10_001 - rows.count) {
                    var fields = buckets[key]?.object ?? [:]
                    fields["aggregation"] = .string(name); fields["key"] = fields["key"] ?? .string(key)
                    rows.append(.object(fields))
                }
            } else {
                rows.append(.object(["aggregation": .string(name), "metric": aggregation]))
            }
            if rows.count >= 10_001 { break }
        }
        return rows
    }

    static func listDatabases(profile: ConnectionProfile, eventLoopGroup: EventLoopGroup) async throws -> [String] {
        // Elasticsearch has no database namespaces. Mapping discovery verifies connectivity
        // using index privileges, without requiring cluster-monitor access to GET /.
        return ["_all"]
    }

    static func loadSchema(profile: ConnectionProfile, database: String?, eventLoopGroup: EventLoopGroup) async throws -> [SchemaTableDescriptor] {
        let command = try ElasticsearchQueryService.parse("{\"method\":\"GET\",\"path\":\"/_mapping\"}")
        let result = try await execute(command: command, profile: profile, database: database, policy: .readOnly, eventLoopGroup: eventLoopGroup)
        guard let document = result.documents?.first,
              let indices = try HTTPJSONValue.parse(document, maximumBytes: HTTPDatabaseTransport.maximumResponseBytes).object else { throw HTTPDatabaseError.invalidResponse }
        guard indices.count <= 10_000 else { throw HTTPDatabaseError.responseTooLarge }
        return try indices.keys.sorted().map { index in
            var columns: [SchemaColumnDescriptor] = []
            func visit(_ fields: [String: HTTPJSONValue], prefix: String, depth: Int) throws {
                guard depth <= 32 else { throw HTTPDatabaseError.responseTooLarge }
                for name in fields.keys.sorted() {
                    guard columns.count < 4_096 else { throw HTTPDatabaseError.responseTooLarge }
                    let field = fields[name]!, path = prefix.isEmpty ? name : prefix + "." + name
                    columns.append(.init(name: path, type: field["type"]?.string ?? "object", isNullable: true, isPrimaryKey: false, isUnique: false))
                    if let properties = field["properties"]?.object { try visit(properties, prefix: path, depth: depth + 1) }
                    if let subfields = field["fields"]?.object { try visit(subfields, prefix: path, depth: depth + 1) }
                }
            }
            if let properties = indices[index]?["mappings"]?["properties"]?.object { try visit(properties, prefix: "", depth: 0) }
            return SchemaTableDescriptor(schemaName: "", name: index, columns: columns, rowCountEstimate: nil)
        }
    }
}
