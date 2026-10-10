import Foundation

extension SQLiteDatabaseClient {
    static func listDatabases(profile: ConnectionProfile) async throws -> [String] {
        try await withConnection(profile: profile, policy: .readOnly) { connection in
            _ = try connection.query("SELECT count(*) FROM main.sqlite_schema")
            return ["main"]
        }
    }

    static func loadSchema(profile: ConnectionProfile, database: String? = nil) async throws -> [SchemaTableDescriptor] {
        try validateDatabaseName(database)
        return try await withConnection(profile: profile, policy: .readOnly) { connection in
            try connection.control("BEGIN")
            defer { connection.rollback() }
            let objects = try schemaRecords(connection)
            return try objects.map { object in
                let name = object["name"]?.displayValue ?? ""
                return try tableDescriptor(name: name, kind: object["type"]?.displayValue == "view" ? .view : .table, connection: connection)
            }
        }
    }

    static func schemaObjects(profile: ConnectionProfile, database: String? = nil) async throws -> [SchemaObject] {
        try validateDatabaseName(database)
        return try await withConnection(profile: profile, policy: .readOnly) { connection in
            try schemaRecords(connection).map { record in
                let name = record["name"]?.displayValue ?? ""
                let kind: SchemaObjectKind = record["type"]?.displayValue == "view" ? .view : .table
                return SchemaObject(id: kind.rawValue + ":main." + name, schema: "main", name: name, kind: kind)
            }
        }
    }

    static func foreignKeys(profile: ConnectionProfile, table: SchemaTableDescriptor) async throws -> [SchemaForeignKey] {
        try validateDatabaseName(table.schemaName)
        return try await withConnection(profile: profile, policy: .readOnly) { connection in
            try connection.control("BEGIN")
            defer { connection.rollback() }
            return try foreignKeys(tableName: table.name, connection: connection)
        }
    }

    static func schemaObjectDetails(profile: ConnectionProfile, object: SchemaObject) async throws -> SchemaObjectDetails {
        try validateDatabaseName(object.schema)
        return try await withConnection(profile: profile, policy: .readOnly) { connection in
            try connection.control("BEGIN")
            defer { connection.rollback() }
            let definitions = try records(connection.query("SELECT sql FROM main.sqlite_schema WHERE name = ? AND type IN ('table', 'view')", values: [.string(object.name)]))
            guard let definition = definitions.first?["sql"]?.displayValue else { throw DatabaseServiceError.invalidSchemaDefinition }
            var details = SchemaObjectDetails(definition: definition)
            if object.kind == .view { return details }
            let columns = try columnRecords(tableName: object.name, connection: connection)
            let primary = columns.filter { integer($0["pk"]) > 0 }.sorted { integer($0["pk"]) < integer($1["pk"]) }
            if !primary.isEmpty {
                details.constraints.append("PRIMARY KEY (" + primary.map { quoteIdentifier($0["name"]?.displayValue ?? "") }.joined(separator: ", ") + ")")
            }
            for column in columns {
                let name = quoteIdentifier(column["name"]?.displayValue ?? "")
                if integer(column["notnull"]) != 0 { details.constraints.append(name + " NOT NULL") }
                if let defaultValue = column["dflt_value"], !defaultValue.isNull { details.constraints.append(name + " DEFAULT " + defaultValue.displayValue) }
            }
            for index in try indexRecords(tableName: object.name, connection: connection) {
                let name = index["name"]?.displayValue ?? ""
                let definitions = try records(connection.query("SELECT sql FROM main.sqlite_schema WHERE type = 'index' AND name = ?", values: [.string(name)]))
                if let sql = definitions.first?["sql"], !sql.isNull {
                    details.indexes.append(sql.displayValue)
                } else {
                    let fields = try records(connection.query("SELECT name FROM pragma_index_info(?, 'main') ORDER BY seqno", values: [.string(name)]))
                    let unique = integer(index["unique"]) == 1 ? "UNIQUE " : ""
                    details.indexes.append(unique + "(" + fields.map { quoteIdentifier($0["name"]?.displayValue ?? "") }.joined(separator: ", ") + ")")
                }
            }
            details.foreignKeys = try foreignKeys(tableName: object.name, connection: connection)
            let triggers = try records(connection.query("SELECT sql FROM main.sqlite_schema WHERE type = 'trigger' AND tbl_name = ? ORDER BY name", values: [.string(object.name)]))
            for trigger in triggers {
                if let sql = trigger["sql"], !sql.isNull { details.definition += ";\n\n" + sql.displayValue }
            }
            return details
        }
    }

    static func tableDescriptor(name: String, kind: SchemaObjectKind = .table, connection: SQLiteConnection) throws -> SchemaTableDescriptor {
        let columns = try columnRecords(tableName: name, connection: connection)
        var uniqueColumns: Set<String> = []
        for index in try indexRecords(tableName: name, connection: connection)
            where integer(index["unique"]) == 1 && integer(index["partial"]) == 0 {
            let fields = try records(connection.query("SELECT name FROM pragma_index_info(?, 'main') ORDER BY seqno", values: [.string(index["name"]?.displayValue ?? "")]))
            if fields.count == 1, let field = fields.first?["name"], !field.isNull { uniqueColumns.insert(field.displayValue) }
        }
        return SchemaTableDescriptor(schemaName: "main", name: name, columns: columns.map { row in
            let name = row["name"]?.displayValue ?? ""
            var descriptor = SchemaColumnDescriptor(name: name, type: row["type"]?.displayValue ?? "",
                isNullable: integer(row["notnull"]) == 0, isPrimaryKey: integer(row["pk"]) > 0,
                isUnique: uniqueColumns.contains(name))
            descriptor.isGenerated = integer(row["hidden"]) != 0
            return descriptor
        }, rowCountEstimate: nil, objectKind: kind)
    }

    private static func schemaRecords(_ connection: SQLiteConnection) throws -> [[String: QueryCell]] {
        try records(connection.query("SELECT name, type, sql FROM main.sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name"))
    }

    private static func columnRecords(tableName: String, connection: SQLiteConnection) throws -> [[String: QueryCell]] {
        try records(connection.query("SELECT cid, name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?, 'main') ORDER BY cid", values: [.string(tableName)]))
    }

    private static func indexRecords(tableName: String, connection: SQLiteConnection) throws -> [[String: QueryCell]] {
        try records(connection.query("SELECT name, \"unique\", origin, partial FROM pragma_index_list(?, 'main') ORDER BY seq", values: [.string(tableName)]))
    }

    private static func foreignKeys(tableName: String, connection: SQLiteConnection) throws -> [SchemaForeignKey] {
        let rows = try records(connection.query("SELECT id, seq, \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(?, 'main') ORDER BY id, seq", values: [.string(tableName)]))
        let grouped = Dictionary(grouping: rows) { integer($0["id"]) }
        return try grouped.keys.sorted().compactMap { id in
            let parts = (grouped[id] ?? []).sorted { integer($0["seq"]) < integer($1["seq"]) }
            guard let referencedTable = parts.first?["table"]?.displayValue else { return nil }
            let primary = try columnRecords(tableName: referencedTable, connection: connection)
                .filter { integer($0["pk"]) > 0 }.sorted { integer($0["pk"]) < integer($1["pk"]) }
            let referenced = parts.enumerated().compactMap { index, part -> String? in
                if let name = part["to"], !name.isNull { return name.displayValue }
                return primary.indices.contains(index) ? primary[index]["name"]?.displayValue : nil
            }
            guard referenced.count == parts.count else { return nil }
            return SchemaForeignKey(id: "main." + tableName + ".fk_\(id)", name: "fk_\(id)",
                columns: parts.compactMap { $0["from"]?.displayValue }, referencedSchema: "main", referencedTable: referencedTable,
                referencedColumns: referenced)
        }
    }

    static func records(_ rows: SQLiteRows) -> [[String: QueryCell]] {
        rows.rows.map { row in
            var record: [String: QueryCell] = [:]
            for index in rows.columns.indices where row.cells.indices.contains(index) { record[rows.columns[index].name] = row.cells[index] }
            return record
        }
    }

    static func quoteIdentifier(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func integer(_ cell: QueryCell?) -> Int { Int(cell?.displayValue ?? "") ?? 0 }

    static func validateDatabaseName(_ name: String?) throws {
        guard name == nil || name?.isEmpty == true || name == "main" else { throw DatabaseServiceError.invalidSchemaDefinition }
    }
}
