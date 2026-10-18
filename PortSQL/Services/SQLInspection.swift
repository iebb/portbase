import Foundation

/// Checks a script against the schema, as DataGrip flags unresolved names: a table in FROM, JOIN, UPDATE,
/// or INTO that the database doesn't have, with the closest name it does have.
enum SQLInspection {
    struct UnknownTable: Equatable {
        let name: String
        let suggestion: String?
    }

    /// Names that every engine accepts without a table of that name.
    private static let builtIns: Set<String> = ["dual", "sqlite_master", "sqlite_schema", "sqlite_sequence", "sqlite_temp_master", "pragma_table_info"]

    static func unknownTables(in sql: String, catalog: [SchemaTableDescriptor], engine: DatabaseEngine) -> [UnknownTable] {
        guard !catalog.isEmpty else { return [] }
        let tokens = SQLEditingService.tokens(sql, engine: engine)
        let names = Set(catalog.flatMap { [$0.name.lowercased(), $0.displayName.lowercased()] })
        let schemas = Set(catalog.map { $0.schemaName.lowercased() })
        // CTE names: an identifier followed by AS ( or by a column list and AS (.
        var ctes = Set<String>()
        for index in tokens.indices where tokens[index].isIdentifier {
            var next = index + 1
            if next < tokens.count, tokens[next].text == "(" {
                var depth = 0
                while next < tokens.count {
                    if tokens[next].text == "(" { depth += 1 }
                    if tokens[next].text == ")" { depth -= 1; if depth == 0 { break } }
                    next += 1
                }
                next += 1
            }
            if next + 1 < tokens.count, tokens[next].keyword == "AS", tokens[next + 1].text == "(" { ctes.insert(tokens[index].text.lowercased()) }
        }
        let reserved: Set<String> = ["SELECT", "WHERE", "SET", "VALUES", "LATERAL", "ONLY", "IF", "NOT", "EXISTS", "TABLE", "OUTFILE", "DUMPFILE"]
        var found: [UnknownTable] = []
        var seen = Set<String>()
        for index in tokens.indices where ["FROM", "JOIN", "UPDATE", "INTO"].contains(tokens[index].keyword) {
            var position = index + 1
            guard position < tokens.count, tokens[position].isIdentifier, !reserved.contains(tokens[position].keyword) else { continue }
            var name = tokens[position].text
            var schema: String?
            if position + 2 < tokens.count, tokens[position + 1].text == ".", tokens[position + 2].isIdentifier {
                schema = name
                name = tokens[position + 2].text
                position += 2
            }
            // A table function like generate_series(…), a variable, or a system schema isn't checked.
            if position + 1 < tokens.count, tokens[position + 1].text == "(" { continue }
            if name.hasPrefix("@") || name.hasPrefix("$") || name.hasPrefix(":") { continue }
            if let schema, !schemas.contains(schema.lowercased()) { continue }
            let lower = name.lowercased()
            let qualified = schema.map { $0.lowercased() + "." + lower }
            guard !names.contains(lower), qualified.map({ !names.contains($0) }) ?? true, !ctes.contains(lower),
                  !builtIns.contains(lower), seen.insert(lower).inserted else { continue }
            found.append(UnknownTable(name: schema.map { $0 + "." + name } ?? name, suggestion: closest(to: lower, in: catalog)))
        }
        return found
    }

    struct UnknownColumn: Equatable {
        /// As written, like o.totl.
        let reference: String
        let table: String
        let suggestion: String?
    }

    /// Qualified columns, like o.totl, whose qualifier is a table in scope at that spot that has no such
    /// column. Unqualified names and sources whose columns aren't known are left alone, so nothing is guessed.
    static func unknownColumns(in sql: String, catalog: [SchemaTableDescriptor], engine: DatabaseEngine) -> [UnknownColumn] {
        guard !catalog.isEmpty else { return [] }
        let tokens = SQLEditingService.tokens(sql, engine: engine)
        var found: [UnknownColumn] = []
        var seen = Set<String>()
        for index in tokens.indices where index + 2 < tokens.count && tokens[index + 1].text == "." {
            let qualifier = tokens[index], column = tokens[index + 2]
            guard qualifier.isIdentifier, column.isIdentifier,
                  index == 0 || tokens[index - 1].text != ".",
                  index + 3 >= tokens.count || tokens[index + 3].text != "." && tokens[index + 3].text != "(" else { continue }
            let cursor = qualifier.range.lowerBound.utf16Offset(in: sql)
            let sources = SQLSymbolCompletion.scope(query: sql, cursor: cursor, catalog: catalog, engine: engine).sources
            guard let source = sources.first(where: { $0.name.lowercased() == qualifier.text.lowercased() }),
                  let table = source.table, !source.isCTE, !table.columns.isEmpty else { continue }
            let name = column.text.lowercased()
            guard !table.columns.contains(where: { $0.name.lowercased() == name }) else { continue }
            let reference = qualifier.text + "." + column.text
            guard seen.insert(reference.lowercased()).inserted else { continue }
            found.append(UnknownColumn(reference: reference, table: table.name, suggestion: closest(to: name, among: table.columns.map(\.name))))
        }
        return found
    }

    static func hints(for sql: String, catalog: [SchemaTableDescriptor], engine: DatabaseEngine) -> [EditorHint] {
        let tables = unknownTables(in: sql, catalog: catalog, engine: engine).map { unknown in
            EditorHint(title: L10n.format("Unknown table “%@”", unknown.name),
                       message: unknown.suggestion.map { L10n.format("It isn't in this database. Did you mean “%@”?", $0) }
                           ?? L10n.text("It isn't in this database, or the table list needs refreshing."),
                       severity: .warning)
        }
        let columns = unknownColumns(in: sql, catalog: catalog, engine: engine).map { unknown in
            EditorHint(title: L10n.format("Unknown column “%@”", unknown.reference),
                       message: unknown.suggestion.map { L10n.format("%1$@ has no such column. Did you mean “%2$@”?", unknown.table, $0) }
                           ?? L10n.format("%@ has no such column.", unknown.table),
                       severity: .warning)
        }
        return Array((tables + columns).prefix(3))
    }

    /// The table name within a small edit distance, for typos like ordres or custmers.
    private static func closest(to name: String, in catalog: [SchemaTableDescriptor]) -> String? {
        closest(to: name, among: catalog.map(\.name))
    }

    private static func closest(to name: String, among candidates: [String]) -> String? {
        let limit = max(1, min(3, name.count / 3))
        var best: (name: String, distance: Int)?
        for candidate in candidates {
            let edits = distance(name, candidate.lowercased())
            guard edits <= limit else { continue }
            if let current = best, current.distance < edits || (current.distance == edits && current.name <= candidate) { continue }
            best = (candidate, edits)
        }
        return best?.name
    }

    /// Levenshtein distance, counting a swap of neighbors as one edit.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1) }
            }
        }
        return table[a.count][b.count]
    }
}
