import Foundation

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

enum DatabaseServiceError: LocalizedError {
    case unsupported
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "The requested database driver is unavailable in this build."
        case .notConfigured:
            "Select or create a bookmark before running a query."
        }
    }
}

actor DatabaseService {
    static let shared = DatabaseService()

    #if canImport(MySQLNIO)
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    #endif

    func execute(query: String, profile: ConnectionProfile?, database: String? = nil) async throws -> QueryResultTable {
        guard let profile else { throw DatabaseServiceError.notConfigured }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return QueryResultTable.empty }

        switch profile.engine {
        case .mysql:
            #if canImport(MySQLNIO)
            return try await executeMySQL(query: trimmed, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
        case .postgresql:
            #if canImport(PostgresNIO)
            return try await executePostgres(query: trimmed, profile: profile, database: database)
            #else
            throw DatabaseServiceError.unsupported
            #endif
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
    private func executeMySQL(query: String, profile: ConnectionProfile, database: String?) async throws -> QueryResultTable {
        let connection = try await connectMySQL(
            profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase),
            loggerLabel: "ad.neko.portsql.mysql"
        )
        do {
            let rows = try await connection.simpleQuery(query).get()
            let columns = rows.first?.columnDefinitions.map { QueryColumn(name: $0.name, type: "\($0.columnType)") } ?? []
            let mappedRows = rows.map { row in
                QueryRow(values: columns.map { column in
                    let data = row.column(column.name)
                    return Self.render(mysql: data)
                })
            }
            let summary = rows.isEmpty ? "Statement executed successfully." : "Fetched \(rows.count) rows from \(profile.name)."
            try await connection.close().get()
            return QueryResultTable(
                columns: columns,
                rows: mappedRows,
                executionSummary: summary,
                generatedMutation: nil,
                profiles: Self.makeProfiles(columns: columns, rows: mappedRows),
                sourceTableReference: nil
            )
        } catch {
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
            let schemaName = selectedDatabase.sqlSingleQuoted
            let rows = try await connection.simpleQuery("""
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
            WHERE columns.TABLE_SCHEMA = '\(schemaName)'
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """).get()

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
        if profile.usesTLS {
            do {
                return try await openMySQLConnection(
                    profile: profile,
                    database: database,
                    tlsConfiguration: makeMySQLTLSConfiguration(certificateVerification: .fullVerification),
                    loggerLabel: loggerLabel
                )
            } catch {
                guard shouldRetryMySQLWithRelaxedTLS(error) else {
                    throw error
                }
                return try await openMySQLConnection(
                    profile: profile,
                    database: database,
                    tlsConfiguration: makeMySQLTLSConfiguration(certificateVerification: .none),
                    loggerLabel: loggerLabel + ".insecureTLS"
                )
            }
        }

        return try await openMySQLConnection(profile: profile, database: database, tlsConfiguration: nil, loggerLabel: loggerLabel)
    }

    private func openMySQLConnection(
        profile: ConnectionProfile,
        database: String?,
        tlsConfiguration: TLSConfiguration?,
        loggerLabel: String
    ) async throws -> MySQLConnection {
        let address = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
        let connection = try await MySQLConnection.connect(
            to: address,
            username: profile.username,
            database: "",
            password: profile.password.isEmpty ? nil : profile.password,
            tlsConfiguration: tlsConfiguration,
            serverHostname: profile.host,
            logger: Logger(label: loggerLabel),
            on: eventLoopGroup.next()
        ).get()
        try await prepareMySQLSession(connection, database: database ?? "")
        return connection
    }

    private func prepareMySQLSession(_ connection: MySQLConnection, database: String) async throws {
        let trimmedDatabase = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDatabase.isEmpty else { return }
        let escapedDatabase = trimmedDatabase.replacingOccurrences(of: "`", with: "``")
        _ = try await connection.simpleQuery("USE `\(escapedDatabase)`").get()
    }

    private func makeMySQLTLSConfiguration(certificateVerification: CertificateVerification) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = certificateVerification
        return configuration
    }

    private func shouldRetryMySQLWithRelaxedTLS(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("niossl")
            || message.contains("tls")
            || message.contains("ssl")
            || message.contains("certificate")
            || message.contains("hostname")
            || message.contains("handshake")
    }

    private func applyMySQLSchemaColumnChange(
        _ draft: SchemaColumnDraft,
        profile: ConnectionProfile,
        database: String?
    ) async throws {
        let connection = try await connectMySQL(
            profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase),
            loggerLabel: "ad.neko.portsql.mysql.schema.ddl"
        )
        do {
            let statement = mySQLSchemaColumnChangeStatement(for: draft)
            _ = try await connection.simpleQuery(statement).get()
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
            let statement = """
            ALTER TABLE \(mySQLQualifiedTableName(table))
            DROP COLUMN \(mySQLIdentifier(column.name));
            """
            _ = try await connection.simpleQuery(statement).get()
            try await connection.close().get()
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func mySQLSchemaColumnChangeStatement(for draft: SchemaColumnDraft) -> String {
        let nullability = draft.isNullable ? "NULL" : "NOT NULL"
        switch draft.mode {
        case .add:
            return """
            ALTER TABLE \(mySQLQualifiedTableName(draft.table))
            ADD COLUMN \(mySQLIdentifier(draft.name)) \(draft.type) \(nullability);
            """
        case .edit:
            return """
            ALTER TABLE \(mySQLQualifiedTableName(draft.table))
            CHANGE COLUMN \(mySQLIdentifier(draft.originalName ?? draft.name)) \(mySQLIdentifier(draft.name)) \(draft.type) \(nullability);
            """
        }
    }

    private func mySQLQualifiedTableName(_ table: SchemaTableDescriptor) -> String {
        if table.schemaName.isEmpty {
            return mySQLIdentifier(table.name)
        }
        return "\(mySQLIdentifier(table.schemaName)).\(mySQLIdentifier(table.name))"
    }

    private func mySQLIdentifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    private static func render(mysql data: MySQLData?) -> String {
        guard let data else { return "" }
        if let value = data.string { return value }
        if let value = data.int64 { return String(value) }
        if let value = data.uint64 { return String(value) }
        if let value = data.double { return String(value) }
        if let value = data.float { return String(value) }
        if let value = data.bool { return value ? "true" : "false" }
        if let value = data.date { return ISO8601DateFormatter().string(from: value) }
        if let value = data.uuid { return value.uuidString }
        if let value = data.decimal { return NSDecimalNumber(decimal: value).stringValue }
        return data.description
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
    private func executePostgres(query: String, profile: ConnectionProfile, database: String?) async throws -> QueryResultTable {
        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: postgresDatabaseName(for: profile, requested: database),
            tls: profile.usesTLS ? .prefer(try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())) : .disable
        )
        let logger = Logger(label: "ad.neko.portsql.postgres")
        let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: 1,
            logger: logger
        ).get()
        do {
            let result = try await connection.query(query).get()
            let first = result.rows.first?.makeRandomAccess()
            let columns = first.map { row in
                (0..<row.count).map { index in
                    QueryColumn(name: row[index].columnName, type: "\(row[index].dataType)")
                }
            } ?? []
            let mappedRows = result.rows.map { row in
                let access = row.makeRandomAccess()
                return QueryRow(values: (0..<access.count).map { index in
                    Self.render(postgres: access[data: index])
                })
            }
            let summary = mappedRows.isEmpty ? "Statement executed successfully." : "Fetched \(mappedRows.count) rows from \(profile.name)."
            try await connection.close()
            return QueryResultTable(
                columns: columns,
                rows: mappedRows,
                executionSummary: summary,
                generatedMutation: nil,
                profiles: Self.makeProfiles(columns: columns, rows: mappedRows),
                sourceTableReference: nil
            )
        } catch {
            try? await connection.close()
            throw error
        }
    }

    private func loadPostgresSchema(profile: ConnectionProfile, database: String?) async throws -> [SchemaTableDescriptor] {
        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: postgresDatabaseName(for: profile, requested: database),
            tls: profile.usesTLS ? .prefer(try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())) : .disable
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
        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: postgresBootstrapDatabase(for: profile),
            tls: profile.usesTLS ? .prefer(try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())) : .disable
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

    private static func render(postgres data: PostgresData) -> String {
        if let value = data.string { return value }
        if let value = data.int { return String(value) }
        if let value = data.int64 { return String(value) }
        if let value = data.double { return String(value) }
        if let value = data.float { return String(value) }
        if let value = data.bool { return value ? "true" : "false" }
        if let value = data.uuid { return value.uuidString }
        if let value = data.date { return ISO8601DateFormatter().string(from: value) }
        return String(describing: data)
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
            let statements = postgresSchemaColumnChangeStatements(for: draft)
            for statement in statements {
                _ = try await connection.query(statement).get()
            }
            try await connection.close()
        } catch {
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
            let statement = """
            ALTER TABLE \(postgresQualifiedTableName(table))
            DROP COLUMN \(postgresIdentifier(column.name));
            """
            _ = try await connection.query(statement).get()
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    private func postgresSchemaColumnChangeStatements(for draft: SchemaColumnDraft) -> [String] {
        let tableName = postgresQualifiedTableName(draft.table)
        let targetName = postgresIdentifier(draft.name)
        var statements: [String] = []

        switch draft.mode {
        case .add:
            statements.append("""
            ALTER TABLE \(tableName)
            ADD COLUMN \(targetName) \(draft.type);
            """)
        case .edit:
            if let originalName = draft.originalName,
               originalName.caseInsensitiveCompare(draft.name) != .orderedSame {
                statements.append("""
                ALTER TABLE \(tableName)
                RENAME COLUMN \(postgresIdentifier(originalName)) TO \(targetName);
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
        return statements
    }

    private func connectPostgres(
        profile: ConnectionProfile,
        database: String?,
        id: Int,
        loggerLabel: String
    ) async throws -> PostgresConnection {
        let config = PostgresConnection.Configuration(
            host: profile.host,
            port: profile.port,
            username: profile.username,
            password: profile.password.isEmpty ? nil : profile.password,
            database: postgresDatabaseName(for: profile, requested: database),
            tls: profile.usesTLS ? .prefer(try! NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())) : .disable
        )
        let logger = Logger(label: loggerLabel)
        return try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: id,
            logger: logger
        ).get()
    }

    private func postgresQualifiedTableName(_ table: SchemaTableDescriptor) -> String {
        if table.schemaName.isEmpty {
            return postgresIdentifier(table.name)
        }
        return "\(postgresIdentifier(table.schemaName)).\(postgresIdentifier(table.name))"
    }

    private func postgresIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    #endif

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
            let values = rows.map { $0.values[safe: index] ?? "" }
            let nullCount = values.filter(\.isEmpty).count
            let distinct = Set(values).count
            let numericSeries = values.enumerated().compactMap { offset, value -> NumericSeriesPoint? in
                guard let number = Double(value) else { return nil }
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
    var sqlSingleQuoted: String {
        replacingOccurrences(of: "'", with: "''")
    }
}
