import Foundation

struct SQLStructureToken {
    let text: String
    let range: Range<String.Index>
    let quoted: Bool
    var keyword: String { quoted ? "" : text.uppercased() }
    var isIdentifier: Bool { quoted || text.first.map { $0.isLetter || $0 == "_" } == true }
}

extension SQLEditingService {
    static func tokens(_ sql: String, engine: DatabaseEngine) -> [SQLStructureToken] {
        let spans = protectedRanges(in: sql, engine: engine)
        var spanIndex = 0
        var index = sql.startIndex
        var result: [SQLStructureToken] = []
        while index < sql.endIndex {
            if spanIndex < spans.count, spans[spanIndex].lowerBound == index {
                let span = spans[spanIndex]
                let delimiter = sql[index]
                if delimiter == "`" || (delimiter == "\"" && !engine.isMySQLFamily) || (delimiter == "[" && engine == .sqlite) {
                    let endDelimiter: Character = delimiter == "[" ? "]" : delimiter
                    let raw = String(sql[span].dropFirst())
                    let name = raw.last == endDelimiter ? String(raw.dropLast()) : raw
                    result.append(SQLStructureToken(text: name.replacingOccurrences(of: String(repeating: String(endDelimiter), count: 2), with: String(endDelimiter)), range: span, quoted: true))
                }
                index = span.upperBound; spanIndex += 1
                continue
            }
            if sql[index].isWhitespace { index = sql.index(after: index); continue }
            let start = index
            if sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "$" {
                repeat { index = sql.index(after: index) }
                while index < sql.endIndex && (sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "$")
            } else { index = sql.index(after: index) }
            result.append(SQLStructureToken(text: String(sql[start..<index]), range: start..<index, quoted: false))
        }
        return result
    }

    static func codeWords(_ sql: String, engine: DatabaseEngine) -> [String] {
        tokens(sql, engine: engine).filter(\.isIdentifier).map { $0.text.uppercased() }
    }

    static func statementRanges(in sql: String, engine: DatabaseEngine) -> [Range<String.Index>] {
        if engine == .sqlite { return SQLiteStatementService.statementRanges(in: sql) }
        guard engine.isRelational else { return sql.isEmpty ? [] : [sql.startIndex..<sql.endIndex] }
        let all = tokens(sql, engine: engine)
        guard !all.isEmpty else { return [] }
        if engine.isMySQLFamily,
           protectedRanges(in: sql, engine: engine) != protectedRanges(in: sql, engine: engine, backslashEscapes: false) {
            return [sql.startIndex..<sql.endIndex]
        }
        // Stored program bodies may contain unquoted semicolons and custom delimiters.
        if engine.isMySQLFamily, all.first?.keyword == "CREATE", all.prefix(8).contains(where: { ["FUNCTION", "PROCEDURE", "TRIGGER", "EVENT"].contains($0.keyword) }) {
            return [sql.startIndex..<sql.endIndex]
        }
        var result: [Range<String.Index>] = []
        var start = sql.startIndex
        var depth = 0
        var hasCode = false
        for token in all {
            if token.text == "(" && !token.quoted { depth += 1 }
            if token.text == ")" && !token.quoted { depth = max(0, depth - 1) }
            if token.text == ";", !token.quoted, depth == 0 {
                if hasCode { result.append(trimmedRange(start..<token.range.upperBound, in: sql)) }
                start = token.range.upperBound; hasCode = false
            } else { hasCode = true }
        }
        if hasCode { result.append(trimmedRange(start..<sql.endIndex, in: sql)) }
        return result
    }

    static func statement(in sql: String, atUTF16 offset: Int, engine: DatabaseEngine) -> Range<String.Index>? {
        let index = String.Index(utf16Offset: max(0, min(offset, sql.utf16.count)), in: sql)
        let ranges = statementRanges(in: sql, engine: engine)
        return ranges.first(where: { $0.upperBound > index }) ?? ranges.last
    }

    private static func trimmedRange(_ range: Range<String.Index>, in sql: String) -> Range<String.Index> {
        var start = range.lowerBound, end = range.upperBound
        while start < end, sql[start].isWhitespace { start = sql.index(after: start) }
        while end > start, sql[sql.index(before: end)].isWhitespace { end = sql.index(before: end) }
        return start..<end
    }
}

/// Resolves completion symbols from SQL tokens, including quoted names and CTE projections.
enum SQLSymbolCompletion {
    static func suggestions(query: String, cursor: Int, catalog: [SchemaTableDescriptor], engine: DatabaseEngine) -> [String] {
        let selected = SQLEditingService.statement(in: query, atUTF16: cursor, engine: engine) ?? query.startIndex..<query.endIndex
        let sql = String(query[selected])
        let offset = max(0, cursor - query[..<selected.lowerBound].utf16.count)
        let all = SQLEditingService.tokens(sql, engine: engine)
        let caret = String.Index(utf16Offset: min(offset, sql.utf16.count), in: sql)
        let scope = aliasScopes(in: sql, tokens: all, caret: caret)
        let visibleScopes = Set(scope.visible)
        var sources: [String: [String]] = [:]
        for table in catalog { sources[table.name] = table.columns.map(\.name); sources[table.displayName] = table.columns.map(\.name) }
        var cteNames: [String] = []
        func closing(_ start: Int) -> Int? {
            var depth = 0
            for i in start..<all.count {
                if all[i].text == "(" { depth += 1 }
                if all[i].text == ")" { depth -= 1; if depth == 0 { return i } }
            }
            return nil
        }
        if all.first?.keyword == "WITH" {
            var i = all.dropFirst().first?.keyword == "RECURSIVE" ? 2 : 1
            while i < all.count, all[i].isIdentifier {
                let name = all[i].text; i += 1
                var fields: [String] = []
                if i < all.count, all[i].text == "(", let end = closing(i) {
                    fields = all[(i + 1)..<end].filter(\.isIdentifier).map(\.text); i = end + 1
                }
                guard i < all.count, all[i].keyword == "AS" else { break }; i += 1
                while i < all.count, ["NOT", "MATERIALIZED"].contains(all[i].keyword) { i += 1 }
                guard i < all.count, all[i].text == "(", let end = closing(i) else { break }
                if fields.isEmpty {
                    let body = Array(all[(i + 1)..<end])
                    if let select = body.firstIndex(where: { $0.keyword == "SELECT" }) {
                        var depth = 0, projection: [SQLStructureToken] = []
                        func addField() {
                            if let asIndex = projection.lastIndex(where: { $0.keyword == "AS" }), asIndex + 1 < projection.count {
                                fields.append(projection[asIndex + 1].text)
                            } else if let last = projection.last, last.isIdentifier { fields.append(last.text) }
                            else if projection.contains(where: { $0.text == "*" }) {
                                if let from = body.firstIndex(where: { $0.keyword == "FROM" }), from + 1 < body.count {
                                    fields += sources[body[from + 1].text] ?? []
                                }
                            }
                            projection = []
                        }
                        for token in body.dropFirst(select + 1) {
                            if token.keyword == "FROM", depth == 0 { addField(); break }
                            if token.text == ",", depth == 0 { addField(); continue }
                            if token.text == "(" { depth += 1 }
                            if token.text == ")" { depth -= 1 }
                            projection.append(token)
                        }
                        if !projection.isEmpty { addField() }
                    }
                }
                sources[name] = fields; cteNames.append(name)
                i = end + 1
                guard i < all.count, all[i].text == "," else { break }; i += 1
            }
        }
        let reserved = Set(["WHERE", "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "ON", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "RETURNING", "SET", "VALUES", "FOR"])
        var aliasesByScope: [Int: [String: [String]]] = [:]
        for i in all.indices where visibleScopes.contains(scope.owners[i]) && ["FROM", "JOIN", "UPDATE", "INTO"].contains(all[i].keyword) {
            var j = i + 1
            guard j < all.count, all[j].isIdentifier else { continue }
            var reference = all[j].text; let short = reference; j += 1
            if j + 1 < all.count, all[j].text == ".", all[j + 1].isIdentifier { reference += "." + all[j + 1].text; j += 2 }
            // An unresolved local source still shadows an outer alias with the same name.
            let fields = sources[reference] ?? sources[short] ?? []
            aliasesByScope[scope.owners[i], default: [:]][reference] = fields
            if j < all.count, all[j].keyword == "AS" { j += 1 }
            if j < all.count, all[j].isIdentifier, !reserved.contains(all[j].keyword) {
                aliasesByScope[scope.owners[i], default: [:]][all[j].text] = fields
            }
        }
        var aliases: [String: [String]] = [:]
        for scopeID in scope.visible.reversed() {
            for (alias, fields) in aliasesByScope[scopeID] ?? [:] { aliases[alias] = fields }
        }
        let before = all.filter { $0.range.lowerBound < caret }
        let fragment = fragment(in: sql, at: caret)
        if let dot = fragment.lastIndex(of: ".") {
            let qualifier = unquote(String(fragment[..<dot]))
            let partial = unquote(String(fragment[fragment.index(after: dot)...]))
            let fields = aliases[qualifier] ?? sources[qualifier] ?? []
            return fields.filter { partial.isEmpty || $0.range(of: partial, options: [.anchored, .caseInsensitive]) != nil }.map { quote(qualifier, engine: engine) + "." + quote($0, engine: engine) }
        }
        let prefix = unquote(fragment)
        let tableContext = ["FROM", "JOIN", "INTO", "UPDATE"].contains(before.dropLast(fragment.isEmpty ? 0 : 1).last?.keyword ?? "")
        let functions = engine == .postgresql
            ? ["COALESCE(", "NULLIF(", "LOWER(", "UPPER(", "ROUND(", "DATE_TRUNC(", "EXTRACT(", "JSONB_EXTRACT_PATH_TEXT(", "STRING_AGG(", "NOW()", "ROW_NUMBER() OVER ("]
            : ["COALESCE(", "IFNULL(", "NULLIF(", "LOWER(", "UPPER(", "ROUND(", "DATE_FORMAT(", "JSON_EXTRACT(", "GROUP_CONCAT(", "NOW()", "ROW_NUMBER() OVER ("]
        let quotedTables = catalog.flatMap { [quote($0.name, engine: engine), quote($0.schemaName, engine: engine) + "." + quote($0.name, engine: engine)] }
        let candidates = tableContext ? cteNames.map { quote($0, engine: engine) } + quotedTables
            : aliases.keys.sorted().flatMap { alias in (aliases[alias] ?? []).map { quote(alias, engine: engine) + "." + quote($0, engine: engine) } }
                + cteNames.flatMap { (sources[$0] ?? []).map { quote($0, engine: engine) } } + functions
        return candidates.filter { prefix.isEmpty || unquote($0).range(of: prefix, options: [.anchored, .caseInsensitive]) != nil }
    }

    private struct QueryScope {
        let parent: Int?
        let start: String.Index
        var end: String.Index
        let baseDepth: Int
        let inheritsParentAliases: Bool
    }

    private static func aliasScopes(in sql: String, tokens: [SQLStructureToken], caret: String.Index) -> (owners: [Int], visible: [Int]) {
        var scopes = [QueryScope(parent: nil, start: sql.startIndex, end: sql.endIndex, baseDepth: 0, inheritsParentAliases: false)]
        var parentheses: [Int?] = []
        var owners = Array(repeating: 0, count: tokens.count)
        var depths = Array(repeating: 0, count: tokens.count)
        var current = 0
        let queryStarts = Set(["SELECT", "WITH", "VALUES", "TABLE", "INSERT", "UPDATE", "DELETE"])
        let clauseStarts = Set(["SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "RETURNING", "VALUES", "SET"])

        for index in tokens.indices {
            let token = tokens[index]
            owners[index] = current
            depths[index] = parentheses.count
            guard !token.quoted else { continue }
            if token.text == "(" {
                let startsQuery = index + 1 < tokens.count && queryStarts.contains(tokens[index + 1].keyword)
                if startsQuery {
                    let previous = index > 0 ? tokens[index - 1].keyword : ""
                    var inheritsParent = !["AS", "FROM", "JOIN"].contains(previous)
                    // A comma-separated FROM subquery, like a non-LATERAL JOIN subquery,
                    // cannot see aliases declared by its immediate containing query.
                    if index > 0, tokens[index - 1].text == ",", parentheses.count == scopes[current].baseDepth {
                        let clause = (0..<index).reversed().first {
                            owners[$0] == current && depths[$0] == scopes[current].baseDepth && clauseStarts.contains(tokens[$0].keyword)
                        }
                        if let clause, tokens[clause].keyword == "FROM" { inheritsParent = false }
                    }
                    let next = scopes.count
                    scopes.append(QueryScope(parent: current, start: token.range.upperBound, end: sql.endIndex,
                        baseDepth: parentheses.count + 1, inheritsParentAliases: inheritsParent))
                    parentheses.append(next)
                    current = next
                } else { parentheses.append(nil) }
            } else if token.text == ")", let closed = parentheses.popLast(), let scopeID = closed {
                scopes[scopeID].end = token.range.lowerBound
                current = scopes[scopeID].parent ?? 0
            }
        }

        let active = scopes.indices.reversed().first { scopes[$0].start <= caret && caret <= scopes[$0].end } ?? 0
        var visible: [Int] = []
        var next: Int? = active
        var include = true
        while let scopeID = next {
            if include { visible.append(scopeID) }
            include = scopes[scopeID].inheritsParentAliases
            next = scopes[scopeID].parent
        }
        return (owners, visible)
    }

    static func fragment(in text: String, at end: String.Index) -> String {
        let prefix = String(text[..<end])
        if let bracket = prefix.range(of: #"(?:[\p{L}\p{N}_$]+\.)?\[[^\]]*\]?(?:\.[\p{L}\p{N}_$]*)?$"#, options: .regularExpression) { return String(prefix[bracket]) }
        let pattern = #"(?:[\p{L}\p{N}_$]+|\"(?:[^\"]|\"\")*\"|`(?:[^`]|``)*`)(?:\.(?:[\p{L}\p{N}_$]*|\"[^\"]*\"?|`[^`]*`?))?$|[\"`][^\"`]*$"#
        guard let range = prefix.range(of: pattern, options: .regularExpression) else { return "" }
        return String(prefix[range])
    }

    static func quote(_ value: String, engine: DatabaseEngine) -> String {
        if value.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil,
           !["select", "from", "where", "group", "order", "user", "table", "limit"].contains(value) { return value }
        let delimiter = engine.isMySQLFamily ? "`" : "\""
        return delimiter + value.replacingOccurrences(of: delimiter, with: delimiter + delimiter) + delimiter
    }

    private static func unquote(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }
}
