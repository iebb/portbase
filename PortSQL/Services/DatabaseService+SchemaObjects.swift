import Foundation

extension DatabaseService {
    func schemaObjects(profile: ConnectionProfile, database: String?) async throws -> [SchemaObject] {
        let query: String
        let values: [QueryBoundValue]
        switch profile.engine {
        case .postgresql:
            query = """
            SELECT c.oid::text AS object_id, n.nspname AS schema_name, c.relname AS object_name,
                   CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'materializedView' ELSE 'table' END AS kind,
                   '' AS signature
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','p','v','m','f') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'
            UNION ALL
            SELECT p.oid::text, n.nspname, p.proname, CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
                   pg_get_function_identity_arguments(p.oid)
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE p.prokind IN ('f','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
            ORDER BY schema_name, kind, object_name
            """
            values = []
        case .mysql, .mariadb:
            query = """
            SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME) AS object_id, TABLE_SCHEMA AS schema_name, TABLE_NAME AS object_name,
                   CASE TABLE_TYPE WHEN 'VIEW' THEN 'view' ELSE 'table' END AS kind, '' AS signature
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = ?
            UNION ALL
            SELECT CONCAT(ROUTINE_SCHEMA, '.', ROUTINE_NAME, '.', ROUTINE_TYPE), ROUTINE_SCHEMA, ROUTINE_NAME,
                   LOWER(ROUTINE_TYPE), '' FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = ?
            ORDER BY schema_name, kind, object_name
            """
            let name = resolvedDatabaseName(database, fallback: profile.trimmedDefaultDatabase) ?? ""
            values = [.string(name), .string(name)]
        case .sqlite: return try await SQLiteDatabaseClient.schemaObjects(profile: profile, database: database)
        case .mongodb, .redis, .clickhouse, .elasticsearch: throw DatabaseServiceError.unsupported
        }
        let result = try await execute(query: query, values: values, profile: profile, database: database, policy: .readOnly)
        return result.records().compactMap { row in
            guard let rawKind = row["kind"]?.displayValue, let kind = SchemaObjectKind(rawValue: rawKind) else { return nil }
            return SchemaObject(id: rawKind + ":" + (row["object_id"]?.displayValue ?? ""), schema: row["schema_name"]?.displayValue ?? "",
                name: row["object_name"]?.displayValue ?? "", kind: kind, signature: row["signature"]?.displayValue ?? "")
        }
    }

    func schemaForeignKeys(table: SchemaTableDescriptor, profile: ConnectionProfile, database: String?) async throws -> [SchemaForeignKey] {
        let query: String
        switch profile.engine {
        case .postgresql:
            query = """
            SELECT c.conname AS name, a.attname AS column_name, rn.nspname AS referenced_schema,
                   rc.relname AS referenced_table, ra.attname AS referenced_column
            FROM pg_constraint c JOIN pg_class cl ON cl.oid = c.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace
            JOIN pg_class rc ON rc.oid = c.confrelid JOIN pg_namespace rn ON rn.oid = rc.relnamespace
            CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(local_key, foreign_key, ord)
            JOIN pg_attribute a ON a.attrelid = cl.oid AND a.attnum = k.local_key
            JOIN pg_attribute ra ON ra.attrelid = rc.oid AND ra.attnum = k.foreign_key
            WHERE c.contype = 'f' AND n.nspname = $1 AND cl.relname = $2 ORDER BY c.conname, k.ord
            """
        case .mysql, .mariadb:
            query = """
            SELECT CONSTRAINT_NAME AS name, COLUMN_NAME AS column_name, REFERENCED_TABLE_SCHEMA AS referenced_schema,
                   REFERENCED_TABLE_NAME AS referenced_table, REFERENCED_COLUMN_NAME AS referenced_column
            FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
              AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION
            """
        case .sqlite: return try await SQLiteDatabaseClient.foreignKeys(profile: profile, table: table)
        case .mongodb, .redis, .clickhouse, .elasticsearch: return []
        }
        let records = try await execute(query: query, values: [.string(table.schemaName), .string(table.name)],
            profile: profile, database: database, policy: .readOnly).records()
        let grouped = Dictionary(grouping: records) { $0["name"]?.displayValue ?? "" }
        return grouped.keys.sorted().map { name in
            let rows = grouped[name] ?? []
            return SchemaForeignKey(id: table.displayName + "." + name, name: name,
                columns: rows.compactMap { $0["column_name"]?.displayValue }, referencedSchema: rows.first?["referenced_schema"]?.displayValue ?? "",
                referencedTable: rows.first?["referenced_table"]?.displayValue ?? "",
                referencedColumns: rows.compactMap { $0["referenced_column"]?.displayValue })
        }
    }

    func schemaObjectDetails(_ object: SchemaObject, profile: ConnectionProfile, database: String?) async throws -> SchemaObjectDetails {
        if profile.engine == .sqlite { return try await SQLiteDatabaseClient.schemaObjectDetails(profile: profile, object: object) }
        guard profile.engine.supportsSchemaObjects else { throw DatabaseServiceError.unsupported }
        var details = SchemaObjectDetails()
        let qualified = Self.schemaIdentifier(object.schema, engine: profile.engine) + "." + Self.schemaIdentifier(object.name, engine: profile.engine)
        let table = SchemaTableDescriptor(schemaName: object.schema, name: object.name, columns: [], rowCountEstimate: nil)
        let tableValues: [QueryBoundValue] = [.string(object.schema), .string(object.name)]
        if profile.engine.isMySQLFamily {
            let kind = object.kind == .view ? "VIEW" : object.kind == .procedure ? "PROCEDURE" : object.kind == .function ? "FUNCTION" : "TABLE"
            let ddl = try await execute(query: "SHOW CREATE \(kind) \(qualified)", profile: profile, database: database, policy: .readOnly)
            let field = ddl.columns.firstIndex { $0.name.lowercased().hasPrefix("create ") }
            if let field, let row = ddl.rows.first, row.cells.indices.contains(field) { details.definition = row.cells[field].displayValue + ";" }
            if object.kind == .table {
                let indexes = try await execute(query: "SHOW INDEX FROM \(qualified)", profile: profile, database: database, policy: .readOnly)
                let grouped = Dictionary(grouping: indexes.records()) { $0["Key_name"]?.displayValue ?? "" }
                details.indexes = grouped.keys.sorted().map { key in
                    let fields = (grouped[key] ?? []).map { row in (row["Column_name"]?.displayValue ?? row["Expression"]?.displayValue ?? "") + ((row["Sub_part"]?.displayValue).flatMap { $0 == "NULL" ? nil : "(" + $0 + ")" } ?? "") }
                    return key + " (" + fields.joined(separator: ", ") + ")"
                }
                let constraints = try await execute(query: "SELECT CONSTRAINT_NAME AS name, CONSTRAINT_TYPE AS kind FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY CONSTRAINT_NAME",
                    values: tableValues, profile: profile, database: database, policy: .readOnly)
                details.constraints = constraints.records().map { ($0["name"]?.displayValue ?? "") + ": " + ($0["kind"]?.displayValue ?? "") }
                details.foreignKeys = try await schemaForeignKeys(table: table, profile: profile, database: database)
            }
            return details
        }
        guard profile.engine == .postgresql else { throw DatabaseServiceError.unsupported }
        if object.kind == .function || object.kind == .procedure {
            let oid = String(object.id.split(separator: ":").last ?? "")
            let rows = try await execute(query: "SELECT pg_get_functiondef($1::oid) AS definition", values: [.string(oid)], profile: profile, database: database, policy: .readOnly)
            details.definition = rows.rows.first?.cells.first?.displayValue ?? ""
            return details
        }
        if object.kind == .view || object.kind == .materializedView {
            let rows = try await execute(query: "SELECT pg_get_viewdef(c.oid, true) AS definition FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2",
                values: tableValues, profile: profile, database: database, policy: .readOnly)
            details.definition = "CREATE " + (object.kind == .materializedView ? "MATERIALIZED VIEW " : "OR REPLACE VIEW ") + qualified + " AS\n" + (rows.rows.first?.cells.first?.displayValue ?? "")
        } else {
            let fields = try await execute(query: """
                SELECT a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type,
                       a.attnotnull AS not_null, pg_get_expr(d.adbin, d.adrelid) AS default_value,
                       a.attidentity AS identity_kind, a.attgenerated AS generated_kind,
                       CASE WHEN a.attcollation <> t.typcollation THEN quote_ident(cn.nspname) || '.' || quote_ident(co.collname) ELSE '' END AS collation
                FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_type t ON t.oid = a.atttypid LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                LEFT JOIN pg_collation co ON co.oid = a.attcollation LEFT JOIN pg_namespace cn ON cn.oid = co.collnamespace
                WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
                """, values: tableValues, profile: profile, database: database, policy: .readOnly)
            let lines = fields.records().map { row in
                var line = Self.schemaIdentifier(row["name"]?.displayValue ?? "", engine: .postgresql) + " " + (row["type"]?.displayValue ?? "")
                if let collation = row["collation"]?.displayValue, !collation.isEmpty, collation != "NULL" { line += " COLLATE " + collation }
                let identity = row["identity_kind"]?.displayValue ?? ""
                if !identity.isEmpty { line += identity == "a" ? " GENERATED ALWAYS AS IDENTITY" : " GENERATED BY DEFAULT AS IDENTITY" }
                else if let value = row["default_value"], value != .null {
                    let generated = row["generated_kind"]?.displayValue ?? ""
                    line += generated.isEmpty ? " DEFAULT " + value.displayValue : " GENERATED ALWAYS AS (" + value.displayValue + ") " + (generated == "v" ? "VIRTUAL" : "STORED")
                }
                if row["not_null"] == .boolean(true) { line += " NOT NULL" }
                return "  " + line
            }
            details.definition = "CREATE TABLE " + qualified + " (\n" + lines.joined(separator: ",\n") + "\n);"
        }
        let constraints = try await execute(query: """
            SELECT con.conname AS name, pg_get_constraintdef(con.oid, true) AS definition
            FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 ORDER BY con.conname
            """, values: tableValues, profile: profile, database: database, policy: .readOnly)
        details.constraints = constraints.records().map { "CONSTRAINT " + Self.schemaIdentifier($0["name"]?.displayValue ?? "", engine: .postgresql) + " " + ($0["definition"]?.displayValue ?? "") }
        let indexes = try await execute(query: "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 ORDER BY indexname",
            values: tableValues, profile: profile, database: database, policy: .readOnly)
        details.indexes = indexes.rows.compactMap { $0.cells.first?.displayValue }
        details.foreignKeys = try await schemaForeignKeys(table: table, profile: profile, database: database)
        return details
    }

    static func schemaIdentifier(_ value: String, engine: DatabaseEngine) -> String {
        let delimiter = engine.isMySQLFamily ? "`" : "\""
        return delimiter + value.replacingOccurrences(of: delimiter, with: delimiter + delimiter) + delimiter
    }
}
