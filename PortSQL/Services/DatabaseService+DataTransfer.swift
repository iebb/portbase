import Foundation
import Logging
import MySQLNIO
import NIOCore
import PostgresNIO
@preconcurrency import SwiftBSON

extension DatabaseService {
    func exportData(
        query: BoundQuery,
        profile: ConnectionProfile,
        database: String?,
        format: QueryResultExportFormat,
        policy: DatabaseExecutionPolicy,
        timeoutSeconds: Int = 30,
        progress: @escaping @Sendable (DataTransferProgress) -> Void = { _ in }
    ) async throws -> DataTransferResult {
        guard case .readOnly = policy else { throw DatabaseServiceError.readOnlyQueryRequired }
        guard profile.engine.supportsFullExport else { throw DatabaseServiceError.unsupported }
        let mongo = profile.engine == .mongodb ? try MongoQueryService.parse(query.sql) : nil
        try validateExecution(query: query.sql, profile: profile, policy: policy, isReadOnly: mongo?.isReadOnly)
        let timeout = max(1, min(timeoutSeconds, 300))
        if profile.engine == .sqlite {
            return try await SQLiteDatabaseClient.exportData(query: query, profile: profile, database: database, format: format,
                policy: policy, timeoutSeconds: timeout, progress: progress)
        }
        let writer = try DataExportWriter(format: format, progress: progress)
        do {
            switch profile.engine {
            case .mysql, .mariadb:
                guard SQLEditingService.statementRanges(in: query.sql, engine: .mysql).count == 1 else { throw DataTransferError.singleQueryRequired }
                try await streamMySQLExport(query: query, profile: profile, database: database, timeout: timeout, writer: writer)
            case .postgresql:
                guard SQLEditingService.statementRanges(in: query.sql, engine: .postgresql).count == 1 else { throw DataTransferError.singleQueryRequired }
                try await streamPostgresExport(query: query, profile: profile, database: database, timeout: timeout, writer: writer)
            case .sqlite, .redis, .clickhouse, .elasticsearch: throw DatabaseServiceError.unsupported
            case .mongodb:
                guard query.values.isEmpty, let mongo else { throw MongoClientError.invalidCommand }
                let db = resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase) ?? "admin"
                if format == .json {
                    _ = try await MongoDatabaseClient.stream(query: mongo, profile: profile, database: db,
                        timeoutSeconds: timeout, eventLoopGroup: eventLoopGroup, onDocument: { try writer.appendDocument($0) })
                } else {
                    let spool = try MongoCSVExportSpool(progress: progress)
                    _ = try await MongoDatabaseClient.stream(query: mongo, profile: profile, database: db,
                        timeoutSeconds: timeout, eventLoopGroup: eventLoopGroup, onDocument: { try spool.append($0) })
                    let finishing = Task.detached { try spool.finish(writer: writer) }
                    return try await withTaskCancellationHandler(operation: { try await finishing.value }, onCancel: { finishing.cancel() })
                }
            }
            try Task.checkCancellation()
            return try writer.finish()
        } catch {
            writer.discard()
            throw error
        }
    }

    private func streamMySQLExport(query: BoundQuery, profile: ConnectionProfile, database: String?, timeout: Int,
                                   writer: DataExportWriter) async throws {
        let connection = try await connectMySQL(profile: profile,
            database: resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase), loggerLabel: "ad.neko.portsql.export")
        do {
            try await withQueryTimeout(seconds: timeout, closeConnection: { _ = connection.close() }) {
            try await self.configureMySQLSession(connection, profile: profile, policy: .readOnly)
            let future = connection.query(query.sql, query.values.map(Self.mysqlBind), onColumns: { definitions in
                writer.setColumns(definitions.map { QueryColumn(name: $0.name, type: "\($0.columnType)") })
            }, onRow: { row in
                let cells = row.columnDefinitions.indices.map { index in
                    let definition = row.columnDefinitions[index]
                    let value = MySQLData(type: definition.columnType, format: row.format, buffer: row.values[index],
                                          isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED))
                    return Self.cell(mysql: value, definition: definition)
                }
                try writer.append(QueryRow(cells: cells))
            })
            try await future.get()
            }
            try await connection.close().get()
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func streamPostgresExport(query: BoundQuery, profile: ConnectionProfile, database: String?, timeout: Int,
                                      writer: DataExportWriter) async throws {
        let connection = try await connectPostgres(profile: profile, database: database, id: 1, loggerLabel: "ad.neko.portsql.export")
        do {
            let bindings = try Self.postgresBindings(query.values)
            try await withQueryTimeout(seconds: timeout, closeConnection: { _ = connection.close() as EventLoopFuture<Void> }) {
                try await self.configurePostgresSession(connection, profile: profile, policy: .readOnly)
                let rows = try await connection.query(PostgresQuery(unsafeSQL: query.sql, binds: bindings), logger: Logger(label: "ad.neko.portsql.export"))
                writer.setColumns(rows.columns.map { QueryColumn(name: $0.name, type: "\($0.dataType)") })
                for try await row in rows {
                    try Task.checkCancellation()
                    try writer.append(Self.postgresRow(row))
                }
            }
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    func importData(
        plan: DataImportPlan,
        profile: ConnectionProfile,
        database: String?,
        policy: DatabaseExecutionPolicy,
        timeoutSeconds: Int = 30,
        progress: @escaping @Sendable (DataTransferProgress) -> Void = { _ in }
    ) async throws -> DataTransferResult {
        guard case .mutation = policy else { throw DatabaseServiceError.unsafeQueryRequiresConfirmation }
        guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        guard profile.engine.supportsDataImport else { throw DatabaseServiceError.unsupported }
        if profile.engine == .sqlite {
            return try await SQLiteDatabaseClient.importData(plan: plan, profile: profile, database: database, policy: policy,
                timeoutSeconds: max(1, min(timeoutSeconds, 300)), progress: progress)
        }
        let statement = try plan.statement(engine: profile.engine)
        let timeout = max(1, min(timeoutSeconds, 300))
        if profile.engine == .mongodb {
            return try await importMongoData(plan: plan, profile: profile, database: database, timeout: timeout, progress: progress)
        }
        try validateExecution(query: statement, profile: profile, policy: policy)
        let mappings = plan.mappings.filter { !$0.targetName.isEmpty }
        let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                                                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
        let sessionID = UUID()
        var completed = 0
        var commitAttempted = false
        do {
            // Hold the destination's metadata lock until commit, so DDL cannot change its engine or column types after validation.
            _ = try await execute(query: "SELECT 1 FROM " + DataTransferCodec.qualifiedTable(schema: plan.schemaName, table: plan.tableName, engine: profile.engine) + " LIMIT 0",
                profile: profile, database: database, policy: .mutation(), timeoutSeconds: timeout, sessionID: sessionID, manualCommit: true)
            let schema = try await loadSchema(profile: profile, database: database)
            guard let destination = schema.first(where: { $0.name == plan.tableName && (plan.schemaName.isEmpty || $0.schemaName == plan.schemaName) }) else {
                throw DataTransferError.invalidMapping
            }
            for mapping in mappings {
                guard let column = destination.columns.first(where: { $0.name == mapping.targetName }) else { throw DataTransferError.invalidMapping }
                guard !DataTransferCodec.isBinaryColumn(column.type) else { throw DataTransferError.binaryImportUnsupported }
            }
            if profile.engine.isMySQLFamily {
                let result = try await execute(query: "SELECT ENGINE FROM information_schema.tables WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_NAME = ?",
                    values: [plan.schemaName.isEmpty ? .null : .string(plan.schemaName), .string(plan.tableName)],
                    profile: profile, database: database, policy: .mutation(), timeoutSeconds: timeout, sessionID: sessionID, manualCommit: true)
                guard let engine = result.rows.first?.cells.first?.displayValue.uppercased(), ["INNODB", "XTRADB"].contains(engine) else {
                    throw DataTransferError.nonTransactionalTable
                }
            }
            while let record = try reader.next() {
                try Task.checkCancellation()
                let values: [QueryBoundValue] = try mappings.map { mapping in
                    guard let cell = record.fields[mapping.sourceName] else { throw DataTransferError.missingField(column: mapping.sourceName, row: completed + 1) }
                    let type = mapping.valueType == .automatic
                        ? DataTransferCodec.sqlValueType(for: destination.columns.first(where: { $0.name == mapping.targetName })!.type)
                        : mapping.valueType
                    return try DataTransferCodec.boundValue(cell, type: type, column: mapping.targetName, row: completed + 1)
                }
                let result = try await execute(query: statement, values: values, profile: profile, database: database,
                    policy: .mutation(expectedAffectedRows: nil), timeoutSeconds: timeout, sessionID: sessionID, manualCommit: true)
                guard result.affectedRowCount == 1 else {
                    throw DatabaseServiceError.unexpectedAffectedRowCount(expected: 1, actual: result.affectedRowCount ?? -1)
                }
                completed += 1
                if completed % 25 == 0 { progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount)) }
            }
            try Task.checkCancellation()
            progress(.init(phase: .finishing, completed: completed, total: plan.source.rowCount))
            commitAttempted = true
            try await finishConsoleTransaction(sessionID, commit: true)
            await closeConsole(sessionID)
            return DataTransferResult(rowCount: completed, fileURL: nil)
        } catch {
            try? await finishConsoleTransaction(sessionID, commit: false)
            await closeConsole(sessionID)
            if commitAttempted { throw DataTransferError.commitUncertain }
            throw error
        }
    }

    private func importMongoData(plan: DataImportPlan, profile: ConnectionProfile, database: String?, timeout: Int,
                                  progress: @escaping @Sendable (DataTransferProgress) -> Void) async throws -> DataTransferResult {
        let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                                                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
        var batch: [BSONDocument] = []
        var byteCount = 0
        var completed = 0
        var recordIndex = 0
        func command(_ documents: [BSONDocument]) throws -> String {
            let command = try MongoExtendedJSON.orderedDocument([
                ("insert", .string(plan.tableName)), ("documents", .array(documents.map(BSON.document))), ("ordered", .bool(true))
            ])
            return MongoExtendedJSON.encode(command, canonical: true)
        }
        do {
            while let record = try reader.next() {
                try Task.checkCancellation()
                recordIndex += 1
                let document = try DataTransferCodec.mongoDocument(record: record, mappings: plan.mappings, row: recordIndex)
                let size = MongoExtendedJSON.encode(document, canonical: true).utf8.count
                guard size < 900_000 else { throw DataTransferError.recordTooLarge }
                if !batch.isEmpty, batch.count >= 100 || byteCount + size > 900_000 {
                    _ = try await execute(query: command(batch), profile: profile, database: database, policy: .mutation(), timeoutSeconds: timeout)
                    completed += batch.count
                    progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount))
                    batch = []; byteCount = 0
                }
                batch.append(document); byteCount += size
            }
            try Task.checkCancellation()
            if !batch.isEmpty {
                _ = try await execute(query: command(batch), profile: profile, database: database, policy: .mutation(), timeoutSeconds: timeout)
                completed += batch.count
            }
            return DataTransferResult(rowCount: completed, fileURL: nil)
        } catch {
            throw DataTransferError.mongoPartialImport(completed: completed, underlying: error is CancellationError ? L10n.text("Cancelled") : error.localizedDescription)
        }
    }
}
