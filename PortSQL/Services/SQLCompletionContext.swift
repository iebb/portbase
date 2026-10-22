import Foundation

extension SQLCompletionEngine {
    /// What the caret is in the middle of, and what can come next there.
    struct Context {
        let sql: String
        let tokens: [Token]
        let fragment: String
        let fragmentStart: Int
        let statementBase: Int
        let statementEnd: Int
        let sources: [SQLScopeSource]
        let ctes: [(name: String, fields: [String])]
        let catalog: [SchemaTableDescriptor]
        let activeDatabase: String?
        let engine: DatabaseEngine
        /// How many tables share each name, counted once rather than per table offered.
        private let nameCounts: [String: Int]

        private(set) var opensAutomatically = true

        init(sql: String, tokens: [Token], fragment: String, fragmentStart: Int, statementBase: Int, statementEnd: Int,
             sources: [SQLScopeSource], ctes: [(name: String, fields: [String])], catalog: [SchemaTableDescriptor],
             activeDatabase: String?, engine: DatabaseEngine) {
            self.sql = sql
            self.tokens = tokens
            self.fragment = fragment
            self.fragmentStart = fragmentStart
            self.statementBase = statementBase
            self.statementEnd = statementEnd
            self.sources = sources
            self.ctes = ctes
            self.catalog = catalog
            self.activeDatabase = activeDatabase
            self.engine = engine
            self.nameCounts = Dictionary(catalog.map { ($0.name.lowercased(), 1) }, uniquingKeysWith: +)
        }

        // MARK: Reading the context

        /// The name being typed, without quotes or a qualifier.
        var typedName: String {
            let name = fragment.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? fragment
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
        }

        /// The qualifier before a dot, as typed (quotes kept) and as a name.
        private var qualifier: (typed: String, name: String)? {
            guard let dot = fragment.lastIndex(of: ".") else { return nil }
            let typed = String(fragment[..<dot])
            return (typed, typed.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]")))
        }

        private var caretDepth: Int {
            guard let last = tokens.last else { return 0 }
            return last.depth + (last.text == "(" ? 1 : 0)
        }

        /// Tokens at the caret's depth or around it, skipping the insides of closed parentheses.
        private var visible: [Token] { tokens.filter { $0.depth <= caretDepth } }

        private var previous: Token? { tokens.last }
        private var beforePrevious: Token? { tokens.dropLast().last }

        private enum Clause { case none, select, from, join, on, whereClause, groupBy, having, orderBy, limit, set, values, into, update, delete, table, returning }

        private var clause: Clause {
            for (index, token) in visible.enumerated().reversed() {
                switch token.keyword {
                case "SELECT": return .select
                case "FROM": return visible.dropLast(visible.count - index).last?.keyword == "DELETE" ? .delete : .from
                case "JOIN": return .join
                case "ON", "USING": return .on
                case "WHERE", "PREWHERE": return .whereClause
                case "HAVING": return .having
                case "BY":
                    let before = index > 0 ? visible[index - 1].keyword : ""
                    if before == "GROUP" { return .groupBy }
                    if before == "ORDER" { return .orderBy }
                case "LIMIT", "OFFSET", "FETCH": return .limit
                case "SET": return .set
                case "VALUES": return .values
                case "INTO": return .into
                case "UPDATE": return .update
                case "DELETE": return .delete
                case "TABLE", "TRUNCATE", "DESCRIBE": return .table
                case "RETURNING": return .returning
                default: continue
                }
            }
            return .none
        }

        private var lowercaseKeywords: Bool {
            guard let first = tokens.first(where: { $0.kind == .word }) else { return false }
            return first.text == first.text.lowercased() && first.text != first.text.uppercased()
        }

        private func keyword(_ text: String) -> String { lowercaseKeywords ? text.lowercased() : text }

        /// Whether the statement has a FROM at its top level anywhere, before or after the caret.
        private var statementHasFrom: Bool {
            SQLEditingService.tokens(sql, engine: engine).contains { $0.keyword == "FROM" }
        }

        private var isAtStatementStart: Bool { previous == nil || previous?.text == ";" }

        private func endsExpression(_ token: Token?) -> Bool {
            guard let token else { return false }
            switch token.kind {
            case .string, .number, .quoted: return true
            case .symbol: return token.text == ")" || token.text == "*"
            case .word: return token.isName || ["NULL", "TRUE", "FALSE"].contains(token.keyword)
            }
        }

        private static let comparisonOperators: Set<String> = ["=", "<", ">", "<=", ">=", "<>", "!=", "LIKE", "ILIKE", "IN", "IS", "BETWEEN"]

        // MARK: Candidates

        /// Whether, with nothing typed yet, the list should still open: right after a keyword that's always
        /// followed by a name, as DataGrip does after FROM and JOIN.
        var opensWithoutTyping: Bool {
            guard typedName.isEmpty else { return true }
            if fragment.hasSuffix(".") { return true }
            return ["FROM", "JOIN", "ON", "INTO", "UPDATE"].contains(previous?.keyword ?? "")
        }

        mutating func candidates() -> [SQLCompletionItem] {
            if let qualifier { return qualifiedCandidates(qualifier) }
            // A type: after :: or CAST(… AS.
            if previous?.text == "::" || (previous?.keyword == "AS" && SQLCompletionEngine.signature(in: tokens, engine: engine)?.name.uppercased() == "CAST") {
                return typeItems()
            }
            if isAtStatementStart { opensAutomatically = !typedName.isEmpty; return statementStarts() }
            let prev = previous
            let prevKeyword = prev?.keyword ?? ""

            // A table name: after FROM, JOIN, INTO, UPDATE, TABLE, or a comma in FROM.
            if ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "TRUNCATE", "DESCRIBE"].contains(prevKeyword)
                || (prev?.text == "," && clause == .from) {
                var items: [SQLCompletionItem] = []
                if prevKeyword == "JOIN" { items += joinSuggestions() }
                items += tableItems(insertStatement: prevKeyword == "INTO" && visible.contains { $0.keyword == "INSERT" })
                return items
            }

            switch clause {
            case .from, .join, .update, .delete, .table:
                // After a table and its alias: what can follow.
                if endsExpression(prev) {
                    opensAutomatically = typedName.count >= 2
                    var items = keywordItems(clause == .join && !visible.reversed().prefix { $0.keyword != "JOIN" }.contains { $0.keyword == "ON" }
                        ? ["ON", "AS", "WHERE", "JOIN", "LEFT JOIN"] : ["WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "CROSS JOIN", "GROUP BY", "ORDER BY", "LIMIT", "AS"],
                        priority: 500)
                    if clause == .join { items += onSuggestions(prefixed: true) }
                    if clause == .update { items = keywordItems(["SET", "AS"], priority: 600) }
                    return items
                }
                return columnItems() + functionItems()
            case .on:
                if ["ON", "AND", "OR"].contains(prevKeyword) { return onSuggestions(prefixed: false) + columnItems() + functionItems() }
                return predicateCandidates(prev)
            case .whereClause, .having:
                return predicateCandidates(prev)
            case .select:
                return selectCandidates(prev)
            case .groupBy:
                if prevKeyword == "BY" || prev?.text == "," {
                    return groupBySnippet() + columnItems() + selectAliasItems()
                }
                opensAutomatically = typedName.count >= 1
                return keywordItems(["HAVING", "ORDER BY", "LIMIT"], priority: 500) + [symbolItem(",")]
            case .orderBy:
                if prevKeyword == "BY" || prev?.text == "," {
                    return selectAliasItems() + columnItems() + functionItems()
                }
                opensAutomatically = typedName.count >= 1
                var words = ["ASC", "DESC", "LIMIT"]
                if engine == .postgresql || engine == .sqlite { words += ["NULLS FIRST", "NULLS LAST"] }
                return keywordItems(words, priority: 600) + [symbolItem(",")]
            case .set:
                if prevKeyword == "SET" || prev?.text == "," { return columnItems(assigning: true) }
                if let prev, prev.isName { return [SQLCompletionItem(kind: .operation, label: "=", insertion: "= ", score: 900)] }
                opensAutomatically = typedName.count >= 1
                return keywordItems(["WHERE", "RETURNING"], priority: 600) + [symbolItem(",")]
            case .into:
                if caretDepth > 0, prev?.text == "(" || prev?.text == "," {
                    return (prev?.text == "(" ? allColumnsSnippet() : []) + columnItems()
                }
                if prev?.text == ")" || endsExpression(prev) { return keywordItems(["VALUES", "SELECT"], priority: 600) }
                return []
            case .values, .limit:
                opensAutomatically = false
                return []
            case .returning:
                return columnItems() + [SQLCompletionItem(kind: .keyword, label: "*", insertion: "*", score: 700)]
            case .none:
                return keywordItems(["SELECT", "FROM", "WHERE"], priority: 300) + columnItems()
            }
        }

        private func statementStarts() -> [SQLCompletionItem] {
            var starts = ["SELECT", "INSERT INTO", "UPDATE", "DELETE FROM", "WITH", "EXPLAIN", "CREATE TABLE", "ALTER TABLE", "DROP TABLE"]
            switch engine {
            case .mysql, .mariadb: starts += ["SHOW TABLES", "SHOW CREATE TABLE", "TRUNCATE TABLE"]
            case .sqlite: starts += ["PRAGMA table_info("]
            case .postgresql: starts += ["TRUNCATE TABLE"]
            default: break
            }
            var items = keywordItems(starts, priority: 600)
            items.append(SQLCompletionItem(kind: .snippet, label: keyword("SELECT * FROM …"), detail: L10n.text("Browse a table"),
                                           insertion: keyword("SELECT * FROM "), score: 650))
            items.append(SQLCompletionItem(kind: .snippet, label: keyword("SELECT COUNT(*) FROM …"), detail: L10n.text("Count rows"),
                                           insertion: keyword("SELECT COUNT(*) FROM "), score: 620))
            return items
        }

        private func selectCandidates(_ prev: Token?) -> [SQLCompletionItem] {
            var items: [SQLCompletionItem] = []
            if prev?.text == "*", typedName.isEmpty, let star = starExpansion() { items.append(star) }
            if let prev, endsExpression(prev) {
                // After a column or expression: the FROM, an alias, or the next column.
                var words = ["AS"]
                if !statementHasFrom { words.insert("FROM", at: 0) }
                return items + keywordItems(words, priority: 700) + [symbolItem(",")] + operatorItems(for: nil, priority: 300)
            }
            if statementHasFrom || !sources.isEmpty {
                items += columnItems() + aliasItems()
            } else {
                // No FROM yet: any table's columns, and picking one adds the FROM clause.
                items += catalogColumnItems()
            }
            items += functionItems()
            items += keywordItems(["DISTINCT", "CASE"], priority: 350)
            items.append(SQLCompletionItem(kind: .keyword, label: "*", detail: L10n.text("All columns"), insertion: "*", score: 500))
            return items
        }

        /// In WHERE, HAVING, and ON: columns, then operators after a column, values after an operator, and
        /// connectives after a value.
        private mutating func predicateCandidates(_ prev: Token?) -> [SQLCompletionItem] {
            let prevKeyword = prev?.keyword ?? ""
            if prev == nil || ["WHERE", "HAVING", "AND", "OR", "NOT", "(", "PREWHERE"].contains(prevKeyword) || prev?.text == "(" {
                // HAVING filters groups, so aggregates come first there.
                if clause == .having { return functionItems(aggregatesFirst: true) + columnItems() + selectAliasItems() }
                return columnItems() + aliasItems() + functionItems() + keywordItems(["NOT", "EXISTS"], priority: 300)
            }
            if prevKeyword == "IS" { return keywordItems(["NULL", "NOT NULL"], priority: 900) }
            if prevKeyword == "NOT", beforePrevious?.keyword == "IS" { return keywordItems(["NULL"], priority: 900) }
            if let prev, Self.comparisonOperators.contains(prev.keyword.isEmpty ? prev.text : prev.keyword) {
                return valueItems(for: columnBefore(index: tokens.count - 1)) + columnItems() + functionItems()
            }
            // A column right after a comparison is a value, so what follows is AND or OR.
            let referenceStart = tokens.count >= 3 && tokens[tokens.count - 2].text == "." ? tokens.count - 3 : tokens.count - 1
            let afterComparison = referenceStart > 0
                && Self.comparisonOperators.contains(tokens[referenceStart - 1].keyword.isEmpty ? tokens[referenceStart - 1].text : tokens[referenceStart - 1].keyword)
            if let prev, !afterComparison, isColumnReference(at: tokens.count - 1) {
                opensAutomatically = typedName.count >= 1
                return operatorItems(for: column(named: prev.text), priority: 900)
            }
            if endsExpression(prev) {
                opensAutomatically = typedName.count >= 1
                var words = ["AND", "OR"]
                words += clause == .having ? ["ORDER BY", "LIMIT"] : ["GROUP BY", "ORDER BY", "LIMIT"]
                return keywordItems(words, priority: 800)
            }
            return columnItems() + functionItems()
        }

        private func qualifiedCandidates(_ qualifier: (typed: String, name: String)) -> [SQLCompletionItem] {
            let name = qualifier.name.lowercased()
            if let source = sources.first(where: { $0.name.lowercased() == name }) {
                return fields(of: source).map { field in
                    SQLCompletionItem(kind: .column, label: field.name, detail: field.type, insertion: qualifier.typed + "." + quote(field.name),
                                      caretFromEnd: 0, score: 900 + (field.isKey ? 20 : 0))
                }
            }
            // A schema: its tables.
            let tables = catalog.filter { $0.schemaName.lowercased() == name }
            if !tables.isEmpty {
                return tables.map { table in
                    SQLCompletionItem(kind: table.objectKind == .view || table.objectKind == .materializedView ? .view : .table,
                                      label: table.name, detail: tableDetail(table), insertion: qualifier.typed + "." + quote(table.name), score: 800)
                }
            }
            // A table named directly.
            if let table = catalog.first(where: { $0.name.lowercased() == name || $0.displayName.lowercased() == name }) {
                return table.columns.map { column in
                    SQLCompletionItem(kind: .column, label: column.name, detail: column.type, insertion: qualifier.typed + "." + quote(column.name), score: 850)
                }
            }
            return []
        }

        // MARK: Items

        private struct Field { let name: String; let type: String?; let isKey: Bool }

        private func fields(of source: SQLScopeSource) -> [Field] {
            source.fields.map { name in
                let column = source.table?.columns.first { $0.name == name }
                return Field(name: name, type: column?.type, isKey: column?.isPrimaryKey == true)
            }
        }

        /// One source per table reference, named by its alias when it has one.
        private var namedSources: [SQLScopeSource] {
            var byPosition: [Int: SQLScopeSource] = [:]
            for source in sources {
                if let existing = byPosition[source.position], existing.isAlias { continue }
                byPosition[source.position] = source
            }
            return byPosition.keys.sorted().compactMap { byPosition[$0] }
        }

        private func columnItems(assigning: Bool = false) -> [SQLCompletionItem] {
            let named = namedSources
            var counts: [String: Int] = [:]
            for source in named { for field in source.fields { counts[field.lowercased(), default: 0] += 1 } }
            var items: [SQLCompletionItem] = []
            for (order, source) in named.reversed().enumerated() {
                for field in fields(of: source) {
                    // Qualified when the name is in more than one table, so the query stays unambiguous.
                    let ambiguous = (counts[field.name.lowercased()] ?? 0) > 1
                    let name = ambiguous ? quote(source.name) + "." + quote(field.name) : quote(field.name)
                    let detail = [field.type, named.count > 1 ? source.name : nil].compactMap { $0 }.joined(separator: " · ")
                    items.append(SQLCompletionItem(kind: .column, label: ambiguous ? source.name + "." + field.name : field.name,
                                                   detail: detail.isEmpty ? nil : detail, insertion: assigning ? name + " = " : name,
                                                   score: 800 - min(order, 5) * 10 + (field.isKey ? 5 : 0)))
                }
            }
            return items
        }

        private func aliasItems() -> [SQLCompletionItem] {
            namedSources.filter { $0.isAlias || namedSources.count > 1 }.map { source in
                SQLCompletionItem(kind: .alias, label: source.name, detail: source.isAlias ? source.reference : nil, insertion: quote(source.name), score: 650)
            }
        }

        private func catalogColumnItems() -> [SQLCompletionItem] {
            catalog.prefix(400).flatMap { table in
                table.columns.map { column in
                    SQLCompletionItem(kind: .column, label: column.name, detail: [column.type, table.name].joined(separator: " · "),
                                      insertion: quote(column.name), addition: SQLTextAddition(location: statementEnd, text: " " + keyword("FROM") + " " + tableReference(table)),
                                      score: 600)
                }
            }
        }

        private func tableItems(insertStatement: Bool) -> [SQLCompletionItem] {
            var items = ctes.map { cte in
                SQLCompletionItem(kind: .cte, label: cte.name, detail: L10n.text("Common table expression"), insertion: quote(cte.name), score: 900)
            }
            for table in catalog {
                let kind: SQLCompletionItem.Kind = table.objectKind == .view || table.objectKind == .materializedView ? .view : .table
                var item = SQLCompletionItem(kind: kind, label: table.name, insertion: tableReference(table), score: 800)
                item.tableID = table.id
                items.append(item)
                if insertStatement, kind == .table {
                    let columns = table.columns.filter { $0.isGenerated != true }
                    let list = columns.map { quote($0.name) }.joined(separator: ", ")
                    var snippet = SQLCompletionItem(kind: .snippet, label: table.name + " (…) VALUES (…)",
                                                    insertion: tableReference(table) + " (" + list + ") " + keyword("VALUES") + " ()",
                                                    caretFromEnd: 1, score: 790)
                    snippet.tableID = table.id
                    items.append(snippet)
                }
            }
            let schemas = Set(catalog.map(\.schemaName)).filter { !$0.isEmpty }
            if schemas.count > 1 {
                items += schemas.sorted().map { SQLCompletionItem(kind: .schema, label: $0, detail: L10n.text("Schema"), insertion: quote($0) + ".", score: 500) }
            }
            return items
        }

        /// Writes the details of the table and INSERT items among those about to be shown.
        func describeTables(in items: inout [SQLCompletionItem]) {
            for index in items.indices where items[index].detail == nil {
                guard let id = items[index].tableID, let table = catalog.first(where: { $0.id == id }) else { continue }
                items[index].detail = items[index].kind == .snippet
                    ? L10n.plural("column_count", count: table.columns.filter { $0.isGenerated != true }.count)
                    : tableDetail(table)
            }
        }

        private func tableDetail(_ table: SchemaTableDescriptor) -> String {
            var parts: [String] = []
            if !isDefaultSchema(table.schemaName) { parts.append(table.schemaName) }
            parts.append(L10n.plural("column_count", count: table.columns.count))
            if let rows = table.rowCountEstimate { parts.append(L10n.plural("row_count", count: rows)) }
            return parts.joined(separator: " · ")
        }

        private func isDefaultSchema(_ schema: String) -> Bool {
            let lower = schema.lowercased()
            return lower.isEmpty || lower == activeDatabase?.lowercased() || ["public", "main", "dbo"].contains(lower)
        }

        private func tableReference(_ table: SchemaTableDescriptor) -> String {
            let clash = (nameCounts[table.name.lowercased()] ?? 0) > 1
            return isDefaultSchema(table.schemaName) && !clash ? quote(table.name) : quote(table.schemaName) + "." + quote(table.name)
        }

        private func keywordItems(_ words: [String], priority: Int) -> [SQLCompletionItem] {
            words.enumerated().map { index, word in
                let text = keyword(word)
                let opensCall = text.hasSuffix("(")
                return SQLCompletionItem(kind: .keyword, label: text, insertion: opensCall ? text + ")" : text + " ",
                                         caretFromEnd: opensCall ? 1 : 0, score: priority - index)
            }
        }

        private func symbolItem(_ symbol: String) -> SQLCompletionItem {
            SQLCompletionItem(kind: .operation, label: symbol, insertion: symbol == "," ? ", " : symbol + " ", score: 400)
        }

        private func operatorItems(for column: SchemaColumnDescriptor?, priority: Int) -> [SQLCompletionItem] {
            let type = column?.type.lowercased() ?? ""
            let text = ["char", "text", "string", "clob", "json", "uuid", "enum"].contains { type.contains($0) }
            var operators: [(String, String, Int)] = [("=", "= ", 0), ("<>", "<> ", 0), ("IN (…)", keyword("IN") + " ()", 1),
                                                      ("IS NULL", keyword("IS NULL") + " ", 0), ("IS NOT NULL", keyword("IS NOT NULL") + " ", 0)]
            if text {
                operators.insert((keyword("LIKE"), keyword("LIKE") + " ''", 1), at: 1)
                if engine == .postgresql { operators.insert((keyword("ILIKE"), keyword("ILIKE") + " ''", 1), at: 2) }
            } else {
                operators += [(">", "> ", 0), ("<", "< ", 0), (">=", ">= ", 0), ("<=", "<= ", 0),
                              (keyword("BETWEEN") + " … " + keyword("AND"), keyword("BETWEEN") + "  " + keyword("AND") + " ", 5)]
            }
            return operators.enumerated().map { index, entry in
                SQLCompletionItem(kind: .operation, label: entry.0, insertion: entry.1, caretFromEnd: entry.2, score: priority - index)
            }
        }

        private func valueItems(for column: SchemaColumnDescriptor?) -> [SQLCompletionItem] {
            let type = column?.type.lowercased() ?? ""
            var items: [SQLCompletionItem] = []
            if type.contains("bool") || type == "tinyint(1)" {
                items += [SQLCompletionItem(kind: .value, label: keyword("TRUE"), insertion: keyword("TRUE") + " ", score: 900),
                          SQLCompletionItem(kind: .value, label: keyword("FALSE"), insertion: keyword("FALSE") + " ", score: 899)]
            } else if ["date", "time"].contains(where: { type.contains($0) }) {
                items += [SQLCompletionItem(kind: .value, label: keyword("CURRENT_DATE"), insertion: keyword("CURRENT_DATE") + " ", score: 880),
                          SQLCompletionItem(kind: .value, label: keyword("CURRENT_TIMESTAMP"), insertion: keyword("CURRENT_TIMESTAMP") + " ", score: 879)]
            } else if ["char", "text", "string", "uuid", "enum"].contains(where: { type.contains($0) }) {
                items.append(SQLCompletionItem(kind: .value, label: "'…'", detail: L10n.text("Text"), insertion: "''", caretFromEnd: 1, score: 880))
            }
            items.append(SQLCompletionItem(kind: .value, label: keyword("NULL"), insertion: keyword("NULL") + " ", score: 300))
            return items
        }

        private func typeItems() -> [SQLCompletionItem] {
            SQLFunctionCatalog.types(for: engine).enumerated().map { index, type in
                let text = type == type.uppercased() ? keyword(type) : type
                return SQLCompletionItem(kind: .keyword, label: text, detail: L10n.text("Type"), insertion: text, score: 800 - index)
            }
        }

        private func functionItems(aggregatesFirst: Bool = false) -> [SQLCompletionItem] {
            let aggregates: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "STRING_AGG", "ARRAY_AGG", "GROUP_CONCAT", "JSONB_AGG", "countIf", "sumIf", "uniq", "uniqExact", "groupArray"]
            return SQLFunctionCatalog.functions(for: engine).enumerated().map { index, function in
                // Mixed-case names, like ClickHouse's, are case-sensitive and keep their spelling.
                let name = function.name == function.name.uppercased() ? keyword(function.name) : function.name
                let insertion = function.takesArguments ? name + "()" : (function.parentheses ? name + "()" : name)
                let boost = aggregatesFirst && aggregates.contains(function.name) ? 500 : 0
                return SQLCompletionItem(kind: .function, label: name + (function.takesArguments ? "(…)" : (function.parentheses ? "()" : "")),
                                         detail: function.signature, insertion: insertion,
                                         caretFromEnd: function.takesArguments ? 1 : 0, score: 400 - min(index, 40) + boost)
            }
        }

        // MARK: Smarter suggestions

        /// "Expand * to columns": replaces the star with the columns of every table in scope.
        private func starExpansion() -> SQLCompletionItem? {
            let named = namedSources
            guard !named.isEmpty, let star = tokens.last, star.text == "*" else { return nil }
            let qualify = named.count > 1
            let columns = named.flatMap { source in
                source.fields.map { qualify ? quote(source.name) + "." + quote($0) : quote($0) }
            }
            guard !columns.isEmpty else { return nil }
            // The star sits right before the caret, with nothing typed after it.
            let starLocation = locationOfLast("*")
            guard let starLocation else { return nil }
            return SQLCompletionItem(kind: .snippet, label: L10n.text("Expand * to columns"), detail: L10n.plural("column_count", count: columns.count),
                                     insertion: columns.joined(separator: ", "), replacing: NSRange(location: starLocation, length: 1), score: 990)
        }

        private func locationOfLast(_ symbol: String) -> Int? {
            let source = sql as NSString
            let length = max(0, min(fragmentStart - statementBase, source.length))
            let range = source.range(of: symbol, options: .backwards, range: NSRange(location: 0, length: length))
            return range.location == NSNotFound ? nil : statementBase + range.location
        }

        /// The SELECT list's expressions that aren't aggregates, for GROUP BY.
        private func groupBySnippet() -> [SQLCompletionItem] {
            let all = SQLEditingService.tokens(sql, engine: engine)
            guard let select = all.firstIndex(where: { $0.keyword == "SELECT" }) else { return [] }
            var depth = 0
            var expressions: [[SQLStructureToken]] = [[]]
            for token in all[(select + 1)...] {
                if token.text == "(" { depth += 1 }
                if token.text == ")" { depth -= 1 }
                if depth == 0, token.keyword == "FROM" { break }
                if depth == 0, token.text == "," { expressions.append([]); continue }
                if token.keyword == "DISTINCT", expressions.last?.isEmpty == true { continue }
                expressions[expressions.count - 1].append(token)
            }
            let aggregates: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG", "JSON_AGG", "JSONB_AGG", "COUNTIF", "UNIQ", "GROUPARRAY"]
            let plain = expressions.compactMap { expression -> String? in
                guard let first = expression.first, let last = expression.last, first.text != "*",
                      !expression.contains(where: { aggregates.contains($0.keyword) }) else { return nil }
                // Drop an "AS alias".
                let body = expression.lastIndex { $0.keyword == "AS" }.map { Array(expression[..<$0]) } ?? expression
                guard let bodyLast = body.last, last.range.upperBound >= bodyLast.range.upperBound else { return nil }
                return String(sql[first.range.lowerBound..<bodyLast.range.upperBound])
            }
            guard !plain.isEmpty else { return [] }
            return [SQLCompletionItem(kind: .snippet, label: plain.joined(separator: ", "), detail: L10n.text("Columns that aren't aggregated"),
                                      insertion: plain.joined(separator: ", "), score: 990)]
        }

        private func selectAliasItems() -> [SQLCompletionItem] {
            let all = SQLEditingService.tokens(sql, engine: engine)
            var aliases: [String] = []
            var depth = 0
            for (index, token) in all.enumerated() {
                if token.text == "(" { depth += 1 }
                if token.text == ")" { depth -= 1 }
                if depth == 0, token.keyword == "FROM" { break }
                if depth == 0, token.keyword == "AS", index + 1 < all.count, all[index + 1].isIdentifier { aliases.append(all[index + 1].text) }
            }
            return aliases.map { SQLCompletionItem(kind: .alias, label: $0, detail: L10n.text("Column alias"), insertion: quote($0), score: 850) }
        }

        private func allColumnsSnippet() -> [SQLCompletionItem] {
            guard let source = namedSources.last, let table = source.table else { return [] }
            let columns = table.columns.filter { $0.isGenerated != true }.map { quote($0.name) }
            return [SQLCompletionItem(kind: .snippet, label: L10n.text("All columns"), detail: L10n.plural("column_count", count: columns.count),
                                      insertion: columns.joined(separator: ", "), score: 990)]
        }

        /// After JOIN: tables that relate to one already in the query, with an alias and the ON condition.
        private func joinSuggestions() -> [SQLCompletionItem] {
            let existing = namedSources
            guard !existing.isEmpty else { return [] }
            var used = Set(existing.map { $0.name.lowercased() })
            var items: [SQLCompletionItem] = []
            let targets = existing.reversed().compactMap { source in source.table.map { JoinTarget(name: source.name, table: $0) } }
            for table in catalog where table.objectKind == nil || table.objectKind == .table || table.objectKind == .view {
                let lowered = table.columns.map { ($0.name.lowercased(), $0) }
                for target in targets {
                    // Self-joins aren't guessed: a table's key matches its own name.
                    guard target.table.id != table.id, target.table.name != table.name else { continue }
                    guard let condition = Self.joinCondition(table, alias: Self.alias(for: table.name, avoiding: used), target,
                                                             lowered: lowered, quote: quote) else { continue }
                    let alias = Self.alias(for: table.name, avoiding: used)
                    let reference = tableReference(table)
                    items.append(SQLCompletionItem(kind: .join, label: "\(table.name) \(alias)",
                                                   detail: keyword("ON") + " " + condition,
                                                   insertion: "\(reference) \(alias) \(keyword("ON")) \(condition)", score: 950))
                    used.insert(alias.lowercased())
                    break
                }
            }
            return items
        }

        /// After ON: conditions joining the newest table to the ones before it.
        private func onSuggestions(prefixed: Bool) -> [SQLCompletionItem] {
            let named = namedSources
            guard let newest = named.last, let newTable = newest.table else { return [] }
            var items: [SQLCompletionItem] = []
            for source in named.dropLast().reversed() {
                guard let other = source.table,
                      let condition = Self.joinCondition(newTable, alias: newest.name, other, otherName: source.name, quote: quote) else { continue }
                let text = prefixed ? keyword("ON") + " " + condition : condition
                items.append(SQLCompletionItem(kind: .join, label: text, detail: L10n.format("Joins %@", source.reference), insertion: text + " ", score: 970))
            }
            return items
        }

        /// A join condition between two tables from their keys: a foreign-key-like column named after the
        /// other table (customer_id → customers.id), or a shared key column name.
        /// A table already in the query, indexed once so that matching it against every table in the
        /// catalog after JOIN is one name lookup per column rather than a comparison of every pair.
        struct JoinTarget {
            let name: String
            let table: SchemaTableDescriptor
            let columns: [String: SchemaColumnDescriptor]
            let key: SchemaColumnDescriptor?
            /// Column names that would refer to this table from another, like customer_id for customers.
            let referenceNames: Set<String>

            init(name: String, table: SchemaTableDescriptor) {
                self.name = name
                self.table = table
                columns = Dictionary(table.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                key = JoinTarget.key(of: table)
                referenceNames = JoinTarget.referenceNames(for: table.name)
            }

            static func key(of table: SchemaTableDescriptor) -> SchemaColumnDescriptor? {
                table.columns.first(where: \.isPrimaryKey) ?? table.columns.first { $0.name.lowercased() == "id" }
            }

            static func referenceNames(for table: String) -> Set<String> {
                let lower = table.lowercased()
                var stems = [lower]
                if lower.hasSuffix("ies") { stems.append(String(lower.dropLast(3)) + "y") }
                else if lower.hasSuffix("ses") || lower.hasSuffix("xes") { stems.append(String(lower.dropLast(2))) }
                else if lower.hasSuffix("s") { stems.append(String(lower.dropLast())) }
                return Set(stems.flatMap { [$0 + "_id", $0 + "id"] })
            }
        }

        static func joinCondition(_ table: SchemaTableDescriptor, alias: String, _ other: SchemaTableDescriptor, otherName: String,
                                  quote: (String) -> String) -> String? {
            joinCondition(table, alias: alias, JoinTarget(name: otherName, table: other), quote: quote)
        }

        /// How a table joins one already in the query: its foreign-key-like column to the other's key, the
        /// other's to its key, or a shared key column. The alias is only worked out for a table that relates.
        static func joinCondition(_ table: SchemaTableDescriptor, alias makeAlias: @autoclosure () -> String, _ target: JoinTarget,
                                  lowered: [(String, SchemaColumnDescriptor)]? = nil, quote: (String) -> String) -> String? {
            let lowered = lowered ?? table.columns.map { ($0.name.lowercased(), $0) }
            if let column = lowered.first(where: { target.referenceNames.contains($0.0) })?.1, let targetKey = target.key {
                return "\(quote(makeAlias())).\(quote(column.name)) = \(quote(target.name)).\(quote(targetKey.name))"
            }
            if let column = JoinTarget.referenceNames(for: table.name).lazy.compactMap({ target.columns[$0] }).first,
               let tableKey = JoinTarget.key(of: table) {
                return "\(quote(makeAlias())).\(quote(tableKey.name)) = \(quote(target.name)).\(quote(column.name))"
            }
            // A key column with the same name in both, like order_id in order_items and payments.
            if let shared = lowered.first(where: { name, column in
                guard name.hasSuffix("_id"), let match = target.columns[name] else { return false }
                return column.isPrimaryKey || match.isPrimaryKey
            })?.1 {
                return "\(quote(makeAlias())).\(quote(shared.name)) = \(quote(target.name)).\(quote(shared.name))"
            }
            return nil
        }

        static func alias(for table: String, avoiding used: Set<String>) -> String {
            let words = table.split { $0 == "_" || $0 == "." }.compactMap(\.first).map { String($0).lowercased() }
            let base = words.isEmpty ? "t" : words.joined()
            var candidate = base
            var suffix = 2
            while used.contains(candidate) || Lexer.reserved.contains(candidate.uppercased()) {
                candidate = base + String(suffix)
                suffix += 1
            }
            return candidate
        }

        // MARK: Columns around the caret

        private func isColumnReference(at index: Int) -> Bool {
            guard tokens.indices.contains(index) else { return false }
            let token = tokens[index]
            guard token.isName else { return false }
            // Not a function name about to be called, and not a table in FROM.
            return true
        }

        private func columnBefore(index: Int) -> SchemaColumnDescriptor? {
            var position = index - 1
            while position >= 0, tokens[position].kind == .symbol, tokens[position].text != ")" { position -= 1 }
            guard position >= 0, tokens[position].isName else { return nil }
            return column(named: tokens[position].text)
        }

        private func column(named name: String) -> SchemaColumnDescriptor? {
            let lower = name.lowercased()
            for source in namedSources.reversed() {
                if let column = source.table?.columns.first(where: { $0.name.lowercased() == lower }) { return column }
            }
            return nil
        }

        private func quote(_ name: String) -> String { SQLSymbolCompletion.quote(name, engine: engine) }
    }
}

/// Functions the completion list offers, by engine, with a short signature.
enum SQLFunctionCatalog {
    struct Function {
        let name: String
        let signature: String
        var takesArguments = true
        var parentheses = true
    }

    /// The parameters in a signature like "DATE_TRUNC('day', timestamp)", split at top-level commas.
    static func parameters(of signature: String) -> [String] {
        guard let open = signature.firstIndex(of: "("), let close = signature.lastIndex(of: ")"), open < close else { return [] }
        let body = signature[signature.index(after: open)..<close]
        var parameters: [String] = []
        var current = ""
        var depth = 0
        for character in body {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parameters.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue
            }
            current.append(character)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parameters.append(last) }
        return parameters
    }

    /// Column types for casts, by engine.
    static func types(for engine: DatabaseEngine) -> [String] {
        switch engine {
        case .postgresql:
            return ["INTEGER", "BIGINT", "NUMERIC", "TEXT", "VARCHAR", "BOOLEAN", "DATE", "TIMESTAMP", "TIMESTAMPTZ", "INTERVAL", "JSONB", "JSON", "UUID", "DOUBLE PRECISION", "SMALLINT", "BYTEA"]
        case .mysql, .mariadb:
            return ["SIGNED", "UNSIGNED", "DECIMAL", "CHAR", "DATE", "DATETIME", "TIME", "JSON", "BINARY", "DOUBLE"]
        case .sqlite:
            return ["INTEGER", "REAL", "TEXT", "NUMERIC", "BLOB"]
        case .clickhouse:
            return ["Int32", "Int64", "UInt32", "UInt64", "Float64", "Decimal(18, 2)", "String", "Date", "DateTime", "UUID", "Bool"]
        default:
            return ["INTEGER", "DECIMAL", "VARCHAR", "DATE", "TIMESTAMP"]
        }
    }

    static func functions(for engine: DatabaseEngine) -> [Function] {
        var common: [Function] = [
            Function(name: "COUNT", signature: "COUNT(expr | *)"),
            Function(name: "SUM", signature: "SUM(number)"),
            Function(name: "AVG", signature: "AVG(number)"),
            Function(name: "MIN", signature: "MIN(expr)"),
            Function(name: "MAX", signature: "MAX(expr)"),
            Function(name: "COALESCE", signature: "COALESCE(value, …)"),
            Function(name: "NULLIF", signature: "NULLIF(a, b)"),
            Function(name: "LOWER", signature: "LOWER(text)"),
            Function(name: "UPPER", signature: "UPPER(text)"),
            Function(name: "TRIM", signature: "TRIM(text)"),
            Function(name: "ROUND", signature: "ROUND(number, digits)"),
            Function(name: "ABS", signature: "ABS(number)"),
            Function(name: "CAST", signature: "CAST(value AS type)"),
            Function(name: "SUBSTRING", signature: "SUBSTRING(text, start, length)"),
            Function(name: "REPLACE", signature: "REPLACE(text, from, to)"),
            Function(name: "CURRENT_DATE", signature: "today's date", takesArguments: false, parentheses: false),
            Function(name: "CURRENT_TIMESTAMP", signature: "now", takesArguments: false, parentheses: false),
        ]
        switch engine {
        case .postgresql:
            common += [
                Function(name: "NOW", signature: "NOW()", takesArguments: false),
                Function(name: "DATE_TRUNC", signature: "DATE_TRUNC('day', timestamp)"),
                Function(name: "EXTRACT", signature: "EXTRACT(field FROM timestamp)"),
                Function(name: "TO_CHAR", signature: "TO_CHAR(value, format)"),
                Function(name: "AGE", signature: "AGE(timestamp, timestamp)"),
                Function(name: "LENGTH", signature: "LENGTH(text)"),
                Function(name: "CONCAT", signature: "CONCAT(text, …)"),
                Function(name: "STRING_AGG", signature: "STRING_AGG(text, separator)"),
                Function(name: "ARRAY_AGG", signature: "ARRAY_AGG(expr)"),
                Function(name: "JSONB_EXTRACT_PATH_TEXT", signature: "JSONB_EXTRACT_PATH_TEXT(jsonb, key, …)"),
                Function(name: "JSONB_AGG", signature: "JSONB_AGG(expr)"),
                Function(name: "GENERATE_SERIES", signature: "GENERATE_SERIES(start, stop, step)"),
                Function(name: "ROW_NUMBER", signature: "ROW_NUMBER() OVER (…)", takesArguments: false),
                Function(name: "GREATEST", signature: "GREATEST(value, …)"),
                Function(name: "LEAST", signature: "LEAST(value, …)"),
            ]
        case .mysql, .mariadb:
            common += [
                Function(name: "NOW", signature: "NOW()", takesArguments: false),
                Function(name: "IFNULL", signature: "IFNULL(value, fallback)"),
                Function(name: "IF", signature: "IF(condition, then, else)"),
                Function(name: "CONCAT", signature: "CONCAT(text, …)"),
                Function(name: "CHAR_LENGTH", signature: "CHAR_LENGTH(text)"),
                Function(name: "DATE", signature: "DATE(datetime)"),
                Function(name: "DATE_FORMAT", signature: "DATE_FORMAT(date, '%Y-%m-%d')"),
                Function(name: "DATE_ADD", signature: "DATE_ADD(date, INTERVAL n DAY)"),
                Function(name: "DATEDIFF", signature: "DATEDIFF(end, start)"),
                Function(name: "TIMESTAMPDIFF", signature: "TIMESTAMPDIFF(unit, start, end)"),
                Function(name: "YEAR", signature: "YEAR(date)"),
                Function(name: "MONTH", signature: "MONTH(date)"),
                Function(name: "GROUP_CONCAT", signature: "GROUP_CONCAT(expr SEPARATOR ', ')"),
                Function(name: "JSON_EXTRACT", signature: "JSON_EXTRACT(doc, '$.path')"),
                Function(name: "JSON_UNQUOTE", signature: "JSON_UNQUOTE(json)"),
                Function(name: "ROW_NUMBER", signature: "ROW_NUMBER() OVER (…)", takesArguments: false),
            ]
        case .sqlite:
            common += [
                Function(name: "IFNULL", signature: "IFNULL(value, fallback)"),
                Function(name: "LENGTH", signature: "LENGTH(text)"),
                Function(name: "DATE", signature: "DATE(time, modifier, …)"),
                Function(name: "DATETIME", signature: "DATETIME(time, modifier, …)"),
                Function(name: "STRFTIME", signature: "STRFTIME('%Y-%m-%d', time)"),
                Function(name: "JULIANDAY", signature: "JULIANDAY(time)"),
                Function(name: "GROUP_CONCAT", signature: "GROUP_CONCAT(expr, separator)"),
                Function(name: "JSON_EXTRACT", signature: "JSON_EXTRACT(json, '$.path')"),
                Function(name: "SUBSTR", signature: "SUBSTR(text, start, length)"),
                Function(name: "INSTR", signature: "INSTR(text, search)"),
                Function(name: "PRINTF", signature: "PRINTF(format, …)"),
                Function(name: "ROW_NUMBER", signature: "ROW_NUMBER() OVER (…)", takesArguments: false),
            ]
        case .clickhouse:
            common += [
                Function(name: "now", signature: "now()", takesArguments: false),
                Function(name: "toDate", signature: "toDate(value)"),
                Function(name: "toStartOfDay", signature: "toStartOfDay(datetime)"),
                Function(name: "toStartOfMonth", signature: "toStartOfMonth(date)"),
                Function(name: "formatDateTime", signature: "formatDateTime(datetime, '%Y-%m-%d')"),
                Function(name: "countIf", signature: "countIf(condition)"),
                Function(name: "sumIf", signature: "sumIf(value, condition)"),
                Function(name: "uniq", signature: "uniq(expr)"),
                Function(name: "uniqExact", signature: "uniqExact(expr)"),
                Function(name: "groupArray", signature: "groupArray(expr)"),
                Function(name: "quantile", signature: "quantile(level)(expr)"),
                Function(name: "arrayJoin", signature: "arrayJoin(array)"),
                Function(name: "JSONExtractString", signature: "JSONExtractString(json, key)"),
            ]
        default:
            break
        }
        return common
    }
}
