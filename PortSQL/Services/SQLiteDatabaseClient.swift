import Foundation
import SQLite3

/// The native driver is called through DatabaseService. It also enforces the execution policy itself.
enum SQLiteDatabaseClient {
    static let maximumMaterializedRows = 10_000

    static func execute(query: String, values: [QueryBoundValue] = [], profile: ConnectionProfile,
                        policy: DatabaseExecutionPolicy, timeoutSeconds: Int = 30) async throws -> QueryResultTable {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        return try await withConnection(profile: profile, policy: policy, timeoutSeconds: timeoutSeconds) { connection in
            let statement = try connection.prepare(query)
            defer { sqlite3_finalize(statement) }
            try connection.bind(values, to: statement)
            let readOnly = sqlite3_stmt_readonly(statement) != 0
            try connection.validate(readOnly: readOnly)
            var transaction = false
            do {
                if !readOnly { try connection.control("BEGIN IMMEDIATE"); transaction = true }
                let output = try connection.read(statement, maximumRows: maximumMaterializedRows)
                let affected = readOnly ? nil : Int(sqlite3_changes64(connection.handle))
                if case .mutation(let expected) = policy, let expected, affected != expected {
                    throw DatabaseServiceError.unexpectedAffectedRowCount(expected: expected, actual: affected ?? -1)
                }
                try connection.operation.check()
                if transaction { try connection.control("COMMIT"); transaction = false }
                let summary: String
                if !output.columns.isEmpty {
                    summary = output.isTruncated
                        ? L10n.format("Showing the first %@ from %@; additional rows were truncated.", L10n.plural("row_count", count: output.rows.count), profile.name)
                        : L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: output.rows.count), profile.name)
                } else if let affected {
                    summary = L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: affected))
                } else { summary = L10n.text("Statement executed successfully.") }
                return QueryResultTable(columns: output.columns, rows: output.rows, executionSummary: summary,
                    generatedMutation: nil, profiles: DatabaseService.makeProfiles(columns: output.columns, rows: output.rows), sourceTableReference: nil, sourceQuery: query,
                    affectedRowCount: affected, isTruncated: output.isTruncated)
            } catch {
                if transaction { connection.rollback() }
                throw error
            }
        }
    }

    static func withConnection<T: Sendable>(profile: ConnectionProfile, policy: DatabaseExecutionPolicy,
                                            timeoutSeconds: Int = 30,
                                            operation: @escaping @Sendable (SQLiteConnection) throws -> T) async throws -> T {
        guard let fileName = profile.sqliteFileName else { throw SQLiteClientError.missingFile }
        if profile.isReadOnly, case .mutation = policy { throw DatabaseServiceError.readOnlyViolation }
        return try await SQLiteOperation.run(timeoutSeconds: timeoutSeconds) { lifetime in
            let lease = try SQLiteFileStore.shared.acquire(fileName: fileName)
            defer { lease.release() }
            let connection = try SQLiteConnection(url: lease.url, profileReadOnly: profile.isReadOnly, policy: policy, operation: lifetime)
            defer { connection.close() }
            return try operation(connection)
        }
    }
}

/// Cancellation and sqlite3_close are serialized so sqlite3_interrupt never receives a closed handle.
final class SQLiteOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: Set<OpaquePointer> = []
    private var cancelled = false
    private let deadline: TimeInterval

    init(timeoutSeconds: Int) { deadline = ProcessInfo.processInfo.systemUptime + Double(max(1, min(timeoutSeconds, 300))) }

    var shouldStop: Bool { lock.withLock { cancelled || ProcessInfo.processInfo.systemUptime >= deadline } }

    func check() throws {
        let wasCancelled = lock.withLock { cancelled }
        if wasCancelled || Task.isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw DatabaseServiceError.queryTimedOut }
    }

    func attach(_ handle: OpaquePointer) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            handles.insert(handle)
        }
    }

    func close(_ handle: OpaquePointer) {
        lock.withLock { _ = handles.remove(handle) }
        sqlite3_close_v2(handle)
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            for handle in handles { sqlite3_interrupt(handle) }
        }
    }

    static func run<T: Sendable>(timeoutSeconds: Int, body: @escaping @Sendable (SQLiteOperation) throws -> T) async throws -> T {
        let operation = SQLiteOperation(timeoutSeconds: timeoutSeconds)
        let worker = Task.detached(priority: .userInitiated) {
            try operation.check()
            return try body(operation)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            operation.cancel()
            worker.cancel()
        })
    }
}

struct SQLiteRows {
    let columns: [QueryColumn]
    let rows: [QueryRow]
    let isTruncated: Bool
}

/// A connection and its statements are confined to one worker. Only SQLiteOperation may interrupt it.
final class SQLiteConnection {
    let handle: OpaquePointer
    let operation: SQLiteOperation
    private let profileReadOnly: Bool
    private let policy: DatabaseExecutionPolicy
    private let authorization: SQLiteAuthorization
    private var closed = false

    init(url: URL, profileReadOnly: Bool, policy: DatabaseExecutionPolicy, operation: SQLiteOperation) throws {
        self.operation = operation
        self.profileReadOnly = profileReadOnly
        self.policy = policy
        let confirmed: Bool
        if case .userQuery(let value) = policy { confirmed = value } else { confirmed = true }
        let readOnly = profileReadOnly || policy.requiresReadOnlySession || !confirmed
        authorization = SQLiteAuthorization(readOnly: readOnly)
        var opened: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(try SQLiteFileStore.canonicalPath(for: url), &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteClientError.database(code: code, message: message)
        }
        handle = opened
        do {
            try operation.attach(opened)
            let configuration = PortSQLConfigureSQLite(opened)
            guard configuration == SQLITE_OK else { throw SQLiteClientError.database(code: configuration, message: String(cString: sqlite3_errmsg(opened))) }
            sqlite3_extended_result_codes(opened, 1)
            sqlite3_limit(opened, SQLITE_LIMIT_LENGTH, 64 * 1_024 * 1_024)
            sqlite3_limit(opened, SQLITE_LIMIT_SQL_LENGTH, 1_024 * 1_024)
            sqlite3_limit(opened, SQLITE_LIMIT_COLUMN, 2_000)
            sqlite3_limit(opened, SQLITE_LIMIT_VARIABLE_NUMBER, 32_766)
            let context = Unmanaged.passUnretained(operation).toOpaque()
            sqlite3_progress_handler(opened, 1_000, { raw in
                guard let raw else { return 1 }
                return Unmanaged<SQLiteOperation>.fromOpaque(raw).takeUnretainedValue().shouldStop ? 1 : 0
            }, context)
            sqlite3_busy_handler(opened, { raw, attempts in
                guard let raw, attempts < 500 else { return 0 }
                let operation = Unmanaged<SQLiteOperation>.fromOpaque(raw).takeUnretainedValue()
                guard !operation.shouldStop else { return 0 }
                sqlite3_sleep(10)
                return operation.shouldStop ? 0 : 1
            }, context)
            try rawControl("PRAGMA trusted_schema = OFF")
            try rawControl("PRAGMA foreign_keys = ON")
            if readOnly { try rawControl("PRAGMA query_only = ON") }
            sqlite3_set_authorizer(opened, { raw, action, first, second, _, _ in
                guard let raw else { return SQLITE_DENY }
                return Unmanaged<SQLiteAuthorization>.fromOpaque(raw).takeUnretainedValue()
                    .authorize(action, first: first.map(String.init(cString:)), second: second.map(String.init(cString:)))
            }, Unmanaged.passUnretained(authorization).toOpaque())
            try operation.check()
        } catch {
            operation.close(opened)
            closed = true
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        sqlite3_set_authorizer(handle, nil, nil)
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_busy_handler(handle, nil, nil)
        operation.close(handle)
    }

    func validate(readOnly: Bool) throws {
        guard !readOnly else { return }
        if profileReadOnly { throw DatabaseServiceError.readOnlyViolation }
        switch policy {
        case .readOnly: throw DatabaseServiceError.readOnlyQueryRequired
        case .userQuery(let confirmed) where !confirmed: throw DatabaseServiceError.unsafeQueryRequiresConfirmation
        default: break
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard !sql.contains("\0"), sql.utf8.count <= 1_024 * 1_024 else { throw SQLiteClientError.singleStatementRequired }
        try operation.check()
        authorization.denial = nil
        var first: OpaquePointer?
        do {
            try sql.withCString { start in
                var cursor: UnsafePointer<CChar>? = start
                while let text = cursor, text.pointee != 0 {
                    var statement: OpaquePointer?
                    var tail: UnsafePointer<CChar>?
                    let code = sqlite3_prepare_v2(handle, text, -1, &statement, &tail)
                    guard code == SQLITE_OK else {
                        if let statement { sqlite3_finalize(statement) }
                        throw error(code)
                    }
                    if let statement {
                        if first != nil { sqlite3_finalize(statement); throw SQLiteClientError.singleStatementRequired }
                        first = statement
                    }
                    guard let tail, tail > text else { break }
                    cursor = tail
                }
            }
            guard let first else { throw SQLiteClientError.singleStatementRequired }
            return first
        } catch {
            if let first { sqlite3_finalize(first) }
            throw error
        }
    }

    func bind(_ values: [QueryBoundValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else { throw SQLiteClientError.invalidParameter }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, position)
            case .integer(let number): code = sqlite3_bind_int64(statement, position, number)
            case .boolean(let value): code = sqlite3_bind_int64(statement, position, value ? 1 : 0)
            case .decimal(let text):
                guard let number = Double(text), number.isFinite else { throw SQLiteClientError.invalidParameter }
                code = sqlite3_bind_double(statement, position, number)
            case .string(let text):
                guard text.utf8.count <= 64 * 1_024 * 1_024 else { throw SQLiteClientError.invalidParameter }
                code = text.withCString { sqlite3_bind_text(statement, position, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            guard code == SQLITE_OK else { throw error(code) }
        }
    }

    /// The table column a result column reads, as SQLite reports it; nil for computed values.
    static func origin(_ statement: OpaquePointer, index: Int32) -> QueryColumnOrigin? {
        guard let table = sqlite3_column_table_name(statement, index), let column = sqlite3_column_origin_name(statement, index) else { return nil }
        return QueryColumnOrigin(schema: sqlite3_column_database_name(statement, index).map(String.init(cString:)),
                                 table: String(cString: table), column: String(cString: column))
    }

    func read(_ statement: OpaquePointer, maximumRows: Int?, onColumns: (([QueryColumn]) -> Void)? = nil,
              onRow: ((QueryRow) throws -> Void)? = nil) throws -> SQLiteRows {
        let count = sqlite3_column_count(statement)
        var columns = (0..<count).map { index in
            QueryColumn(name: String(cString: sqlite3_column_name(statement, index)),
                type: sqlite3_column_decltype(statement, index).map(String.init(cString:)) ?? "ANY",
                origin: Self.origin(statement, index: index))
        }
        var rows: [QueryRow] = []
        var materializedBytes = 0
        var truncated = false
        var emittedColumns = false
        while true {
            try operation.check()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(code) }
            if !emittedColumns {
                columns = columns.enumerated().map { index, column in
                    column.type == "ANY" ? QueryColumn(name: column.name, type: Self.storageType(sqlite3_column_type(statement, Int32(index))),
                                                       origin: column.origin) : column
                }
                onColumns?(columns); emittedColumns = true
            }
            let rowBytes = columns.indices.reduce(0) { total, index in
                let column = Int32(index)
                let type = sqlite3_column_type(statement, column)
                return total + ((type == SQLITE_TEXT || type == SQLITE_BLOB) ? Int(sqlite3_column_bytes(statement, column)) : 16)
            }
            if let maximumRows, rows.count >= maximumRows || materializedBytes + rowBytes > 64 * 1_024 * 1_024 {
                truncated = true
                // Read queries can stop immediately. DML RETURNING must finish before its transaction commits.
                if sqlite3_stmt_readonly(statement) != 0 { break }
                continue
            }
            let row = QueryRow(cells: columns.indices.map { Self.cell(statement, index: Int32($0), declaredType: columns[$0].type) })
            if let onRow { try onRow(row) } else { rows.append(row); materializedBytes += rowBytes }
        }
        if !emittedColumns { onColumns?(columns) }
        return SQLiteRows(columns: columns, rows: rows, isTruncated: truncated)
    }

    func query(_ sql: String, values: [QueryBoundValue] = []) throws -> SQLiteRows {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_stmt_readonly(statement) != 0 else { throw DatabaseServiceError.readOnlyQueryRequired }
        return try read(statement, maximumRows: SQLiteDatabaseClient.maximumMaterializedRows)
    }

    func control(_ sql: String) throws {
        try operation.check()
        authorization.internalTransaction = true
        defer { authorization.internalTransaction = false }
        try rawControl(sql)
    }

    func rollback() {
        authorization.internalTransaction = true
        defer { authorization.internalTransaction = false }
        // Disable an expired/cancelled progress callback while rolling back; closing is the final fallback.
        sqlite3_progress_handler(handle, 0, nil, nil)
        _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
    }

    private func rawControl(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(code) }
    }

    func error(_ code: Int32) -> Error {
        do { try operation.check() } catch { return error }
        if let denial = authorization.denial {
            if case .write = denial {
                if profileReadOnly { return DatabaseServiceError.readOnlyViolation }
                if policy.requiresReadOnlySession { return DatabaseServiceError.readOnlyQueryRequired }
                return DatabaseServiceError.unsafeQueryRequiresConfirmation
            }
            if denial == .temporary { return SQLiteClientError.temporaryObjectsUnavailable }
            return denial == .transaction ? SQLiteClientError.transactionControlsUnavailable : SQLiteClientError.unsafeOperation
        }
        return SQLiteClientError.database(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    static func cell(_ statement: OpaquePointer, index: Int32, declaredType: String) -> QueryCell {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER:
            let value = sqlite3_column_int64(statement, index)
            if declaredType.uppercased().contains("BOOL"), value == 0 || value == 1 { return .boolean(value == 1) }
            return .integer(String(value))
        case SQLITE_FLOAT: return .decimal(String(sqlite3_column_double(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .binary(Data()) }
            return .binary(Data(bytes: bytes, count: count))
        default:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_text(statement, index) else { return .text("") }
            let data = Data(bytes: bytes, count: count)
            guard let value = String(data: data, encoding: .utf8) else { return .binary(data) }
            let type = declaredType.uppercased()
            if type.contains("DATE") || type.contains("TIME") { return .dateTime(value) }
            if type.contains("JSON") { return .json(value) }
            return .text(value)
        }
    }

    private static func storageType(_ type: Int32) -> String {
        switch type { case SQLITE_INTEGER: "INTEGER"; case SQLITE_FLOAT: "REAL"; case SQLITE_TEXT: "TEXT"; case SQLITE_BLOB: "BLOB"; default: "ANY" }
    }
}

private final class SQLiteAuthorization {
    enum Denial: Equatable { case write, transaction, temporary, unsafe }
    let readOnly: Bool
    var internalTransaction = false
    var denial: Denial?
    private static let metadataPragmas: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo", "foreign_key_list",
        "foreign_key_check", "database_list", "compile_options", "collation_list", "function_list", "module_list",
        "integrity_check", "quick_check"
    ]

    init(readOnly: Bool) { self.readOnly = readOnly }

    func authorize(_ action: Int32, first: String?, second: String?) -> Int32 {
        switch action {
        case SQLITE_ATTACH, SQLITE_DETACH:
            denial = .unsafe; return SQLITE_DENY
        case SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
            if !internalTransaction { denial = .transaction; return SQLITE_DENY }
        case SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW:
            denial = .temporary; return SQLITE_DENY
        case SQLITE_PRAGMA:
            if !Self.metadataPragmas.contains(first?.lowercased() ?? "") { denial = .unsafe; return SQLITE_DENY }
        case SQLITE_FUNCTION:
            let name = (second ?? first ?? "").lowercased()
            if ["load_extension", "readfile", "writefile", "eval", "edit", "fts3_tokenizer"].contains(name)
                || (name.hasPrefix("pragma_") && !Self.metadataPragmas.contains(String(name.dropFirst(7)))) {
                denial = .unsafe; return SQLITE_DENY
            }
        case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: break
        default:
            if readOnly { denial = .write; return SQLITE_DENY }
        }
        return SQLITE_OK
    }
}
