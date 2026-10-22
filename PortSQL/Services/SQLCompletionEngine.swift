import Foundation

/// One completion: what the list shows and what accepting it does to the text.
struct SQLCompletionItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case keyword, table, view, cte, column, alias, function, join, snippet, schema, value, operation

        var symbol: String {
            switch self {
            case .keyword: "textformat"
            case .table: "tablecells"
            case .view: "eye"
            case .cte: "curlybraces"
            case .column: "list.bullet.indent"
            case .alias: "character.cursor.ibeam"
            case .function: "function"
            case .join: "arrow.triangle.merge"
            case .snippet: "text.badge.plus"
            case .schema: "folder"
            case .value: "number"
            case .operation: "equal"
            }
        }
    }

    let kind: Kind
    let label: String
    var detail: String?
    /// The table a table or INSERT item stands for, so its detail is written only if the item is shown.
    var tableID: UUID?
    /// The text that replaces the word being typed.
    let insertion: String
    /// Where the caret lands, counted back from the end of the insertion, such as inside parentheses.
    var caretFromEnd = 0
    /// A range of the whole text (UTF-16) to replace instead of the word being typed, as expanding `*` does.
    var replacing: NSRange?
    /// Text added elsewhere, such as the FROM clause for a column picked before there is one.
    var addition: SQLTextAddition?
    var score = 0

    var id: String { kind.rawValue + "|" + label + "|" + insertion }
}

struct SQLTextAddition: Hashable {
    /// A UTF-16 location in the whole text.
    let location: Int
    let text: String
}

/// The function call the caret is inside, for a parameter hint like DataGrip's.
struct SQLSignatureHint: Equatable {
    let name: String
    /// The parameters as the signature names them, such as ["'day'", "timestamp"].
    let parameters: [String]
    /// The parameter the caret is on.
    let argument: Int
}

/// The completions at the caret and the word they replace.
struct SQLCompletionResult: Equatable {
    var items: [SQLCompletionItem]
    /// The word being typed, which an item's insertion replaces (UTF-16, in the whole text).
    var fragmentRange: NSRange
    var fragment: String
    /// Whether the list should open on its own as the user types; otherwise only on request.
    var opensAutomatically: Bool
    var signature: SQLSignatureHint? = nil

    static let empty = SQLCompletionResult(items: [], fragmentRange: NSRange(location: 0, length: 0), fragment: "", opensAutomatically: false)
}

/// How often each completion has been accepted, so the ones a person uses rise to the top, as
/// DataGrip ranks by use. Kept on this device.
enum SQLCompletionUsage {
    private static let key = "Portbase.completionUsage"
    private static let limit = 400

    static func key(for item: SQLCompletionItem) -> String { item.kind.rawValue + "|" + item.insertion.lowercased() }

    /// Read from defaults once and kept, since completion asks on every keystroke.
    @MainActor private static var cached: [String: Int]?

    @MainActor static func counts() -> [String: Int] {
        if let cached { return cached }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        cached = stored
        return stored
    }

    @MainActor static func record(_ item: SQLCompletionItem) {
        var counts = counts()
        counts[key(for: item), default: 0] += 1
        // Keep the most used when the list grows long.
        if counts.count > limit {
            counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(limit * 3 / 4).map { ($0.key, $0.value) })
        }
        cached = counts
        UserDefaults.standard.set(counts, forKey: key)
    }
}

/// Context-aware SQL completion, in the spirit of DataGrip and DBeaver: it works out which clause of which
/// statement the caret is in, which tables and aliases are in scope there, and what can come next, then
/// offers tables, columns with their types, aliases, joins along likely keys, functions for the engine,
/// operators, keywords, and snippets, ranked by how well they match what has been typed.
enum SQLCompletionEngine {
    static func complete(_ text: String, cursor: Int, catalog: [SchemaTableDescriptor], activeDatabase: String?,
                         engine: DatabaseEngine, limit: Int = 40, usage: [String: Int] = [:]) -> SQLCompletionResult {
        let length = text.utf16.count
        let cursor = max(0, min(cursor, length))
        let caretIndex = String.Index(utf16Offset: cursor, in: text)
        // Inside a string or comment there's nothing to complete; inside a quoted identifier there is.
        let protected = SQLEditingService.protectedRanges(in: text, engine: engine)
        if let span = protected.first(where: { $0.lowerBound < caretIndex && caretIndex < $0.upperBound || ($0.lowerBound < caretIndex && $0.upperBound == caretIndex && !isClosed($0, in: text)) }),
           !isIdentifierQuote(text[span.lowerBound], engine: engine) {
            return .empty
        }

        let statementRange = SQLEditingService.statement(in: text, atUTF16: cursor, engine: engine) ?? text.startIndex..<text.endIndex
        // The statement may end before the caret, as with trailing whitespace; complete from its start.
        let start = min(statementRange.lowerBound, caretIndex)
        let end = max(statementRange.upperBound, caretIndex)
        let sql = String(text[start..<end])
        let base = text[..<start].utf16.count
        let localCaret = String.Index(utf16Offset: cursor - base, in: sql)

        let fragment = SQLSymbolCompletion.fragment(in: sql, at: localCaret)
        let fragmentStart = cursor - fragment.utf16.count
        let fragmentRange = NSRange(location: fragmentStart, length: fragment.utf16.count)
        let tokens = Lexer.tokens(String(sql[..<String.Index(utf16Offset: fragmentStart - base, in: sql)]), engine: engine)
        let scope = SQLSymbolCompletion.scope(query: text, cursor: cursor, catalog: catalog, engine: engine)
        var context = Context(sql: sql, tokens: tokens, fragment: fragment, fragmentStart: fragmentStart, statementBase: base,
                              statementEnd: base + sql.utf16.count, sources: scope.sources, ctes: scope.ctes, catalog: catalog,
                              activeDatabase: activeDatabase, engine: engine)
        var items = context.candidates()
        if !usage.isEmpty {
            for index in items.indices {
                // Enough to reorder items of the same kind, not to lift one past a better fit for the context.
                items[index].score += min(usage[SQLCompletionUsage.key(for: items[index])] ?? 0, 8) * 12
            }
        }
        items = rank(items, fragment: context.typedName)
        var seen = Set<String>()
        items = items.filter { seen.insert($0.kind.rawValue + "|" + $0.insertion.lowercased()).inserted }
        // Details like "12 columns · 3,400 rows" cost a plural lookup each, so only the items shown get one.
        var shown = Array(items.prefix(limit))
        context.describeTables(in: &shown)
        return SQLCompletionResult(items: shown, fragmentRange: fragmentRange, fragment: fragment,
                                   opensAutomatically: context.opensAutomatically && context.opensWithoutTyping && !items.isEmpty,
                                   signature: signature(in: tokens, engine: engine))
    }

    /// The function call around the caret and which of its arguments the caret is on.
    static func signature(in tokens: [Token], engine: DatabaseEngine) -> SQLSignatureHint? {
        var balance = 0
        var commas = 0
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            if token.text == ")" { balance += 1; continue }
            if token.text == "(" {
                if balance > 0 { balance -= 1; continue }
                guard index > 0, tokens[index - 1].kind == .word else { return nil }
                let name = tokens[index - 1].text.uppercased()
                guard let function = SQLFunctionCatalog.functions(for: engine).first(where: { $0.name.uppercased() == name && $0.takesArguments }) else { return nil }
                let parameters = SQLFunctionCatalog.parameters(of: function.signature)
                guard !parameters.isEmpty else { return nil }
                return SQLSignatureHint(name: function.name, parameters: parameters, argument: min(commas, parameters.count - 1))
            }
            if token.text == ",", balance == 0 { commas += 1 }
        }
        return nil
    }

    /// The edits accepting an item makes, last first so each range is still valid when it's applied, and
    /// where the caret lands afterwards. Editors apply these themselves so accepting can be undone.
    static func edits(for item: SQLCompletionItem, in text: String, result: SQLCompletionResult) -> (edits: [(range: NSRange, text: String)], cursor: Int)? {
        let source = text as NSString
        let target = item.replacing ?? result.fragmentRange
        guard target.location >= 0, NSMaxRange(target) <= source.length else { return nil }
        var insertion = item.insertion
        // Keep words apart when a keyword or name lands right after another word.
        if target.location > 0, item.replacing == nil, let first = insertion.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) || first == "_" {
            let previous = source.character(at: target.location - 1)
            if let scalar = Unicode.Scalar(previous), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == ")" {
                insertion = " " + insertion
            }
        }
        var edits = [(range: target, text: insertion)]
        var cursor = target.location + (insertion as NSString).length - item.caretFromEnd
        if let addition = item.addition, addition.location >= 0, addition.location <= source.length {
            let addedLength = (addition.text as NSString).length
            if addition.location >= NSMaxRange(target) {
                edits.insert((NSRange(location: addition.location, length: 0), addition.text), at: 0)
            } else {
                edits.append((NSRange(location: addition.location, length: 0), addition.text))
                cursor += addedLength
            }
        }
        return (edits, cursor)
    }

    /// Applies an item to the text and returns the new text and caret.
    static func apply(_ item: SQLCompletionItem, to text: String, result: SQLCompletionResult) -> (text: String, cursor: Int) {
        guard let plan = edits(for: item, in: text, result: result) else { return (text, NSMaxRange(result.fragmentRange)) }
        var updated = text as NSString
        for edit in plan.edits { updated = updated.replacingCharacters(in: edit.range, with: edit.text) as NSString }
        return (updated as String, plan.cursor)
    }

    // MARK: Ranking

    /// Orders items by how well they match the typed word, then by the context's own preference.
    /// Matches: whole name, prefix, a word inside a snake_case or camelCase name, initials ("cid" for
    /// customer_id), then letters in order.
    static func rank(_ items: [SQLCompletionItem], fragment: String) -> [SQLCompletionItem] {
        let needle = fragment.lowercased()
        return items.compactMap { item -> SQLCompletionItem? in
            guard !needle.isEmpty else { return item }
            guard let quality = matchQuality(name: matchName(item), needle: needle) else { return nil }
            var ranked = item
            ranked.score += quality
            return ranked
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.label.count != rhs.label.count { return lhs.label.count < rhs.label.count }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func matchName(_ item: SQLCompletionItem) -> String {
        // A qualified column matches on its own name; a join on its table.
        switch item.kind {
        case .column, .alias, .table, .view, .cte:
            return (item.label.split(separator: ".").last.map(String.init) ?? item.label).lowercased()
        default:
            return item.label.lowercased()
        }
    }

    static func matchQuality(name: String, needle: String) -> Int? {
        if name == needle { return 1_000 }
        if name.hasPrefix(needle) { return 800 }
        let parts = words(in: name)
        if parts.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 600 }
        if matchesInitials(parts[...], needle[...]) { return 450 }
        var remaining = needle[...]
        for character in name where character == remaining.first { remaining = remaining.dropFirst() }
        return remaining.isEmpty && needle.count >= 2 ? 200 : nil
    }

    /// Splits snake_case, kebab, dotted, and camelCase names into lowercase words.
    private static func words(in name: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousLower = false
        for character in name {
            if character == "_" || character == "." || character == "-" || character == " " {
                if !current.isEmpty { result.append(current.lowercased()); current = "" }
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower, !current.isEmpty { result.append(current.lowercased()); current = "" }
            current.append(character)
            previousLower = character.isLowercase
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result.isEmpty ? [name] : result
    }

    /// Whether the needle reads as the leading letters of successive words, like "cid" or "custid" for customer_id.
    private static func matchesInitials(_ parts: ArraySlice<String>, _ needle: Substring) -> Bool {
        guard !needle.isEmpty else { return true }
        guard let part = parts.first else { return false }
        var taken = 0
        for (a, b) in zip(part, needle) where a == b { taken += 1; if taken == part.count { break } }
        guard taken > 0 else { return false }
        for count in stride(from: taken, through: 1, by: -1) where matchesInitials(parts.dropFirst(), needle.dropFirst(count)) {
            return true
        }
        return false
    }

    // MARK: Helpers

    private static func isIdentifierQuote(_ character: Character, engine: DatabaseEngine) -> Bool {
        character == "`" || (character == "\"" && !engine.isMySQLFamily) || (character == "[" && engine == .sqlite)
    }

    /// Whether a string, comment, or quoted name is finished, so a caret right after it is outside it.
    private static func isClosed(_ span: Range<String.Index>, in text: String) -> Bool {
        let body = text[span]
        if body.hasPrefix("--") || body.hasPrefix("#") { return body.hasSuffix("\n") }
        if body.hasPrefix("/*") { return body.count > 3 && body.hasSuffix("*/") }
        guard let first = body.first, let last = body.last, body.count > 1 else { return false }
        switch first {
        case "'", "\"", "`": return last == first
        case "[": return last == "]"
        default: return true
        }
    }
}

// MARK: - Tokens

extension SQLCompletionEngine {
    struct Token {
        enum Kind { case word, quoted, string, number, symbol }
        let kind: Kind
        let text: String
        /// Parenthesis depth the token sits at.
        let depth: Int
        var keyword: String { kind == .word ? text.uppercased() : "" }
        var isName: Bool { (kind == .word && !Lexer.reserved.contains(keyword)) || kind == .quoted }
    }

    enum Lexer {
        static let reserved: Set<String> = [
            "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "NATURAL", "ON", "USING",
            "GROUP", "ORDER", "BY", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT", "AS", "AND", "OR", "NOT", "IN",
            "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "CASE", "WHEN", "THEN", "ELSE", "END", "INSERT", "INTO",
            "VALUES", "UPDATE", "SET", "DELETE", "RETURNING", "WITH", "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX",
            "ASC", "DESC", "NULLS", "FIRST", "LAST", "TRUE", "FALSE", "TRUNCATE", "EXPLAIN", "DESCRIBE", "SHOW", "LATERAL",
            "WINDOW", "OVER", "PARTITION", "INTERSECT", "EXCEPT", "FETCH", "FOR", "PRAGMA", "REPLACE", "IGNORE", "DUPLICATE",
            "KEY", "CONFLICT", "DO", "NOTHING", "RECURSIVE", "MATERIALIZED", "ADD", "COLUMN", "RENAME", "TO", "PRIMARY",
            "REFERENCES", "DEFAULT", "CHECK", "UNIQUE", "CONSTRAINT", "FOREIGN", "IF", "CASCADE", "PREWHERE", "FINAL", "SAMPLE",
        ]

        static func tokens(_ sql: String, engine: DatabaseEngine) -> [Token] {
            let spans = SQLEditingService.protectedRanges(in: sql, engine: engine)
            var spanIndex = 0
            var index = sql.startIndex
            var depth = 0
            var result: [Token] = []
            while index < sql.endIndex {
                if spanIndex < spans.count, spans[spanIndex].lowerBound == index {
                    let span = spans[spanIndex]
                    let text = String(sql[span])
                    if let first = text.first {
                        if first == "`" || (first == "\"" && !engine.isMySQLFamily) || (first == "[" && engine == .sqlite) {
                            let close: Character = first == "[" ? "]" : first
                            let name = String(text.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: String(close)))
                            result.append(Token(kind: .quoted, text: name, depth: depth))
                        } else if !(text.hasPrefix("--") || text.hasPrefix("/*") || text.hasPrefix("#")) {
                            result.append(Token(kind: .string, text: text, depth: depth))
                        }
                    }
                    index = span.upperBound; spanIndex += 1
                    continue
                }
                let character = sql[index]
                if character.isWhitespace { index = sql.index(after: index); continue }
                let start = index
                if character.isLetter || character == "_" || character == "$" || character == "@" {
                    repeat { index = sql.index(after: index) }
                    while index < sql.endIndex && (sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "$")
                    result.append(Token(kind: .word, text: String(sql[start..<index]), depth: depth))
                } else if character.isNumber {
                    repeat { index = sql.index(after: index) }
                    while index < sql.endIndex && (sql[index].isNumber || sql[index] == ".")
                    result.append(Token(kind: .number, text: String(sql[start..<index]), depth: depth))
                } else {
                    index = sql.index(after: index)
                    // Two-character operators read as one.
                    if index < sql.endIndex, ["<=", ">=", "<>", "!=", "||", "::"].contains(String(sql[start...index])) {
                        index = sql.index(after: index)
                    }
                    let text = String(sql[start..<index])
                    if text == ")" { depth = max(0, depth - 1) }
                    result.append(Token(kind: .symbol, text: text, depth: depth))
                    if text == "(" { depth += 1 }
                }
            }
            return result
        }
    }
}

// MARK: - Clause fields

/// A suggestion for a WHERE or ORDER BY field, with the field's whole text once it's accepted.
struct SQLClauseSuggestion: Identifiable, Hashable {
    let kind: SQLCompletionItem.Kind
    let label: String
    let detail: String?
    let completedText: String
    var id: String { kind.rawValue + "|" + label + "|" + completedText }
}

extension SQLCompletionEngine {
    enum ClauseKind { case filter, sort }

    /// Completions for a field holding only a clause's body, completed as if it followed
    /// `SELECT * FROM table WHERE` (or ORDER BY), with the caret at the end of the text.
    static func clauseSuggestions(_ text: String, kind: ClauseKind, table: SchemaTableDescriptor, catalog: [SchemaTableDescriptor],
                                  activeDatabase: String?, engine: DatabaseEngine, limit: Int = 12) -> [SQLClauseSuggestion] {
        let quote = { SQLSymbolCompletion.quote($0, engine: engine) }
        let reference = table.schemaName.isEmpty ? quote(table.name) : quote(table.schemaName) + "." + quote(table.name)
        let prefix = "SELECT * FROM " + reference + (kind == .filter ? " WHERE " : " ORDER BY ")
        let full = prefix + text
        let offset = (prefix as NSString).length
        let scopeCatalog = catalog.contains { $0.id == table.id } ? catalog : catalog + [table]
        let result = complete(full, cursor: (full as NSString).length, catalog: scopeCatalog, activeDatabase: activeDatabase,
                              engine: engine, limit: limit * 2)
        return result.items
            .filter { $0.replacing == nil && $0.addition == nil }
            .prefix(limit)
            .compactMap { item in
                let applied = apply(item, to: full, result: result).text as NSString
                guard applied.length >= offset else { return nil }
                return SQLClauseSuggestion(kind: item.kind, label: item.label, detail: item.detail,
                                           completedText: applied.substring(from: offset))
            }
    }
}
