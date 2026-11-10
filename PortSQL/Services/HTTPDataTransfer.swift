import Foundation
import NIOCore

/// Splits a streamed body into lines, keeping a partial line until the rest of it arrives.
final class StreamedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    /// A single line longer than this is refused rather than buffered without limit.
    static let maximumLineBytes = 64 * 1_024 * 1_024

    func consume(_ chunk: Data, line: (Data) throws -> Void) throws {
        try lock.withLock {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let current = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if !current.isEmpty { try line(Data(current)) }
            }
            guard pending.count <= Self.maximumLineBytes else { throw HTTPDatabaseError.responseTooLarge }
        }
    }

    /// The last line, when the body didn't end with a newline.
    func finish(line: (Data) throws -> Void) throws {
        try lock.withLock {
            if !pending.isEmpty { try line(pending) }
            pending = Data()
        }
    }
}

/// The batches an import sends, by count and by size, so each request stays under the transport's 1 MiB body limit.
struct ImportBatcher {
    static let maximumBytes = 900_000
    static let maximumRecords = 1_000
    private(set) var lines: [String] = []
    private(set) var bytes = 0

    var isEmpty: Bool { lines.isEmpty }

    /// Whether a line of this size still fits in the current batch.
    func fits(_ line: String) -> Bool {
        lines.isEmpty || (lines.count < Self.maximumRecords && bytes + line.utf8.count + 1 <= Self.maximumBytes)
    }

    mutating func append(_ line: String) throws {
        guard line.utf8.count + 1 <= Self.maximumBytes else { throw DataTransferError.recordTooLarge }
        lines.append(line); bytes += line.utf8.count + 1
    }

    mutating func take() -> [String] {
        defer { lines = []; bytes = 0 }
        return lines
    }
}

// MARK: - ClickHouse

enum ClickHouseDataTransfer {
    /// Streams every row of a read-only query, without the 10,000-row display limit, as ClickHouse writes it.
    static func export(query: BoundQuery, profile: ConnectionProfile, database: String?, timeoutSeconds: Int,
                       eventLoopGroup: EventLoopGroup, writer: DataExportWriter) async throws {
        var sql = query.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while sql.hasSuffix(";") { sql.removeLast(); sql = sql.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard try ClickHouseQueryService.classify(sql) else { throw DatabaseServiceError.readOnlyQueryRequired }
        var settings = ["default_format": "JSONCompactEachRowWithNamesAndTypes", "readonly": "1",
            "max_execution_time": String(timeoutSeconds), "timeout_overflow_mode": "throw",
            "output_format_json_quote_64bit_integers": "1", "output_format_json_quote_decimals": "1",
            "output_format_json_quote_denormals": "1", "cancel_http_readonly_queries_on_client_close": "1",
            // An error after rows have started is then written as text after an __exception__ line, never as
            // a JSON row that could pass for data.
            "http_write_exception_in_output_format": "0"]
        let selected = database?.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseName = selected?.isEmpty == false ? selected! : profile.trimmedDefaultDatabase
        if !databaseName.isEmpty { settings["database"] = databaseName }
        for (index, value) in query.values.enumerated() { settings["param_p\(index + 1)"] = try ClickHouseDatabaseClient.parameterText(value) }

        let lines = StreamedLines()
        let decoder = ClickHouseRowDecoder(writer: writer)
        _ = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: "/",
            queryItems: settings.keys.sorted().map { URLQueryItem(name: $0, value: settings[$0]) }, body: Data(sql.utf8),
            timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup,
            onChunk: { chunk in try lines.consume(chunk) { try decoder.line($0) } })
        try lines.finish { try decoder.line($0) }
        try decoder.finish()
    }

    /// Inserts the file in batches of JSONEachRow. ClickHouse has no transaction across batches, so an
    /// import that stops part way leaves the batches already confirmed.
    static func importRows(plan: DataImportPlan, profile: ConnectionProfile, database: String?, timeoutSeconds: Int,
                           eventLoopGroup: EventLoopGroup, progress: @escaping @Sendable (DataTransferProgress) -> Void) async throws -> DataTransferResult {
        let mappings = plan.mappings.filter { !$0.targetName.isEmpty }
        guard !mappings.isEmpty, Set(mappings.map(\.targetName)).count == mappings.count else { throw DataTransferError.invalidMapping }
        let schema = try await ClickHouseDatabaseClient.loadSchema(profile: profile, database: database, eventLoopGroup: eventLoopGroup)
        guard let destination = schema.first(where: { $0.name == plan.tableName }) else { throw DataTransferError.invalidMapping }
        var types: [String: String] = [:]
        for mapping in mappings {
            guard let column = destination.columns.first(where: { $0.name == mapping.targetName }) else { throw DataTransferError.invalidMapping }
            types[mapping.targetName] = column.type
        }
        let table = DataTransferCodec.identifier(plan.tableName, engine: .clickhouse)
        let columns = mappings.map { DataTransferCodec.identifier($0.targetName, engine: .clickhouse) }.joined(separator: ", ")
        let header = "INSERT INTO \(table) (\(columns)) FORMAT JSONEachRow\n"
        var settings = ["max_execution_time": String(timeoutSeconds), "date_time_input_format": "best_effort",
                        "input_format_json_read_numbers_as_strings": "1"]
        let selected = database?.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseName = selected?.isEmpty == false ? selected! : profile.trimmedDefaultDatabase
        if !databaseName.isEmpty { settings["database"] = databaseName }
        let items = settings.keys.sorted().map { URLQueryItem(name: $0, value: settings[$0]) }

        let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                                                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
        var batch = ImportBatcher()
        var completed = 0, record = 0
        func send() async throws {
            let lines = batch.take()
            do {
                _ = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: "/", queryItems: items,
                    body: Data((header + lines.joined(separator: "\n") + "\n").utf8), timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
            } catch HTTPDatabaseError.status(let code) {
                // A rejected insert wrote nothing; ClickHouse inserts each block whole.
                throw DataTransferError.partialImport(completed: completed, underlying: HTTPDatabaseError.status(code).localizedDescription)
            } catch {
                throw DataTransferError.partialImport(completed: completed, underlying: HTTPDatabaseError.unconfirmedWrite.localizedDescription)
            }
            completed += lines.count
            progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount))
        }
        do {
            while let next = try reader.next() {
                try Task.checkCancellation()
                record += 1
                var fields: [String: HTTPJSONValue] = [:]
                for mapping in mappings {
                    guard let cell = next.fields[mapping.sourceName] else { throw DataTransferError.missingField(column: mapping.sourceName, row: record) }
                    let type = mapping.valueType == .automatic ? DataTransferCodec.sqlValueType(for: types[mapping.targetName] ?? "") : mapping.valueType
                    fields[mapping.targetName] = try jsonValue(DataTransferCodec.boundValue(cell, type: type, column: mapping.targetName, row: record))
                }
                let line = HTTPJSONValue.object(fields).json()
                if !batch.fits(line) { try await send() }
                try batch.append(line)
            }
            try Task.checkCancellation()
            if !batch.isEmpty { try await send() }
        } catch let error as DataTransferError {
            if case .partialImport = error { throw error }
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error.localizedDescription)
        } catch {
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error is CancellationError ? L10n.text("Cancelled") : error.localizedDescription)
        }
        return DataTransferResult(rowCount: completed, fileURL: nil)
    }

    /// A typed import value as JSON. Numbers stay exact as their text; ClickHouse reads them into the column's type.
    static func jsonValue(_ value: QueryBoundValue) -> HTTPJSONValue {
        switch value {
        case .null: .null
        case .string(let text): .string(text)
        case .integer(let number): .number(String(number))
        case .decimal(let text): .string(text)
        case .boolean(let flag): .bool(flag)
        }
    }
}

/// Reads JSONCompactEachRowWithNamesAndTypes: a line of names, a line of types, then one array per row.
private final class ClickHouseRowDecoder: @unchecked Sendable {
    private let writer: DataExportWriter
    private var names: [String]?
    private var types: [String]?
    private var failed = false

    init(writer: DataExportWriter) { self.writer = writer }

    func line(_ data: Data) throws {
        if failed {
            throw HTTPDatabaseError.serverMessage(String(decoding: data.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if data.starts(with: Data("__exception__".utf8)) { failed = true; return }
        guard let value = try? HTTPJSONValue.parse(data, maximumBytes: StreamedLines.maximumLineBytes), let array = value.array else {
            // An error after rows started arrives as text in the body.
            let text = String(decoding: data.prefix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw text.isEmpty ? HTTPDatabaseError.invalidResponse : HTTPDatabaseError.serverMessage(text)
        }
        guard let names else { self.names = array.compactMap(\.string); return }
        guard let types else {
            let types = array.compactMap(\.string)
            guard types.count == names.count else { throw HTTPDatabaseError.invalidResponse }
            self.types = types
            writer.setColumns(zip(names, types).map { QueryColumn(name: $0, type: $1) })
            return
        }
        guard array.count == types.count else { throw HTTPDatabaseError.invalidResponse }
        try writer.append(QueryRow(cells: zip(array, types).map { ClickHouseDatabaseClient.cell($0, type: $1) }))
    }

    func finish() throws {
        if failed { throw HTTPDatabaseError.invalidResponse }
        // A query with no rows still has its header.
        if types == nil { writer.setColumns((names ?? []).map { QueryColumn(name: $0, type: "") }) }
    }
}

// MARK: - Elasticsearch

enum ElasticsearchDataTransfer {
    static let pageSize = 1_000

    /// Every hit of a search, paged with the scroll API: JSON keeps each hit as Elasticsearch returns it;
    /// CSV has `_id` and one column per field of `_source`, nested fields joined with dots.
    static func export(command: ElasticsearchCommand, profile: ConnectionProfile, format: QueryResultExportFormat,
                       timeoutSeconds: Int, eventLoopGroup: EventLoopGroup, writer: DataExportWriter,
                       progress: @escaping @Sendable (DataTransferProgress) -> Void) async throws -> DataTransferResult {
        guard command.isReadOnly, command.isSearch else { throw HTTPDatabaseError.unsupportedRequest }
        var fields = command.body?.object ?? [:]
        fields["size"] = .number(String(pageSize))
        fields["from"] = nil
        let spool = format == .csv ? try JSONDocumentCSVSpool(progress: progress) : nil
        func take(_ hits: [HTTPJSONValue]) throws {
            for hit in hits {
                try Task.checkCancellation()
                if let spool { try spool.append(flattened(hit)) } else { try writer.appendDocument(hit.json()) }
            }
        }
        let keepAlive = "\(max(1, timeoutSeconds))s"
        var response = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: command.path,
            queryItems: [URLQueryItem(name: "scroll", value: keepAlive)], body: Data(HTTPJSONValue.object(fields).json().utf8),
            timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
        var scrollID: String?
        do {
            while true {
                let json = try HTTPJSONValue.parse(response.body)
                scrollID = json["_scroll_id"]?.string ?? scrollID
                guard let hits = json["hits"]?["hits"]?.array else { throw HTTPDatabaseError.invalidResponse }
                if (json["_shards"]?["failed"]?.integer ?? 0) > 0 || json["timed_out"] == .bool(true) { throw HTTPDatabaseError.partialSearch }
                try take(hits)
                // The scroll ends with an empty page.
                guard !hits.isEmpty, let scrollID else { break }
                try Task.checkCancellation()
                response = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: "/_search/scroll",
                    body: Data(HTTPJSONValue.object(["scroll": .string(keepAlive), "scroll_id": .string(scrollID)]).json().utf8),
                    timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
            }
        } catch {
            await clear(scrollID, profile: profile, eventLoopGroup: eventLoopGroup)
            throw error
        }
        await clear(scrollID, profile: profile, eventLoopGroup: eventLoopGroup)
        if let spool { return try spool.finish(writer: writer) }
        return try writer.finish()
    }

    /// The export source for a whole index.
    static func searchAll(index: String) throws -> ElasticsearchCommand {
        try ElasticsearchQueryService.parse(HTTPJSONValue.object([
            "method": .string("POST"), "path": .string("/" + index + "/_search"),
            "body": .object(["query": .object(["match_all": .object([:])])]),
        ]).json())
    }

    /// Releases the scroll's search context; a failure only means it expires on its own.
    private static func clear(_ scrollID: String?, profile: ConnectionProfile, eventLoopGroup: EventLoopGroup) async {
        guard let scrollID else { return }
        _ = try? await HTTPDatabaseTransport.request(profile: profile, method: "DELETE", path: "/_search/scroll",
            body: Data(HTTPJSONValue.object(["scroll_id": .array([.string(scrollID)])]).json().utf8),
            timeoutSeconds: 10, eventLoopGroup: eventLoopGroup)
    }

    /// A hit as one flat object: `_id`, then each field of `_source`, nested objects joined with dots.
    static func flattened(_ hit: HTTPJSONValue) -> [(String, HTTPJSONValue)] {
        var pairs: [(String, HTTPJSONValue)] = []
        if let id = hit["_id"] { pairs.append(("_id", id)) }
        func visit(_ value: HTTPJSONValue, prefix: String, depth: Int) {
            guard let fields = value.object, depth < 8 else { pairs.append((prefix, value)); return }
            for key in fields.keys.sorted() {
                let name = prefix.isEmpty ? key : prefix + "." + key
                if let child = fields[key], child.object != nil, child.object?.isEmpty == false { visit(child, prefix: name, depth: depth + 1) }
                else { pairs.append((name, fields[key] ?? .null)) }
            }
        }
        if let source = hit["_source"] { visit(source, prefix: "", depth: 0) }
        return pairs
    }

    /// Indexes the file with the bulk API. Each batch is confirmed item by item; the import stops at the
    /// first batch with a rejected document, reporting the documents already indexed.
    static func importDocuments(plan: DataImportPlan, profile: ConnectionProfile, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
                                progress: @escaping @Sendable (DataTransferProgress) -> Void) async throws -> DataTransferResult {
        let index = plan.tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ElasticsearchQueryService.validIndex(index, allowPattern: false) else { throw DataTransferError.invalidMapping }
        let mappings = plan.mappings.filter { !$0.targetName.isEmpty }
        guard Set(mappings.map(\.targetName)).count == mappings.count else { throw DataTransferError.invalidMapping }
        let action = HTTPJSONValue.object(["index": .object(["_index": .string(index)])]).json()
        let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                                                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
        var batch = ImportBatcher()
        var completed = 0, record = 0
        func send() async throws {
            let lines = batch.take()
            let response: HTTPDatabaseResponse
            do {
                response = try await HTTPDatabaseTransport.request(profile: profile, method: "POST", path: "/_bulk",
                    queryItems: [URLQueryItem(name: "refresh", value: "wait_for")],
                    body: Data((lines.joined(separator: "\n") + "\n").utf8), timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
            } catch {
                throw DataTransferError.partialImport(completed: completed, underlying: HTTPDatabaseError.unconfirmedWrite.localizedDescription)
            }
            guard let json = try? HTTPJSONValue.parse(response.body), let items = json["items"]?.array else {
                throw DataTransferError.partialImport(completed: completed, underlying: HTTPDatabaseError.unconfirmedWrite.localizedDescription)
            }
            let indexed = items.filter { ($0["index"]?["status"]?.integer).map { (200..<300).contains($0) } == true }.count
            completed += indexed
            progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount))
            if indexed < items.count {
                let reason = items.lazy.compactMap { $0["index"]?["error"]?["reason"]?.string }.first ?? HTTPDatabaseError.invalidResponse.localizedDescription
                throw DataTransferError.partialImport(completed: completed, underlying: reason)
            }
        }
        do {
            while let next = try reader.next() {
                try Task.checkCancellation()
                record += 1
                let source: HTTPJSONValue
                if mappings.isEmpty, let original = next.documentJSON {
                    source = try HTTPJSONValue.parse(original)
                } else {
                    var fields: [String: HTTPJSONValue] = [:]
                    for mapping in mappings {
                        guard let cell = next.fields[mapping.sourceName] else { continue }  // A missing field stays absent.
                        fields[mapping.targetName] = try documentValue(cell, type: mapping.valueType, column: mapping.targetName, row: record)
                    }
                    source = .object(fields)
                }
                let pair = action + "\n" + source.json()
                if !batch.fits(pair) { try await send() }
                try batch.append(pair)
            }
            try Task.checkCancellation()
            if !batch.isEmpty { try await send() }
        } catch let error as DataTransferError {
            if case .partialImport = error { throw error }
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error.localizedDescription)
        } catch {
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error is CancellationError ? L10n.text("Cancelled") : error.localizedDescription)
        }
        return DataTransferResult(rowCount: completed, fileURL: nil)
    }

    /// A field's value: typed as chosen, or kept as the file had it.
    static func documentValue(_ cell: QueryCell, type: DataImportValueType, column: String, row: Int) throws -> HTTPJSONValue {
        if cell.isNull { return .null }
        if type == .json || (type == .automatic && (cell.isJSONValue)) {
            guard let value = try? HTTPJSONValue.parse(cell.displayValue) else { throw DataTransferError.invalidValue(column: column, row: row) }
            return value
        }
        switch try DataTransferCodec.boundValue(cell, type: type, column: column, row: row) {
        case .null: return .null
        case .string(let text): return type == .decimal && DataTransferCodec.isJSONNumber(text) ? .number(text) : .string(text)
        case .integer(let number): return .number(String(number))
        case .decimal(let text): return .number(text)
        case .boolean(let flag): return .bool(flag)
        }
    }
}

private extension QueryCell {
    var isJSONValue: Bool {
        switch self {
        case .json, .extendedJSON: true
        case .decimal: true
        default: false
        }
    }
}

/// Documents whose fields vary are spooled to disk while the CSV header is discovered, then written in order.
final class JSONDocumentCSVSpool: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var names: [String] = []
    private var seen = Set<String>()
    private var count = 0
    private let progress: @Sendable (DataTransferProgress) -> Void

    init(progress: @escaping @Sendable (DataTransferProgress) -> Void) throws {
        self.progress = progress
        url = try DataExportWriter.temporaryURL(extension: "jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: WorkspaceFileStore.fileAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }

    func append(_ pairs: [(String, HTTPJSONValue)]) throws {
        let completed = try lock.withLock {
            for (name, _) in pairs where seen.insert(name).inserted {
                names.append(name)
                guard names.count <= DataTransferCodec.maximumColumns else { throw DataTransferError.tooManyColumns }
            }
            var object: [String: HTTPJSONValue] = [:]
            for (name, value) in pairs { object[name] = value }
            try handle.write(contentsOf: Data((HTTPJSONValue.object(object).json() + "\n").utf8))
            count += 1
            return count
        }
        if completed % 250 == 0 { progress(.init(phase: .exporting, completed: completed, total: nil)) }
    }

    func finish(writer: DataExportWriter) throws -> DataTransferResult {
        try handle.synchronize()
        try handle.close()
        writer.setColumns(names.map { QueryColumn(name: $0, type: "JSON") })
        progress(.init(phase: .finishing, completed: count, total: count))
        let reader = try JSONRecordReader(url: url, maximumBytes: 64 * 1_024 * 1_024)
        while let text = try reader.next() {
            try Task.checkCancellation()
            let object = try HTTPJSONValue.parse(text, maximumBytes: 64 * 1_024 * 1_024)
            // A field the document lacks is NULL in its row; a JSON null is NULL too.
            try writer.append(QueryRow(cells: names.map { object[$0]?.cell ?? .null }))
        }
        return try writer.finish()
    }
}
