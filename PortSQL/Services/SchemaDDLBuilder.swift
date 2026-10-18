import Foundation

/// SQL for a database object, for the Structure page's copy and open actions: a complete CREATE
/// script that can be replayed, plus DROP, SELECT, INSERT, and UPDATE statements.
enum SchemaDDLBuilder {
    static func qualifiedName(_ object: SchemaObject, engine: DatabaseEngine) -> String {
        DatabaseService.schemaIdentifier(object.schema, engine: engine) + "." + DatabaseService.schemaIdentifier(object.name, engine: engine)
    }

    /// The object's CREATE statement with what it needs to be recreated: on PostgreSQL its constraints
    /// and the indexes that don't back a constraint, on SQLite its indexes. MySQL's own statement is complete.
    static func createScript(_ object: SchemaObject, details: SchemaObjectDetails, engine: DatabaseEngine) -> String {
        var statements = [terminated(details.definition)]
        switch engine {
        case .postgresql where object.kind == .table:
            let qualified = qualifiedName(object, engine: engine)
            let constraintNames = Set(details.constraints.compactMap { constraintName(in: $0) })
            statements += details.constraints.map { "ALTER TABLE " + qualified + " ADD " + terminated($0) }
            statements += details.indexes.filter { index in
                // Primary key and unique constraints create their own indexes.
                guard let name = indexName(in: index) else { return true }
                return !constraintNames.contains(name)
            }.map(terminated)
        case .sqlite where object.kind == .table:
            statements += details.indexes.filter { $0.uppercased().hasPrefix("CREATE") }.map(terminated)
        default:
            break
        }
        return statements.filter { $0 != ";" && !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func dropStatement(_ object: SchemaObject, engine: DatabaseEngine) -> String {
        let qualified = qualifiedName(object, engine: engine)
        switch object.kind {
        case .table: return "DROP TABLE " + qualified + ";"
        case .view: return "DROP VIEW " + qualified + ";"
        case .materializedView: return "DROP MATERIALIZED VIEW " + qualified + ";"
        // PostgreSQL routines are overloaded, so the argument types pick the one to drop.
        case .function: return "DROP FUNCTION " + qualified + (engine == .postgresql ? "(" + object.signature + ")" : "") + ";"
        case .procedure: return "DROP PROCEDURE " + qualified + (engine == .postgresql ? "(" + object.signature + ")" : "") + ";"
        }
    }

    static func selectStatement(_ object: SchemaObject, columns: [SchemaColumnDescriptor], engine: DatabaseEngine) -> String {
        let list = columns.isEmpty ? "*" : columns.map { DatabaseService.schemaIdentifier($0.name, engine: engine) }.joined(separator: ",\n       ")
        return "SELECT " + list + "\nFROM " + qualifiedName(object, engine: engine) + "\nLIMIT 100;"
    }

    /// An INSERT with a named parameter per column, which the console asks values for and binds.
    static func insertStatement(_ object: SchemaObject, columns: [SchemaColumnDescriptor], engine: DatabaseEngine) -> String {
        let writable = columns.filter { $0.isGenerated != true }
        let names = writable.map { DatabaseService.schemaIdentifier($0.name, engine: engine) }.joined(separator: ", ")
        let values = writable.map { ":" + parameterName($0.name) }.joined(separator: ", ")
        return "INSERT INTO " + qualifiedName(object, engine: engine) + " (" + names + ")\nVALUES (" + values + ");"
    }

    /// An UPDATE of the non-key columns, matched on the primary key.
    static func updateStatement(_ object: SchemaObject, columns: [SchemaColumnDescriptor], engine: DatabaseEngine) -> String {
        let keys = columns.filter(\.isPrimaryKey)
        let changed = columns.filter { !$0.isPrimaryKey && $0.isGenerated != true }
        let assignments = changed.map { DatabaseService.schemaIdentifier($0.name, engine: engine) + " = :" + parameterName($0.name) }
        let conditions = keys.map { DatabaseService.schemaIdentifier($0.name, engine: engine) + " = :" + parameterName($0.name) }
        return "UPDATE " + qualifiedName(object, engine: engine) + "\nSET " + assignments.joined(separator: ",\n    ")
            + "\nWHERE " + (conditions.isEmpty ? "/* choose the rows to update */" : conditions.joined(separator: " AND ")) + ";"
    }

    static func columnList(_ columns: [SchemaColumnDescriptor], engine: DatabaseEngine) -> String {
        columns.map { DatabaseService.schemaIdentifier($0.name, engine: engine) }.joined(separator: ", ")
    }

    // MARK: Helpers

    private static func terminated(_ statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix(";") ? trimmed : trimmed + ";"
    }

    /// Parameter names use letters, digits, and underscores, so other column names are simplified.
    private static func parameterName(_ column: String) -> String {
        let simplified = String(column.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        return simplified.first?.isNumber == true ? "_" + simplified : simplified
    }

    /// The name in "CONSTRAINT name definition", unquoted.
    private static func constraintName(in constraint: String) -> String? {
        let parts = constraint.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].uppercased() == "CONSTRAINT" else { return nil }
        return unquoted(String(parts[1]))
    }

    /// The name in "CREATE [UNIQUE] INDEX [CONCURRENTLY] name ON …", unquoted.
    private static func indexName(in definition: String) -> String? {
        let words = definition.split(separator: " ").map(String.init)
        guard let index = words.firstIndex(where: { $0.uppercased() == "INDEX" }) else { return nil }
        var position = index + 1
        while words.indices.contains(position), ["CONCURRENTLY", "IF", "NOT", "EXISTS"].contains(words[position].uppercased()) { position += 1 }
        guard words.indices.contains(position), words[position].uppercased() != "ON" else { return nil }
        return unquoted(words[position])
    }

    private static func unquoted(_ identifier: String) -> String {
        guard identifier.count >= 2, let first = identifier.first, first == "\"" || first == "`", identifier.last == first else { return identifier }
        return String(identifier.dropFirst().dropLast()).replacingOccurrences(of: String(first) + String(first), with: String(first))
    }
}
