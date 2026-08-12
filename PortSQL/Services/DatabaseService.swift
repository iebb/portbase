import Foundation
import Darwin

#if canImport(Charts)
import Charts
#endif

#if canImport(MySQLNIO)
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
#endif

#if canImport(PostgresNIO)
import PostgresNIO
#endif

private func withQueryTimeout<Value: Sendable>(
    seconds: Int,
    closeConnection: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try Task.checkCancellation()
                return try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                closeConnection()
                throw DatabaseServiceError.queryTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    } onCancel: {
        closeConnection()
    }
}

#if canImport(MySQLNIO)
private final class MySQLExecutionMetadata: @unchecked Sendable {
    private let lock = NSLock()
    private var storedColumns: [MySQLProtocol.ColumnDefinition41]?
    private var storedAffectedRows: Int?
    private var storedRows: [MySQLRow] = []
    private var sawAdditionalRows = false

    var columns: [MySQLProtocol.ColumnDefinition41]? {
        lock.withLock { storedColumns }
    }

    var affectedRows: Int? {
        lock.withLock { storedAffectedRows }
    }

    var rows: [MySQLRow] {
        lock.withLock { storedRows }
    }

    var isTruncated: Bool {
        lock.withLock { sawAdditionalRows }
    }

    func setColumns(_ columns: [MySQLProtocol.ColumnDefinition41]) {
        lock.withLock { storedColumns = columns }
    }

    func setAffectedRows(_ affectedRows: Int) {
        lock.withLock { storedAffectedRows = affectedRows }
    }

    func append(_ row: MySQLRow, maximumRows: Int) {
        lock.withLock {
            if storedRows.count < maximumRows {
                storedRows.append(row)
            } else {
                sawAdditionalRows = true
            }
        }
    }
}
#endif

#if canImport(PostgresNIO)
private struct PostgresExecutionOutput: @unchecked Sendable {
    let columns: [QueryColumn]
    let rows: [QueryRow]
    let affectedRows: Int?
    let isTruncated: Bool
}

private struct PostgresUnknownText: PostgresDynamicTypeEncodable, Sendable {
    let value: String
    var psqlType: PostgresDataType { .unknown }
    var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(value)
    }
}

private final class PostgresExecutionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumRows: Int
    private var storedRows: [PostgresRow] = []
    private var storedMetadata: PostgresQueryMetadata?
    private var sawAdditionalRows = false

    init(maximumRows: Int) {
        self.maximumRows = maximumRows
    }

    func append(_ row: PostgresRow) {
        lock.withLock {
            if storedRows.count < maximumRows {
                storedRows.append(row)
            } else {
                sawAdditionalRows = true
            }
        }
    }

    func setMetadata(_ metadata: PostgresQueryMetadata) {
        lock.withLock { storedMetadata = metadata }
    }

    var snapshot: (rows: [PostgresRow], metadata: PostgresQueryMetadata?, isTruncated: Bool) {
        lock.withLock { (storedRows, storedMetadata, sawAdditionalRows) }
    }
}
#endif

enum DatabaseServiceError: LocalizedError {
    case unsupported
    case notConfigured
    case readOnlyViolation
    case unsafeQueryRequiresConfirmation
    case readOnlyQueryRequired
    case queryTimedOut
    case invalidSchemaDefinition
    case mysqlColumnEditRequiresCompleteMetadata
    case tlsIdentityUnavailableThroughTunnel
    case privateCACertificateMissing
    case privateCACertificateInvalid
    case privateCACertificateTooLarge
    case unexpectedAffectedRowCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "The requested database driver is unavailable in this build."
        case .notConfigured:
            "Select or create a bookmark before running a query."
        case .readOnlyViolation:
            "This connection is read-only and cannot execute write or schema statements."
        case .unsafeQueryRequiresConfirmation:
            "This statement requires explicit confirmation before it can run."
        case .readOnlyQueryRequired:
            "This operation only accepts read-only SQL."
        case .queryTimedOut:
            "The database query timed out and its connection was closed."
        case .invalidSchemaDefinition:
            "The column type contains unsupported or unsafe SQL syntax."
        case .mysqlColumnEditRequiresCompleteMetadata:
            "MySQL column editing is disabled because PortSQL cannot yet preserve every existing default, generated expression, comment, character set, collation, and AUTO_INCREMENT attribute. Add a new column or use reviewed SQL instead."
        case .tlsIdentityUnavailableThroughTunnel:
            "TLS through an SSH tunnel requires a DNS database hostname so the certificate identity can be verified. An IP address cannot be verified safely through the loopback tunnel."
        case .privateCACertificateMissing:
            "Private CA TLS is selected, but no CA certificate is available on this device. Import the CA certificate again."
        case .privateCACertificateInvalid:
            "The private CA must be a valid PEM certificate bundle and must not contain a private key."
        case .privateCACertificateTooLarge:
            "The private CA certificate bundle is too large."
        case .unexpectedAffectedRowCount(let expected, let actual):
            actual < 0
                ? "Expected to affect \(expected) row(s), but the database did not report an affected-row count. The result cannot be verified safely."
                : "Expected to affect \(expected) row(s), but the database reported \(actual). The row may have changed since it was loaded."
        }
    }
}

enum DatabaseExecutionPolicy: Sendable {
    case userQuery(confirmed: Bool)
    case readOnly
    case mutation(expectedAffectedRows: Int? = nil)
}

private extension DatabaseExecutionPolicy {
    var requiresReadOnlySession: Bool {
        if case .readOnly = self { return true }
        return false
    }
}

struct SchemaMutationPlan: Hashable {
    let statements: [String]

    var previewSQL: String {
        statements.joined(separator: "\n")
    }
}

actor DatabaseService {
    static let shared = DatabaseService()
    private static let maximumMaterializedRows = 10_000

    #if canImport(MySQLNIO)
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    #endif

    func execute(
        query: String,
        values: [QueryBoundValue] = [],
        profile: ConnectionProfile?,
        database: String? = nil,
        policy: DatabaseExecutionPolicy = .userQuery(confirmed: false),
        timeoutSeconds: Int = 30
    ) async throws -> QueryResultTable {
        guard let profile else { throw DatabaseServiceError.notConfigured }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return QueryResultTable.empty }
        try validateExecution(query: trimmed, profile: profile, policy: policy)
        let timeout = max(1, min(timeoutSeconds, 300))

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            return try await executeMySQL(
                query: trimmed,
                values: values,
                profile: profile,
                database: database,
                policy: policy,
                timeoutSeconds: timeout
            )
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            return try await executePostgres(
                query: trimmed,
                values: values,
                profile: profile,
                database: database,
                policy: policy,
                timeoutSeconds: timeout
            )
            #else
            throw DatabaseServiceError.unsupported
            #endif
        }
    }

    private func validateExecution(
        query: String,
        profile: ConnectionProfile,
        policy: DatabaseExecutionPolicy
    ) throws {
        let isReadOnlySQL = SQLSafetyService.isReadOnlySQL(query, engine: profile.engine)
        if profile.isReadOnly, !isReadOnlySQL {
            throw DatabaseServiceError.readOnlyViolation
        }
        switch policy {
        case .readOnly:
            guard isReadOnlySQL else { throw DatabaseServiceError.readOnlyQueryRequired }
        case .mutation:
            guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        case .userQuery(let confirmed):
            if let assessment = SQLSafetyService.assessment(
                for: query,
                readOnly: profile.isReadOnly,
                engine: profile.engine
            ) {
                if assessment.blocksExecution { throw DatabaseServiceError.readOnlyViolation }
                if assessment.requiresConfirmation, !confirmed {
                    throw DatabaseServiceError.unsafeQueryRequiresConfirmation
                }
            }
        }
    }

    private func expectedAffectedRows(for policy: DatabaseExecutionPolicy) -> Int? {
        guard case .mutation(let expected) = policy else { return nil }
        return expected
    }

    private func validateAffectedRows(_ actual: Int?, policy: DatabaseExecutionPolicy) throws {
        guard let expected = expectedAffectedRows(for: policy) else { return }
        guard let actual else {
            throw DatabaseServiceError.unexpectedAffectedRowCount(expected: expected, actual: -1)
        }
        guard expected != actual else { return }
        throw DatabaseServiceError.unexpectedAffectedRowCount(expected: expected, actual: actual)
    }

    nonisolated static func schemaColumnChangePlan(
        for draft: SchemaColumnDraft,
        engine: DatabaseEngine
    ) throws -> SchemaMutationPlan {
        guard isSafeSchemaType(draft.type) else { throw DatabaseServiceError.invalidSchemaDefinition }
        switch engine {
        case .mysql:
            guard draft.mode == .add else {
                throw DatabaseServiceError.mysqlColumnEditRequiresCompleteMetadata
            }
            let tableName = qualifiedTable(draft.table, engine: engine)
            let nullability = draft.isNullable ? "NULL" : "NOT NULL"
            return SchemaMutationPlan(statements: ["""
            ALTER TABLE \(tableName)
            ADD COLUMN \(identifier(draft.name, engine: engine)) \(draft.type) \(nullability);
            """])
        case .postgresql:
            let tableName = qualifiedTable(draft.table, engine: engine)
            let targetName = identifier(draft.name, engine: engine)
            var statements: [String] = []
            switch draft.mode {
            case .add:
                statements.append("""
                ALTER TABLE \(tableName)
                ADD COLUMN \(targetName) \(draft.type);
                """)
            case .edit:
                if let originalName = draft.originalName, originalName != draft.name {
                    statements.append("""
                    ALTER TABLE \(tableName)
                    RENAME COLUMN \(identifier(originalName, engine: engine)) TO \(targetName);
                    """)
                }
            }
            statements.append("""
            ALTER TABLE \(tableName)
            ALTER COLUMN \(targetName) TYPE \(draft.type);
            """)
            statements.append("""
            ALTER TABLE \(tableName)
            ALTER COLUMN \(targetName) \(draft.isNullable ? "DROP NOT NULL" : "SET NOT NULL");
            """)
            return SchemaMutationPlan(statements: statements)
        }
    }

    nonisolated static func dropColumnPlan(
        _ column: SchemaColumnDescriptor,
        from table: SchemaTableDescriptor,
        engine: DatabaseEngine
    ) -> SchemaMutationPlan {
        SchemaMutationPlan(statements: ["""
        ALTER TABLE \(qualifiedTable(table, engine: engine))
        DROP COLUMN \(identifier(column.name, engine: engine));
        """])
    }

    nonisolated private static func qualifiedTable(
        _ table: SchemaTableDescriptor,
        engine: DatabaseEngine
    ) -> String {
        let tableName = identifier(table.name, engine: engine)
        guard !table.schemaName.isEmpty else { return tableName }
        return "\(identifier(table.schemaName, engine: engine)).\(tableName)"
    }

    nonisolated private static func identifier(_ value: String, engine: DatabaseEngine) -> String {
        switch engine {
        case .mysql:
            return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
        case .postgresql:
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    func loadSchema(profile: ConnectionProfile?, database: String? = nil) async throws -> [SchemaTableDescriptor] {
        guard let profile else { return [] }

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            return try await loadMySQLSchema(profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            return try await loadPostgresSchema(profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        }
    }

    func listDatabases(profile: ConnectionProfile?) async throws -> [String] {
        guard let profile else { return [] }

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            return try await listMySQLDatabases(profile: profile)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            return try await listPostgresDatabases(profile: profile)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        }
    }

    func applySchemaColumnChange(
        _ draft: SchemaColumnDraft,
        profile: ConnectionProfile?,
        database: String? = nil
    ) async throws {
        guard let profile else { throw DatabaseServiceError.notConfigured }
        guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        guard Self.isSafeSchemaType(draft.type) else { throw DatabaseServiceError.invalidSchemaDefinition }

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            try await applyMySQLSchemaColumnChange(draft, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            try await applyPostgresSchemaColumnChange(draft, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        }
    }

    func dropSchemaColumn(
        _ column: SchemaColumnDescriptor,
        from table: SchemaTableDescriptor,
        profile: ConnectionProfile?,
        database: String? = nil
    ) async throws {
        guard let profile else { throw DatabaseServiceError.notConfigured }
        guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            try await dropMySQLSchemaColumn(column, from: table, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            try await dropPostgresSchemaColumn(column, from: table, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        }
    }

    #if canImport(MySQLNIO)
    private func executeMySQL(
        query: String,
        values: [QueryBoundValue],
        profile: ConnectionProfile,
        database: String?,
        policy: DatabaseExecutionPolicy,
        timeoutSeconds: Int
    ) async throws -> QueryResultTable {
        let connection = try await connectMySQL(
            profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase),
            loggerLabel: "ad.neko.portsql.mysql"
        )
        do {
            try await configureMySQLSession(connection, profile: profile, policy: policy)
            let validatesMutation = expectedAffectedRows(for: policy) != nil
            if validatesMutation {
                _ = try await connection.simpleQuery("START TRANSACTION").get()
            }
            let metadata = MySQLExecutionMetadata()
            let future = connection.query(
                query,
                values.map(Self.mysqlBind),
                onColumns: { metadata.setColumns($0) },
                onRow: { metadata.append($0, maximumRows: Self.maximumMaterializedRows) },
                onMetadata: { metadata.setAffectedRows(Int(clamping: $0.affectedRows)) }
            )
            try await withQueryTimeout(
                seconds: timeoutSeconds,
                closeConnection: { _ = connection.close() },
                operation: { try await future.get() }
            )
            let rows = metadata.rows
            let definitions = metadata.columns ?? rows.first?.columnDefinitions ?? []
            let columns = definitions.map { QueryColumn(name: $0.name, type: "\($0.columnType)") }
            let mappedRows = rows.map { row in
                QueryRow(cells: row.columnDefinitions.indices.map { index in
                    let definition = row.columnDefinitions[index]
                    let data = MySQLData(
                        type: definition.columnType,
                        format: row.format,
                        buffer: row.values[index],
                        isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
                    )
                    return Self.cell(mysql: data, definition: definition)
                })
            }
            let affectedRows = metadata.affectedRows
            try validateAffectedRows(affectedRows, policy: policy)
            if validatesMutation {
                _ = try await connection.simpleQuery("COMMIT").get()
            }
            let summary: String
            if !columns.isEmpty {
                summary = metadata.isTruncated
                    ? L10n.format("Showing the first %@ from %@; additional rows were truncated.", L10n.plural("row_count", count: rows.count), profile.name)
                    : L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: rows.count), profile.name)
            } else if let affectedRows {
                summary = L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: affectedRows))
            } else {
                summary = "Statement executed successfully."
            }
            try await connection.close().get()
            return QueryResultTable(
                columns: columns,
                rows: mappedRows,
                executionSummary: summary,
                generatedMutation: nil,
                profiles: Self.makeProfiles(columns: columns, rows: mappedRows),
                sourceTableReference: nil,
                affectedRowCount: affectedRows,
                isTruncated: metadata.isTruncated
            )
        } catch {
            if expectedAffectedRows(for: policy) != nil {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
            }
            try? await connection.close().get()
            throw error
        }
    }

    private func loadMySQLSchema(profile: ConnectionProfile, database: String?) async throws -> [SchemaTableDescriptor] {
        guard let selectedDatabase = resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase) else {
            return []
        }

        let connection = try await connectMySQL(profile: profile, database: nil, loggerLabel: "ad.neko.portsql.mysql.schema")
        do {
            let rows = try await connection.query("""
            SELECT
                columns.TABLE_NAME,
                columns.COLUMN_NAME,
                columns.DATA_TYPE,
                columns.IS_NULLABLE,
                columns.COLUMN_KEY,
                tables.TABLE_ROWS
            FROM INFORMATION_SCHEMA.COLUMNS AS columns
            LEFT JOIN INFORMATION_SCHEMA.TABLES AS tables
                ON tables.TABLE_SCHEMA = columns.TABLE_SCHEMA
               AND tables.TABLE_NAME = columns.TABLE_NAME
            WHERE columns.TABLE_SCHEMA = ?
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """, [MySQLData(string: selectedDatabase)]).get()

            let grouped = Dictionary(grouping: rows) { row in
                row.column("TABLE_NAME")?.string ?? ""
            }

            let catalog = grouped.keys.sorted().map { tableName in
                let tableRows = grouped[tableName]?.first
                let rowCountEstimate = Self.mysqlInteger(tableRows?.column("TABLE_ROWS"))
                let columns = (grouped[tableName] ?? []).map { row in
                    SchemaColumnDescriptor(
                        name: row.column("COLUMN_NAME")?.string ?? "",
                        type: row.column("DATA_TYPE")?.string ?? "",
                        isNullable: (row.column("IS_NULLABLE")?.string ?? "YES") == "YES",
                        isPrimaryKey: (row.column("COLUMN_KEY")?.string ?? "") == "PRI",
                        isUnique: (row.column("COLUMN_KEY")?.string ?? "") == "UNI"
                    )
                }
                return SchemaTableDescriptor(
                    schemaName: selectedDatabase,
                    name: tableName,
                    columns: columns,
                    rowCountEstimate: rowCountEstimate
                )
            }
            try await connection.close().get()
            return catalog
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func listMySQLDatabases(profile: ConnectionProfile) async throws -> [String] {
        let connection = try await connectMySQL(profile: profile, database: nil, loggerLabel: "ad.neko.portsql.mysql.databases")
        do {
            let rows = try await connection.simpleQuery("SHOW DATABASES").get()
            try await connection.close().get()
            let ignored = Set(["information_schema", "mysql", "performance_schema", "sys"])
            return rows
                .compactMap { row in
                    row.column("Database")?.string ?? row.column("database")?.string
                }
                .filter { !ignored.contains($0.lowercased()) }
                .sorted()
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func connectMySQL(profile: ConnectionProfile, database: String?, loggerLabel: String) async throws -> MySQLConnection {
        switch profile.transportSecurityMode {
        case .systemCA, .privateCA, .preferTLS:
            return try await openMySQLConnection(
                profile: profile,
                database: database,
                tlsConfiguration: try Self.tlsConfiguration(for: profile),
                allowPlaintextFallback: profile.transportSecurityMode == .preferTLS,
                loggerLabel: loggerLabel
            )
        case .plaintext:
            return try await openMySQLConnection(
                profile: profile,
                database: database,
                tlsConfiguration: nil,
                allowPlaintextFallback: false,
                loggerLabel: loggerLabel
            )
        }
    }

    private func openMySQLConnection(
        profile: ConnectionProfile,
        database: String?,
        tlsConfiguration: TLSConfiguration?,
        allowPlaintextFallback: Bool,
        loggerLabel: String
    ) async throws -> MySQLConnection {
        if tlsConfiguration != nil, profile.usesSSHTunnel, Self.isIPAddress(profile.host) {
            throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
        }
        let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
        let address = try SocketAddress.makeAddressResolvingHost(endpoint.host, port: endpoint.port)
        let serverHostname = Self.isIPAddress(endpoint.serverHostname) ? nil : endpoint.serverHostname
        let connection = try await MySQLConnection.connect(
            to: address,
            username: profile.username,
            database: "",
            password: profile.password.isEmpty ? nil : profile.password,
            tlsConfiguration: tlsConfiguration,
            allowPlaintextFallback: allowPlaintextFallback,
            serverHostname: serverHostname,
            logger: Logger(label: loggerLabel),
            on: eventLoopGroup.next()
        ).get()
        do {
            try await prepareMySQLSession(connection, database: database ?? "")
            return connection
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func prepareMySQLSession(_ connection: MySQLConnection, database: String) async throws {
        let trimmedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDatabase.isEmpty else { return }
        let escapedDatabase = trimmedDatabase.replacingOccurrences(of: "`", with: "``")
        _ = try await connection.simpleQuery("USE `\(escapedDatabase)`").get()
    }

    private func configureMySQLSession(
        _ connection: MySQLConnection,
        profile: ConnectionProfile,
        policy: DatabaseExecutionPolicy
    ) async throws {
        guard profile.isReadOnly || policy.requiresReadOnlySession else { return }
        _ = try await connection.simpleQuery("SET SESSION TRANSACTION READ ONLY").get()
    }

    private func applyMySQLSchemaColumnChange(
        _ draft: SchemaColumnDraft,
        profile: ConnectionProfile,
        database: String?
    ) async throws {
        guard draft.mode == .add else {
            throw DatabaseServiceError.mysqlColumnEditRequiresCompleteMetadata
        }
        let connection = try await connectMySQL(
            profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase),
            loggerLabel: "ad.neko.portsql.mysql.schema.ddl"
        )
        do {
            let plan = try Self.schemaColumnChangePlan(for: draft, engine: .mysql)
            for statement in plan.statements {
                _ = try await connection.simpleQuery(statement).get()
            }
            try await connection.close().get()
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func dropMySQLSchemaColumn(
        _ column: SchemaColumnDescriptor,
        from table: SchemaTableDescriptor,
        profile: ConnectionProfile,
        database: String?
    ) async throws {
        let connection = try await connectMySQL(
            profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase),
            loggerLabel: "ad.neko.portsql.mysql.schema.drop"
        )
        do {
            let statement = Self.dropColumnPlan(column, from: table, engine: .mysql).statements[0]
            _ = try await connection.simpleQuery(statement).get()
            try await connection.close().get()
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private static func mysqlBind(_ value: QueryBoundValue) -> MySQLData {
        switch value {
        case .null:
            return .null
        case .string(let value):
            return MySQLData(string: value)
        case .integer(let value):
            return MySQLData(int: Int(value))
        case .decimal(let value):
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
                .map(MySQLData.init(decimal:)) ?? MySQLData(string: value)
        case .boolean(let value):
            return MySQLData(bool: value)
        }
    }

    private static func cell(
        mysql data: MySQLData,
        definition: MySQLProtocol.ColumnDefinition41
    ) -> QueryCell {
        guard data.buffer != nil else { return .null }
        if definition.characterSet == .binary,
           [.varchar, .varString, .string, .blob, .tinyBlob, .mediumBlob, .longBlob, .geometry]
            .contains(definition.columnType),
           let buffer = data.buffer {
            return .binary(Data(buffer.readableBytesView))
        }
        switch definition.columnType {
        case .tiny, .short, .long, .longlong, .int24, .year:
            if definition.flags.contains(.COLUMN_UNSIGNED), let value = data.uint64 {
                return .integer(String(value))
            }
            if let value = data.int64 { return .integer(String(value)) }
        case .decimal, .newdecimal:
            if let value = data.decimal {
                return .decimal(NSDecimalNumber(decimal: value).stringValue)
            }
        case .float, .double:
            if let value = data.double { return .decimal(String(value)) }
        case .bit:
            if let value = data.bool { return .boolean(value) }
        case .date, .newdate:
            if let value = data.time { return .dateTime(formatMySQLDate(value)) }
        case .time, .time2:
            if let value = data.time { return .dateTime(formatMySQLTime(value)) }
        case .datetime, .datetime2, .timestamp, .timestamp2:
            if let value = data.time { return .dateTime(formatMySQLDateTime(value)) }
        case .json:
            if let value = data.string { return .json(value) }
        default:
            break
        }
        if let value = data.string { return .text(value) }
        if let buffer = data.buffer { return .binary(Data(buffer.readableBytesView)) }
        return .text(data.description)
    }

    nonisolated static func formatMySQLDate(_ value: MySQLTime) -> String {
        String(format: "%04d-%02d-%02d", value.year ?? 0, value.month ?? 0, value.day ?? 0)
    }

    nonisolated static func formatMySQLTime(_ value: MySQLTime) -> String {
        let base = String(format: "%02d:%02d:%02d", value.hour ?? 0, value.minute ?? 0, value.second ?? 0)
        let signedBase = value.isNegative ? "-\(base)" : base
        guard let microsecond = value.microsecond, microsecond > 0 else { return signedBase }
        return signedBase + String(format: ".%06d", microsecond).trimmingTrailingZeros
    }

    nonisolated static func formatMySQLDateTime(_ value: MySQLTime) -> String {
        "\(formatMySQLDate(value)) \(formatMySQLTime(value))"
    }

    private static func mysqlInteger(_ data: MySQLData?) -> Int? {
        if let value = data?.int64 {
            return Int(value)
        }
        if let value = data?.uint64 {
            return Int(value)
        }
        if let string = data?.string, let value = Int(string) {
            return value
        }
        return nil
    }
    #endif

    #if canImport(PostgresNIO)
    private func executePostgres(
        query: String,
        values: [QueryBoundValue],
        profile: ConnectionProfile,
        database: String?,
        policy: DatabaseExecutionPolicy,
        timeoutSeconds: Int
    ) async throws -> QueryResultTable {
        let config = try await makePostgresConfiguration(
            profile: profile,
            database: postgresDatabaseName(for: profile, requested: database)
        )
        let logger = Logger(label: "ad.neko.portsql.postgres")
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: 1,
            logger: logger
        ).get()
        do {
            try await configurePostgresSession(connection, profile: profile, policy: policy)
            let validatesMutation = expectedAffectedRows(for: policy) != nil
            if validatesMutation {
                _ = try await connection.query("BEGIN").get()
            }
            let output: PostgresExecutionOutput
            if SQLSafetyService.isReadOnlySQL(query, engine: .postgresql) {
                let bindings = try Self.postgresBindings(values)
                output = try await withQueryTimeout(
                    seconds: timeoutSeconds,
                    closeConnection: { _ = (connection.close() as EventLoopFuture<Void>) },
                    operation: {
                        let sequence = try await connection.query(
                            PostgresQuery(unsafeSQL: query, binds: bindings),
                            logger: logger
                        )
                        let columns = sequence.columns.map {
                            QueryColumn(name: $0.name, type: "\($0.dataType)")
                        }
                        var rows: [QueryRow] = []
                        rows.reserveCapacity(min(Self.maximumMaterializedRows, 256))
                        var isTruncated = false
                        for try await row in sequence {
                            if rows.count < Self.maximumMaterializedRows {
                                rows.append(Self.postgresRow(row))
                            } else {
                                isTruncated = true
                                break
                            }
                        }
                        return PostgresExecutionOutput(
                            columns: columns,
                            rows: rows,
                            affectedRows: nil,
                            isTruncated: isTruncated
                        )
                    }
                )
            } else {
                let collector = PostgresExecutionCollector(maximumRows: Self.maximumMaterializedRows)
                let bindings = try Self.postgresBindings(values)
                let future = connection.query(
                    PostgresQuery(unsafeSQL: query, binds: bindings),
                    logger: logger,
                    { collector.append($0) }
                )
                let metadata = try await withQueryTimeout(
                    seconds: timeoutSeconds,
                    closeConnection: { _ = (connection.close() as EventLoopFuture<Void>) },
                    operation: { try await future.get() }
                )
                collector.setMetadata(metadata)
                let snapshot = collector.snapshot
                let columns: [QueryColumn] = snapshot.rows.first.map { row in
                    let access = row.makeRandomAccess()
                    return (0..<access.count).map { index in
                        QueryColumn(name: access[index].columnName, type: "\(access[index].dataType)")
                    }
                } ?? []
                output = PostgresExecutionOutput(
                    columns: columns,
                    rows: snapshot.rows.map(Self.postgresRow),
                    affectedRows: snapshot.metadata?.rows,
                    isTruncated: snapshot.isTruncated
                )
            }
            try validateAffectedRows(output.affectedRows, policy: policy)
            if validatesMutation {
                _ = try await connection.query("COMMIT").get()
            }
            let summary: String
            if !output.columns.isEmpty {
                summary = output.isTruncated
                    ? L10n.format("Showing the first %@ from %@; additional rows were truncated.", L10n.plural("row_count", count: output.rows.count), profile.name)
                    : L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: output.rows.count), profile.name)
            } else if let affectedRows = output.affectedRows {
                summary = L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: affectedRows))
            } else {
                summary = "Statement executed successfully."
            }
            try await connection.close()
            return QueryResultTable(
                columns: output.columns,
                rows: output.rows,
                executionSummary: summary,
                generatedMutation: nil,
                profiles: Self.makeProfiles(columns: output.columns, rows: output.rows),
                sourceTableReference: nil,
                affectedRowCount: output.affectedRows,
                isTruncated: output.isTruncated
            )
        } catch {
            if expectedAffectedRows(for: policy) != nil {
                _ = try? await connection.query("ROLLBACK").get()
            }
            try? await connection.close()
            throw error
        }
    }

    private static func postgresBindings(_ values: [QueryBoundValue]) throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: values.count)
        for value in values {
            switch value {
            case .null:
                bindings.appendNull()
            case .string(let value):
                bindings.append(PostgresUnknownText(value: value))
            case .integer(let value):
                bindings.append(value)
            case .decimal(let value):
                if let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
                    try bindings.append(decimal)
                } else {
                    bindings.append(value)
                }
            case .boolean(let value):
                bindings.append(value)
            }
        }
        return bindings
    }

    private static func postgresRow(_ row: PostgresRow) -> QueryRow {
        let access = row.makeRandomAccess()
        return QueryRow(cells: (0..<access.count).map { index in
            cell(postgres: access[data: index])
        })
    }

    private static func cell(postgres data: PostgresData) -> QueryCell {
        guard data.value != nil else { return .null }
        switch data.type {
        case .bool:
            if let value = data.bool { return .boolean(value) }
        case .int2, .int4, .int8, .oid:
            if let value = data.int64 { return .integer(String(value)) }
            if let value = data.int { return .integer(String(value)) }
        case .numeric, .money, .float4, .float8:
            if let value = data.string { return .decimal(value) }
            if let value = data.double { return .decimal(String(value)) }
        case .date:
            if let value = data.date { return .dateTime(formatUTC(value, pattern: "yyyy-MM-dd")) }
            if let value = data.string { return .dateTime(value) }
        case .timestamp, .timestamptz:
            if let value = postgresTimestampText(data) { return .dateTime(value) }
        case .time, .timetz:
            if let value = postgresTimeText(data) { return .dateTime(value) }
        case .json, .jsonb:
            if let value = postgresJSONText(data) { return .json(value) }
        case .bytea:
            if let value = data.value { return .binary(Data(value.readableBytesView)) }
        default:
            break
        }
        if let value = data.string { return .text(value) }
        if let value = data.value { return .binary(Data(value.readableBytesView)) }
        return .null
    }

    private static func postgresJSONText(_ data: PostgresData) -> String? {
        guard var value = data.value else { return nil }
        if data.type == .jsonb, data.formatCode == .binary, value.readableBytes > 0 {
            value.moveReaderIndex(forwardBy: 1)
        }
        return value.readString(length: value.readableBytes)
    }

    nonisolated static func postgresTimeText(_ data: PostgresData) -> String? {
        guard var buffer = data.value else { return nil }
        if data.formatCode == .text {
            return buffer.readString(length: buffer.readableBytes)
        }
        guard let microseconds = buffer.readInteger(as: Int64.self) else { return nil }
        let secondsInDay: Int64 = 86_400
        var totalSeconds = microseconds / 1_000_000
        totalSeconds = ((totalSeconds % secondsInDay) + secondsInDay) % secondsInDay
        let hour = totalSeconds / 3_600
        let minute = (totalSeconds % 3_600) / 60
        let second = totalSeconds % 60
        var text = String(format: "%02lld:%02lld:%02lld", hour, minute, second)
        let fraction = abs(microseconds % 1_000_000)
        if fraction > 0 {
            text += String(format: ".%06lld", fraction).trimmingTrailingZeros
        }
        if data.type == .timetz, let secondsWestOfUTC = buffer.readInteger(as: Int32.self) {
            let offset = -Int(secondsWestOfUTC)
            let sign = offset >= 0 ? "+" : "-"
            let magnitude = abs(offset)
            text += String(format: "%@%02d:%02d", sign, magnitude / 3_600, (magnitude % 3_600) / 60)
        }
        return text
    }

    nonisolated static func postgresTimestampText(_ data: PostgresData) -> String? {
        guard data.type == .timestamp || data.type == .timestamptz,
              var buffer = data.value else { return nil }
        if data.formatCode == .text {
            return buffer.readString(length: buffer.readableBytes)
        }
        guard let totalMicroseconds = buffer.readInteger(as: Int64.self) else { return nil }

        var wholeSeconds = totalMicroseconds / 1_000_000
        var microseconds = totalMicroseconds % 1_000_000
        if microseconds < 0 {
            wholeSeconds -= 1
            microseconds += 1_000_000
        }
        let postgresEpoch = Date(timeIntervalSince1970: 946_684_800)
        let date = Date(timeInterval: Double(wholeSeconds), since: postgresEpoch)
        var text = formatUTC(date, pattern: "yyyy-MM-dd HH:mm:ss")
        if microseconds > 0 {
            text += String(format: ".%06lld", microseconds).trimmingTrailingZeros
        }
        if data.type == .timestamptz {
            text += "+00:00"
        }
        return text
    }

    private static func formatUTC(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date).trimmingTrailingZerosBeforeSQLSuffix
    }

    private func configurePostgresSession(
        _ connection: PostgresConnection,
        profile: ConnectionProfile,
        policy: DatabaseExecutionPolicy
    ) async throws {
        guard profile.isReadOnly || policy.requiresReadOnlySession else { return }
        _ = try await connection.query("SET default_transaction_read_only = on").get()
    }

    private func loadPostgresSchema(profile: ConnectionProfile, database: String?) async throws -> [SchemaTableDescriptor] {
        let config = try await makePostgresConfiguration(
            profile: profile,
            database: postgresDatabaseName(for: profile, requested: database)
        )
        let logger = Logger(label: "ad.neko.portsql.postgres.schema")
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: 2,
            logger: logger
        ).get()
        do {
            let result = try await connection.query("""
            SELECT
                cols.table_schema,
                cols.table_name,
                cols.column_name,
                cols.data_type,
                cols.is_nullable,
                COALESCE(pk.is_primary_key, false) AS is_primary_key,
                COALESCE(uniq.is_unique, false) AS is_unique,
                stats.row_estimate
            FROM information_schema.columns AS cols
            LEFT JOIN (
                SELECT
                    kcu.table_schema,
                    kcu.table_name,
                    kcu.column_name,
                    TRUE AS is_primary_key
                FROM information_schema.table_constraints AS tc
                INNER JOIN information_schema.key_column_usage AS kcu
                    ON tc.constraint_name = kcu.constraint_name
                   AND tc.table_schema = kcu.table_schema
                   AND tc.table_name = kcu.table_name
                WHERE tc.constraint_type = 'PRIMARY KEY'
            ) AS pk
                ON pk.table_schema = cols.table_schema
               AND pk.table_name = cols.table_name
               AND pk.column_name = cols.column_name
            LEFT JOIN (
                SELECT
                    kcu.table_schema,
                    kcu.table_name,
                    kcu.column_name,
                    TRUE AS is_unique
                FROM information_schema.table_constraints AS tc
                INNER JOIN information_schema.key_column_usage AS kcu
                    ON tc.constraint_name = kcu.constraint_name
                   AND tc.table_schema = kcu.table_schema
                   AND tc.table_name = kcu.table_name
                WHERE tc.constraint_type = 'UNIQUE'
            ) AS uniq
                ON uniq.table_schema = cols.table_schema
               AND uniq.table_name = cols.table_name
               AND uniq.column_name = cols.column_name
            LEFT JOIN (
                SELECT
                    namespaces.nspname AS table_schema,
                    classes.relname AS table_name,
                    GREATEST(classes.reltuples::bigint, 0) AS row_estimate
                FROM pg_class AS classes
                INNER JOIN pg_namespace AS namespaces
                    ON namespaces.oid = classes.relnamespace
                WHERE classes.relkind IN ('r', 'p')
            ) AS stats
                ON stats.table_schema = cols.table_schema
               AND stats.table_name = cols.table_name
            WHERE cols.table_schema NOT IN ('information_schema', 'pg_catalog')
            ORDER BY cols.table_schema, cols.table_name, cols.ordinal_position
            """).get()

            var tableMap: [String: (schema: String, name: String, columns: [SchemaColumnDescriptor])] = [:]
            var rowEstimates: [String: Int?] = [:]
            for row in result.rows {
                let access = row.makeRandomAccess()
                let schemaName = access[data: "table_schema"].string ?? ""
                let tableName = access[data: "table_name"].string ?? ""
                let key = "\(schemaName).\(tableName)"
                let column = SchemaColumnDescriptor(
                    name: access[data: "column_name"].string ?? "",
                    type: access[data: "data_type"].string ?? "",
                    isNullable: (access[data: "is_nullable"].string ?? "YES") == "YES",
                    isPrimaryKey: access[data: "is_primary_key"].bool ?? false,
                    isUnique: access[data: "is_unique"].bool ?? false
                )
                if tableMap[key] == nil {
                    tableMap[key] = (schema: schemaName, name: tableName, columns: [])
                }
                tableMap[key]?.columns.append(column)
                rowEstimates[key] = Self.postgresInteger(access[data: "row_estimate"])
            }

            let catalog = tableMap.values
                .sorted { lhs, rhs in
                    if lhs.schema == rhs.schema { return lhs.name < rhs.name }
                    return lhs.schema < rhs.schema
                }
                .map {
                    let key = "\($0.schema).\($0.name)"
                    return SchemaTableDescriptor(
                        schemaName: $0.schema,
                        name: $0.name,
                        columns: $0.columns,
                        rowCountEstimate: rowEstimates[key] ?? nil
                    )
                }
            try await connection.close()
            return catalog
        } catch {
            try? await connection.close()
            throw error
        }
    }

    private func listPostgresDatabases(profile: ConnectionProfile) async throws -> [String] {
        let config = try await makePostgresConfiguration(
            profile: profile,
            database: postgresBootstrapDatabase(for: profile)
        )
        let logger = Logger(label: "ad.neko.portsql.postgres.databases")
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: 3,
            logger: logger
        ).get()
        do {
            let result = try await connection.query("""
            SELECT datname
            FROM pg_database
            WHERE datistemplate = false
            ORDER BY datname
            """).get()
            try await connection.close()
            return result.rows.compactMap { row in
                row.makeRandomAccess()[data: "datname"].string
            }
        } catch {
            try? await connection.close()
            throw error
        }
    }

    private static func postgresInteger(_ data: PostgresData) -> Int? {
        if let value = data.int {
            return value
        }
        if let value = data.int64 {
            return Int(value)
        }
        if let value = data.string, let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    private func applyPostgresSchemaColumnChange(
        _ draft: SchemaColumnDraft,
        profile: ConnectionProfile,
        database: String?
    ) async throws {
        let connection = try await connectPostgres(
            profile: profile,
            database: database,
            id: 4,
            loggerLabel: "ad.neko.portsql.postgres.schema.ddl"
        )
        do {
            let statements = try Self.schemaColumnChangePlan(for: draft, engine: .postgresql).statements
            _ = try await connection.query("BEGIN").get()
            for statement in statements {
                _ = try await connection.query(statement).get()
            }
            _ = try await connection.query("COMMIT").get()
            try await connection.close()
        } catch {
            _ = try? await connection.query("ROLLBACK").get()
            try? await connection.close()
            throw error
        }
    }

    private func dropPostgresSchemaColumn(
        _ column: SchemaColumnDescriptor,
        from table: SchemaTableDescriptor,
        profile: ConnectionProfile,
        database: String?
    ) async throws {
        let connection = try await connectPostgres(
            profile: profile,
            database: database,
            id: 5,
            loggerLabel: "ad.neko.portsql.postgres.schema.drop"
        )
        do {
            let statement = Self.dropColumnPlan(column, from: table, engine: .postgresql).statements[0]
            _ = try await connection.query("BEGIN").get()
            _ = try await connection.query(statement).get()
            _ = try await connection.query("COMMIT").get()
            try await connection.close()
        } catch {
            _ = try? await connection.query("ROLLBACK").get()
            try? await connection.close()
            throw error
        }
    }

    private func connectPostgres(
        profile: ConnectionProfile,
        database: String?,
        id: Int,
        loggerLabel: String
    ) async throws -> PostgresConnection {
        let config = try await makePostgresConfiguration(
            profile: profile,
            database: postgresDatabaseName(for: profile, requested: database)
        )
        let logger = Logger(label: loggerLabel)
        return try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: id,
            logger: logger
        ).get()
    }

    private func makePostgresConfiguration(
        profile: ConnectionProfile,
        database: String
    ) async throws -> PostgresConnection.Configuration {
        if profile.transportSecurityMode != .plaintext, profile.usesSSHTunnel, Self.isIPAddress(profile.host) {
            throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
        }
        let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
        let tlsConfiguration = try Self.tlsConfiguration(for: profile)
        let postgresTLS: PostgresConnection.Configuration.TLS
        switch profile.transportSecurityMode {
        case .systemCA, .privateCA:
            postgresTLS = .require(try NIOSSLContext(configuration: tlsConfiguration))
        case .preferTLS:
            postgresTLS = .prefer(try NIOSSLContext(configuration: tlsConfiguration))
        case .plaintext:
            postgresTLS = .disable
        }
        var config = PostgresConnection.Configuration(
            host: endpoint.host,
            port: endpoint.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: database,
            tls: postgresTLS
        )
        config.options.tlsServerName = Self.isIPAddress(endpoint.serverHostname) ? nil : endpoint.serverHostname
        return config
    }

    #endif

    nonisolated static func tlsConfiguration(for profile: ConnectionProfile) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        configuration.trustRoots = .default

        guard profile.transportSecurityMode == .privateCA else { return configuration }
        let pem = profile.privateCACertificate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pem.isEmpty, pem != "<keychain>" else {
            throw DatabaseServiceError.privateCACertificateMissing
        }
        guard pem.utf8.count <= 1_048_576 else {
            throw DatabaseServiceError.privateCACertificateTooLarge
        }
        let uppercased = pem.uppercased()
        guard !uppercased.contains("PRIVATE KEY"), uppercased.contains("BEGIN CERTIFICATE") else {
            throw DatabaseServiceError.privateCACertificateInvalid
        }
        do {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Array(pem.utf8))
            guard !certificates.isEmpty else { throw DatabaseServiceError.privateCACertificateInvalid }
            configuration.additionalTrustRoots = [.certificates(certificates)]
            return configuration
        } catch let error as DatabaseServiceError {
            throw error
        } catch {
            throw DatabaseServiceError.privateCACertificateInvalid
        }
    }

    private func resolvedDatabaseName(_ requested: String?, fallback: String) -> String? {
        let requestedName = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requestedName.isEmpty {
            return requestedName
        }

        let fallbackName = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? nil : fallbackName
    }

    private func postgresDatabaseName(for profile: ConnectionProfile, requested: String?) -> String {
        resolvedDatabaseName(requested, fallback: profile.trimmedDefaultDatabase)
            ?? postgresBootstrapDatabase(for: profile)
    }

    private func postgresBootstrapDatabase(for profile: ConnectionProfile) -> String {
        let fallback = profile.trimmedDefaultDatabase
        return fallback.isEmpty ? "postgres" : fallback
    }

    nonisolated static func isSafeSchemaType(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(";"),
              !trimmed.contains("--"),
              !trimmed.contains("/*"),
              !trimmed.contains("*/"),
              !trimmed.contains("\0") else {
            return false
        }

        var depth = 0
        var quote: Character?
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            let nextIndex = trimmed.index(after: index)
            let next = nextIndex < trimmed.endIndex ? trimmed[nextIndex] : nil
            if let activeQuote = quote {
                if character == activeQuote {
                    if next == activeQuote {
                        index = trimmed.index(after: nextIndex)
                        continue
                    }
                    quote = nil
                }
                index = nextIndex
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            } else if character == "," {
                if depth == 0 { return false }
            } else if !(character.isLetter || character.isNumber || character.isWhitespace
                        || "_ .[]+-".contains(character)) {
                return false
            }
            index = nextIndex
        }
        return quote == nil && depth == 0
    }

    nonisolated static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}

extension DatabaseService {
    nonisolated static func makeProfiles(columns: [QueryColumn], rows: [QueryRow]) -> [QueryColumnProfile] {
        columns.mapProfileRows(rows)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension Array where Element == QueryColumn {
    func mapProfileRows(_ rows: [QueryRow]) -> [QueryColumnProfile] {
        enumerated().map { index, column in
            let cells = rows.map { $0.cells[safe: index] ?? .null }
            let nullCount = cells.filter(\.isNull).count
            let distinct = Set(cells).count
            let numericSeries = cells.enumerated().compactMap { offset, cell -> NumericSeriesPoint? in
                guard !cell.isNull, let number = Double(cell.displayValue) else { return nil }
                return NumericSeriesPoint(label: rows[offset].values.first ?? "#\(offset + 1)", value: number)
            }
            return QueryColumnProfile(
                columnName: column.name,
                rowCount: rows.count,
                nullCount: nullCount,
                distinctCount: distinct,
                numericSeries: numericSeries
            )
        }
    }
}

private extension String {
    var trimmingTrailingZeros: String {
        var value = self
        while value.last == "0" { value.removeLast() }
        return value
    }

    var trimmingTrailingZerosBeforeSQLSuffix: String {
        guard contains(".") else { return self }
        var value = self
        while value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return value
    }
}
