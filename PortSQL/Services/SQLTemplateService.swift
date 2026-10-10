import Foundation

/// Starter statements inserted into the editor. Inserting a template never runs it.
struct SQLTemplate: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case select, aggregate, join, cte, window, insert, update, delete, createIndex
    }

    var id: Kind { kind }
    let kind: Kind
    let title: String
    let systemImage: String
    let sql: String
    var isWrite: Bool { [.insert, .update, .delete, .createIndex].contains(kind) }
}

enum SQLTemplateService {
    static func templates(table: SchemaTableDescriptor?, engine: DatabaseEngine) -> [SQLTemplate] {
        let name = table.map { qualifiedName($0, engine: engine) } ?? "table_name"
        let columns = table?.columns.map { identifier($0.name, engine: engine) } ?? []
        let first = columns.first ?? "id"
        let second = columns.dropFirst().first ?? "name"
        let key = table?.primaryKeyColumns.first.map { identifier($0.name, engine: engine) } ?? first
        let list = columns.isEmpty ? "*" : columns.prefix(6).joined(separator: ", ")
        let limit = engine == .sqlite || engine == .postgresql || engine.isMySQLFamily || engine == .clickhouse ? "\nLIMIT 100" : ""

        return [
            SQLTemplate(kind: .select, title: L10n.text("Select rows"), systemImage: "list.bullet.rectangle",
                        sql: "SELECT \(list)\nFROM \(name)\nWHERE \(first) IS NOT NULL\nORDER BY \(key)\(limit);"),
            SQLTemplate(kind: .aggregate, title: L10n.text("Group and count"), systemImage: "chart.bar.doc.horizontal",
                        sql: "SELECT \(second), COUNT(*) AS total\nFROM \(name)\nGROUP BY \(second)\nORDER BY total DESC\(limit);"),
            SQLTemplate(kind: .join, title: L10n.text("Join tables"), systemImage: "arrow.triangle.merge",
                        sql: "SELECT a.*, b.*\nFROM \(name) AS a\nJOIN other_table AS b ON b.\(first) = a.\(key)\(limit);"),
            SQLTemplate(kind: .cte, title: L10n.text("Common table expression"), systemImage: "square.stack.3d.down.right",
                        sql: "WITH recent AS (\n  SELECT *\n  FROM \(name)\n)\nSELECT *\nFROM recent\(limit);"),
            SQLTemplate(kind: .window, title: L10n.text("Running total"), systemImage: "function",
                        sql: "SELECT \(key), \(second),\n  SUM(\(first)) OVER (ORDER BY \(key)) AS running_total\nFROM \(name)\(limit);"),
            SQLTemplate(kind: .insert, title: L10n.text("Insert row"), systemImage: "plus.square",
                        sql: "INSERT INTO \(name) (\(columns.prefix(3).joined(separator: ", ").isEmpty ? "\(first), \(second)" : columns.prefix(3).joined(separator: ", ")))\nVALUES (:value1, :value2\(columns.count >= 3 ? ", :value3" : ""));"),
            SQLTemplate(kind: .update, title: L10n.text("Update rows"), systemImage: "pencil.line",
                        sql: "UPDATE \(name)\nSET \(second) = :value\nWHERE \(key) = :id;"),
            SQLTemplate(kind: .delete, title: L10n.text("Delete rows"), systemImage: "trash",
                        sql: "DELETE FROM \(name)\nWHERE \(key) = :id;"),
            SQLTemplate(kind: .createIndex, title: L10n.text("Create index"), systemImage: "bolt.horizontal",
                        sql: "CREATE INDEX idx_\(table?.name ?? "table")_\(table?.columns.dropFirst().first?.name ?? "column")\nON \(name) (\(second));"),
        ]
    }

    /// Inserts `snippet` at a UTF-16 cursor, replacing any selection, and returns the new text and cursor.
    static func insert(_ snippet: String, into text: String, cursor: Int, selectionLength: Int) -> (text: String, cursor: Int) {
        let source = text as NSString
        let location = min(max(0, cursor), source.length)
        let length = min(max(0, selectionLength), source.length - location)
        let before = source.substring(to: location)
        let needsBreak = !before.isEmpty && !before.hasSuffix("\n")
        let insertion = (needsBreak ? "\n\n" : "") + snippet
        let updated = source.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
        return (updated, location + (insertion as NSString).length)
    }

    static func identifier(_ name: String, engine: DatabaseEngine) -> String {
        let simple = name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
        guard !simple else { return name }
        if engine.isMySQLFamily || engine == .clickhouse { return "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func qualifiedName(_ table: SchemaTableDescriptor, engine: DatabaseEngine) -> String {
        let name = identifier(table.name, engine: engine)
        guard !table.schemaName.isEmpty, engine != .sqlite || table.schemaName != "main" else { return name }
        return identifier(table.schemaName, engine: engine) + "." + name
    }
}
