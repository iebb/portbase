import Foundation
import SQLite3

extension SQLiteDatabaseClient {
    static func exportData(query: BoundQuery, profile: ConnectionProfile, database: String? = nil, format: QueryResultExportFormat,
                           policy: DatabaseExecutionPolicy, timeoutSeconds: Int = 30,
                           progress: @escaping @Sendable (DataTransferProgress) -> Void = { _ in }) async throws -> DataTransferResult {
        guard case .readOnly = policy else { throw DatabaseServiceError.readOnlyQueryRequired }
        try validateDatabaseName(database)
        let writer = try DataExportWriter(format: format, progress: progress)
        do {
            try await withConnection(profile: profile, policy: .readOnly, timeoutSeconds: timeoutSeconds) { connection in
                let statement = try connection.prepare(query.sql)
                defer { sqlite3_finalize(statement) }
                try connection.bind(query.values, to: statement)
                guard sqlite3_stmt_readonly(statement) != 0 else { throw DatabaseServiceError.readOnlyQueryRequired }
                _ = try connection.read(statement, maximumRows: nil, onColumns: { writer.setColumns($0) }, onRow: { try writer.append($0) })
                try connection.operation.check()
            }
            try Task.checkCancellation()
            return try writer.finish()
        } catch {
            writer.discard()
            throw error
        }
    }

    static func importData(plan: DataImportPlan, profile: ConnectionProfile, database: String? = nil, policy: DatabaseExecutionPolicy,
                           timeoutSeconds: Int = 30,
                           progress: @escaping @Sendable (DataTransferProgress) -> Void = { _ in }) async throws -> DataTransferResult {
        guard case .mutation(let expected) = policy else { throw DatabaseServiceError.unsafeQueryRequiresConfirmation }
        guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        try validateDatabaseName(database)
        try validateDatabaseName(plan.schemaName)
        let sql = try plan.statement(engine: .sqlite)
        return try await withConnection(profile: profile, policy: .mutation(), timeoutSeconds: timeoutSeconds) { connection in
            try connection.control("BEGIN IMMEDIATE")
            var committed = false
            defer { if !committed { connection.rollback() } }
            let tables = try records(connection.query("SELECT name FROM main.sqlite_schema WHERE name = ? AND type = 'table'", values: [.string(plan.tableName)]))
            guard !tables.isEmpty else { throw DataTransferError.invalidMapping }
            let destination = try tableDescriptor(name: plan.tableName, connection: connection)
            let mappings = plan.mappings.filter { !$0.targetName.isEmpty }
            for mapping in mappings {
                guard let column = destination.columns.first(where: { $0.name == mapping.targetName }), column.isGenerated != true else {
                    throw DataTransferError.invalidMapping
                }
                guard !DataTransferCodec.isBinaryColumn(column.type) else { throw DataTransferError.binaryImportUnsupported }
            }
            let statement = try connection.prepare(sql)
            defer { sqlite3_finalize(statement) }
            let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
            var completed = 0
            while let record = try reader.next() {
                try connection.operation.check()
                let values: [QueryBoundValue] = try mappings.map { mapping in
                    guard let cell = record.fields[mapping.sourceName] else { throw DataTransferError.missingField(column: mapping.sourceName, row: completed + 1) }
                    let column = destination.columns.first { $0.name == mapping.targetName }!
                    let type = mapping.valueType == .automatic ? DataTransferCodec.sqlValueType(for: column.type) : mapping.valueType
                    return try DataTransferCodec.boundValue(cell, type: type, column: mapping.targetName, row: completed + 1)
                }
                try connection.bind(values, to: statement)
                let code = sqlite3_step(statement)
                guard code == SQLITE_DONE else { throw connection.error(code) }
                let affected = Int(sqlite3_changes64(connection.handle))
                guard affected == 1 else { throw DatabaseServiceError.unexpectedAffectedRowCount(expected: 1, actual: affected) }
                let reset = sqlite3_reset(statement)
                guard reset == SQLITE_OK else { throw connection.error(reset) }
                sqlite3_clear_bindings(statement)
                completed += 1
                if completed % 25 == 0 { progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount)) }
            }
            if let expected, completed != expected {
                throw DatabaseServiceError.unexpectedAffectedRowCount(expected: expected, actual: completed)
            }
            guard completed == plan.source.rowCount else {
                throw DatabaseServiceError.unexpectedAffectedRowCount(expected: plan.source.rowCount, actual: completed)
            }
            try connection.operation.check()
            progress(.init(phase: .finishing, completed: completed, total: plan.source.rowCount))
            try connection.control("COMMIT")
            committed = true
            return DataTransferResult(rowCount: completed, fileURL: nil)
        }
    }
}
