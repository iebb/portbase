import Foundation

struct SQLSafetyAssessment: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
    let requiresConfirmation: Bool
    let blocksExecution: Bool
    /// Permanently removes data or objects (DROP, TRUNCATE, DELETE without WHERE); confirmed with a
    /// dedicated prompt that names what is lost.
    var isDestructive = false
    /// The object the statement destroys, as written in the SQL, for the prompt and typed confirmation.
    var target: String?
    /// The label for the confirming button, such as "Drop" or "Truncate".
    var actionTitle: String?
}

enum SQLSafetyService {
    private static let mutatingKeywords = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "TRUNCATE", "ALTER",
        "CREATE", "RENAME", "REPLACE", "UPSERT"
    ]

    private static let schemaMutationKeywords = [
        "DROP", "TRUNCATE", "ALTER", "CREATE", "RENAME"
    ]

    static func assessment(
        for sql: String,
        readOnly: Bool,
        engine: DatabaseEngine = .postgresql
    ) -> SQLSafetyAssessment? {
        if engine == .mongodb { return MongoQueryService.assessment(for: sql, readOnly: readOnly) }
        if engine == .redis { return RedisCommandService.assessment(for: sql, readOnly: readOnly) }
        if engine == .elasticsearch { return ElasticsearchQueryService.assessment(for: sql, readOnly: readOnly) }
        // Destroying data gets its own confirmation, ahead of ClickHouse's general write check.
        if !readOnly, let destructive = destructiveAssessment(for: sql, engine: engine) { return destructive }
        if engine == .clickhouse { return ClickHouseQueryService.assessment(for: sql, readOnly: readOnly) }
        let statements = normalizedStatements(sql, engine: engine)
        guard !statements.isEmpty else { return nil }

        if readOnly, statements.contains(where: { !isReadOnlyStatement($0) }) {
            return SQLSafetyAssessment(
                title: L10n.text("Read-only connection"),
                message: L10n.text("This server is marked read-only. Disable read-only mode in the server bookmark before running write or schema statements."),
                requiresConfirmation: false,
                blocksExecution: true
            )
        }

        if statements.contains(where: isDeleteWithoutWhere) {
            return SQLSafetyAssessment(
                title: L10n.text("Confirm DELETE"),
                message: L10n.text("This DELETE statement does not include a WHERE clause and may affect every row in the target table."),
                requiresConfirmation: true,
                blocksExecution: false
            )
        }

        if statements.contains(where: isUpdateWithoutWhere) {
            return SQLSafetyAssessment(
                title: L10n.text("Confirm UPDATE"),
                message: L10n.text("This UPDATE statement does not include a WHERE clause and may affect every row in the target table."),
                requiresConfirmation: true,
                blocksExecution: false
            )
        }

        if statements.contains(where: containsSchemaMutation) {
            return SQLSafetyAssessment(
                title: L10n.text("Confirm schema change"),
                message: L10n.text("This statement changes schema or removes data. Review it carefully before running it against a live database."),
                requiresConfirmation: true,
                blocksExecution: false
            )
        }

        if statements.contains(where: { !isReadOnlyStatement($0) }) {
            return SQLSafetyAssessment(
                title: L10n.text("Confirm write"),
                message: L10n.text("This statement can change database data. Review it carefully before running it against a live database."),
                requiresConfirmation: true,
                blocksExecution: false
            )
        }

        return nil
    }

    /// The confirmation for the first statement that permanently destroys data, if any. Detection runs on
    /// the sanitized statements, so keywords in literals and comments never count; names are then read
    /// from the original SQL so they keep the user's spelling and quoting.
    static func destructiveAssessment(for sql: String, engine: DatabaseEngine) -> SQLSafetyAssessment? {
        let word = #"([^\s;(),]+)"#
        let kinds = "TEMPORARY TABLE|TABLE|MATERIALIZED VIEW|VIEW|DATABASE|SCHEMA|INDEX|SEQUENCE|FUNCTION|PROCEDURE|TRIGGER|TYPE|DICTIONARY"
        let alterPrefix = #"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?"#
        for statement in normalizedStatements(sql, engine: engine).sorted() {
            if statement.range(of: #"^TRUNCATE "#, options: .regularExpression) != nil {
                let target = spelledName(after: #"TRUNCATE\s+(?:TABLE\s+)?(?:ONLY\s+)?"#, in: sql)
                    ?? capture(#"^TRUNCATE (?:TABLE )?(?:ONLY )?"# + word, in: statement) ?? ""
                return SQLSafetyAssessment(
                    title: L10n.format("Empty %@?", target),
                    message: L10n.format("TRUNCATE permanently removes every row in %@. This can't be undone.", target),
                    requiresConfirmation: true, blocksExecution: false, isDestructive: true, target: target, actionTitle: L10n.text("Truncate"))
            }
            if let match = captures(#"^ALTER TABLE (?:IF EXISTS )?(?:ONLY )?"# + word + #" DROP (?:COLUMN )?(?:IF EXISTS )?"# + word, in: statement),
               match.count == 2, !["CONSTRAINT", "INDEX", "KEY", "PRIMARY", "FOREIGN", "PARTITION", "DEFAULT", "CHECK"].contains(match[1]) {
                let table = spelledName(after: alterPrefix, in: sql) ?? match[0]
                let column = spelledName(after: alterPrefix + Self.identifierPattern + #"\s+DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?"#, in: sql) ?? match[1]
                return SQLSafetyAssessment(
                    title: L10n.format("Drop column %@?", column),
                    message: L10n.format("This permanently deletes the column %1$@ and all of its values from %2$@. This can't be undone.", column, table),
                    requiresConfirmation: true, blocksExecution: false, isDestructive: true, target: column, actionTitle: L10n.text("Drop"))
            }
            if let kind = capture(#"^DROP ("# + kinds + #") "#, in: statement) {
                let spelledKind = kind.replacingOccurrences(of: " ", with: #"\s+"#)
                let target = spelledName(after: #"DROP\s+"# + spelledKind + #"\s+(?:IF\s+EXISTS\s+)?"#, in: sql)
                    ?? capture(#"^DROP "# + kind + #" (?:IF EXISTS )?"# + word, in: statement) ?? ""
                return SQLSafetyAssessment(
                    title: L10n.format("Drop %@?", target),
                    message: L10n.format("DROP %1$@ permanently deletes %2$@ and everything in it. This can't be undone.", kind, target),
                    requiresConfirmation: true, blocksExecution: false, isDestructive: true, target: target, actionTitle: L10n.text("Drop"))
            }
            if isDeleteWithoutWhere(statement) {
                let target = spelledName(after: #"DELETE\s+(?:FROM\s+)?"#, in: sql)
                    ?? capture(#"^DELETE (?:FROM )?"# + word, in: statement) ?? ""
                return SQLSafetyAssessment(
                    title: L10n.format("Delete every row in %@?", target),
                    message: L10n.format("This DELETE has no WHERE clause, so it removes every row in %@. This can't be undone.", target),
                    requiresConfirmation: true, blocksExecution: false, isDestructive: true, target: target, actionTitle: L10n.text("Delete All Rows"))
            }
        }
        return nil
    }

    /// One identifier part, bare or quoted with "", ``, or [], optionally qualified with dots.
    private static let identifierPattern = #"(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[^\s;(),."`\[]+)(?:\.(?:"[^"]+"|`[^`]+`|\[[^\]]+\]|[^\s;(),."`\[]+))*"#

    /// The identifier following `prefix` in the original SQL, without quotes, or nil when it can't be found.
    private static func spelledName(after prefix: String, in sql: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + prefix + "(" + identifierPattern + ")", options: .caseInsensitive),
              let match = regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)),
              let range = Range(match.range(at: 1), in: sql) else { return nil }
        let name = sql[range].filter { !"\"`[]".contains($0) }
        return name.isEmpty ? nil : name
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func isReadOnlyStatement(_ normalized: String) -> Bool {
        guard !containsMutatingKeyword(in: normalized), !containsSelectInto(in: normalized) else { return false }
        let allowed = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH"]
        return allowed.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
    }

    static func isReadOnlySQL(
        _ sql: String,
        engine: DatabaseEngine = .postgresql
    ) -> Bool {
        if engine == .mongodb { return (try? MongoQueryService.parse(sql).isReadOnly) == true }
        if engine == .clickhouse { return ClickHouseQueryService.isReadOnly(sql) }
        if engine == .redis { return (try? RedisCommandService.parse(sql).isReadOnly) == true }
        if engine == .elasticsearch { return (try? ElasticsearchQueryService.parse(sql).isReadOnly) == true }
        let statements = normalizedStatements(sql, engine: engine)
        return !statements.isEmpty && statements.allSatisfy(isReadOnlyStatement)
    }

    static func explainQuery(
        for sql: String,
        engine: DatabaseEngine = .postgresql
    ) -> String? {
        if engine == .mongodb { return MongoQueryService.explain(sql) }
        guard engine.isSQL else { return nil }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isReadOnlySQL(trimmed, engine: engine) else { return nil }
        return "\(engine == .sqlite ? "EXPLAIN QUERY PLAN" : "EXPLAIN") \(trimmed)"
    }

    private static func containsSchemaMutation(_ normalized: String) -> Bool {
        schemaMutationKeywords.contains { containsWord($0, in: normalized) }
    }

    private static func isDeleteWithoutWhere(_ normalized: String) -> Bool {
        isTopLevelMutationWithoutWhere("DELETE", in: normalized)
    }

    private static func isUpdateWithoutWhere(_ normalized: String) -> Bool {
        isTopLevelMutationWithoutWhere("UPDATE", in: normalized)
    }

    private static func isTopLevelMutationWithoutWhere(_ keyword: String, in normalized: String) -> Bool {
        let words = topLevelWords(in: normalized)
        guard words.first(where: { mutatingKeywords.contains($0) }) == keyword else { return false }
        guard let mutationIndex = words.firstIndex(of: keyword) else { return false }
        return !words.dropFirst(mutationIndex + 1).contains("WHERE")
    }

    private static func topLevelWords(in normalized: String) -> [String] {
        var depth = 0
        var token = ""
        var words: [String] = []

        func finishToken() {
            if depth == 0, !token.isEmpty {
                words.append(token)
            }
            token = ""
        }

        for character in normalized + " " {
            if character == "(" {
                finishToken()
                depth += 1
            } else if character == ")" {
                finishToken()
                depth = max(0, depth - 1)
            } else if depth == 0, character.isLetter || character.isNumber || character == "_" {
                token.append(character)
            } else {
                finishToken()
            }
        }
        return words
    }

    private static func containsWord(_ word: String, in normalized: String) -> Bool {
        // No lookbehind: newer Foundation runtimes evaluate this with Swift Regex, which rejects it.
        normalized.range(of: #"(^|[^A-Z0-9_])\#(word)($|[^A-Z0-9_])"#, options: .regularExpression) != nil
    }

    private static func normalizedStatements(_ sql: String, engine: DatabaseEngine) -> [String] {
        let backslashModes = engine.isMySQLFamily ? [true, false] : [false]
        return Array(Set(backslashModes.flatMap { mysqlBackslashEscapes in
            sanitizedSQL(
                sql,
                engine: engine,
                mysqlBackslashEscapes: mysqlBackslashEscapes
            )
            .split(separator: ";")
            .map { normalizedStatement(String($0)) }
            .filter { !$0.isEmpty }
        }))
    }

    private static func normalizedStatement(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .uppercased()
    }

    private static func containsMutatingKeyword(in normalized: String) -> Bool {
        mutatingKeywords.contains { containsWord($0, in: normalized) }
    }

    private static func containsSelectInto(in normalized: String) -> Bool {
        let words = topLevelWords(in: normalized)
        guard let selectIndex = words.firstIndex(of: "SELECT") else { return false }
        let afterSelect = words.dropFirst(selectIndex + 1)
        guard let intoIndex = afterSelect.firstIndex(of: "INTO") else { return false }
        // A top-level INTO before the SELECT's FROM is PostgreSQL table creation;
        // MySQL's INTO OUTFILE/DUMPFILE can also appear after FROM.
        let intoOffset = afterSelect.distance(from: afterSelect.startIndex, to: intoIndex)
        let beforeInto = afterSelect.prefix(intoOffset)
        if !beforeInto.contains("FROM") { return true }
        let afterInto = afterSelect.dropFirst(intoOffset + 1)
        return afterInto.first == "OUTFILE" || afterInto.first == "DUMPFILE"
    }

    private static func sanitizedSQL(
        _ sql: String,
        engine: DatabaseEngine,
        mysqlBackslashEscapes: Bool
    ) -> String {
        var output = ""
        var index = sql.startIndex

        while index < sql.endIndex {
            let character = sql[index]
            let nextIndex = sql.index(after: index)
            let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

            if character == "-", next == "-",
               isDashCommentStart(in: sql, afterSecondDash: sql.index(after: nextIndex), engine: engine) {
                output.append(" ")
                index = sql.index(after: nextIndex)
                while index < sql.endIndex, sql[index] != "\n", sql[index] != "\r" {
                    index = sql.index(after: index)
                }
                continue
            }


            if engine.isMySQLFamily, character == "#" {
                output.append(" ")
                index = nextIndex
                while index < sql.endIndex, sql[index] != "\n", sql[index] != "\r" {
                    index = sql.index(after: index)
                }
                continue
            }

            if character == "/", next == "*" {
                let markerIndex = sql.index(index, offsetBy: 2)
                let mariaMarkerEnd = markerIndex < sql.endIndex ? sql.index(after: markerIndex) : markerIndex
                let executableComment = markerIndex < sql.endIndex && sql[markerIndex] == "!"
                let mariaExecutableComment = mariaMarkerEnd < sql.endIndex
                    && (sql[markerIndex] == "M" || sql[markerIndex] == "m")
                    && sql[mariaMarkerEnd] == "!"
                if executableComment || mariaExecutableComment {
                    output.append(" ")
                    index = sql.index(index, offsetBy: mariaExecutableComment ? 4 : 3)
                    while index < sql.endIndex, sql[index].isNumber {
                        index = sql.index(after: index)
                    }
                    continue
                }
                output.append(" ")
                index = sql.index(after: nextIndex)
                while index < sql.endIndex {
                    if sql[index] == "*",
                       sql.index(after: index) < sql.endIndex,
                       sql[sql.index(after: index)] == "/" {
                        index = sql.index(index, offsetBy: 2)
                        break
                    }
                    index = sql.index(after: index)
                }
                continue
            }

            if character == "*", next == "/" {
                output.append(" ")
                index = sql.index(index, offsetBy: 2)
                continue
            }

            if engine == .postgresql,
               character == "$",
               let delimiterEnd = dollarQuoteDelimiterEnd(in: sql, from: index) {
                let delimiter = String(sql[index...delimiterEnd])
                let contentStart = sql.index(after: delimiterEnd)
                if let closingRange = sql.range(
                    of: delimiter,
                    range: contentStart..<sql.endIndex
                ) {
                    output.append(" ")
                    index = closingRange.upperBound
                    continue
                }
            }

            if character == "'" || character == "\"" || character == "`" {
                let quote = character
                let postgresEscapeString = engine == .postgresql
                    && quote == "'"
                    && isPostgresEscapeStringPrefix(in: sql, before: index)
                output.append(" ")
                index = nextIndex
                while index < sql.endIndex {
                    if ((engine.isMySQLFamily && mysqlBackslashEscapes) || postgresEscapeString),
                       sql[index] == "\\",
                       quote != "`" {
                        let afterEscape = sql.index(after: index)
                        index = afterEscape < sql.endIndex ? sql.index(after: afterEscape) : afterEscape
                        continue
                    }
                    if sql[index] == quote {
                        let afterQuote = sql.index(after: index)
                        if afterQuote < sql.endIndex, sql[afterQuote] == quote {
                            index = sql.index(after: afterQuote)
                            continue
                        }
                        index = afterQuote
                        break
                    }
                    index = sql.index(after: index)
                }
                output.append(" ")
                continue
            }

            output.append(character)
            index = nextIndex
        }

        return output
    }

    private static func isPostgresEscapeStringPrefix(
        in sql: String,
        before quoteIndex: String.Index
    ) -> Bool {
        guard quoteIndex > sql.startIndex else { return false }
        let prefixIndex = sql.index(before: quoteIndex)
        guard sql[prefixIndex] == "E" || sql[prefixIndex] == "e" else { return false }
        guard prefixIndex > sql.startIndex else { return true }
        let beforePrefix = sql[sql.index(before: prefixIndex)]
        return !(beforePrefix.isLetter || beforePrefix.isNumber || beforePrefix == "_")
    }

    private static func isDashCommentStart(
        in sql: String,
        afterSecondDash index: String.Index,
        engine: DatabaseEngine
    ) -> Bool {
        guard engine.isMySQLFamily else { return true }
        guard index < sql.endIndex else { return false }
        return sql[index].unicodeScalars.allSatisfy { $0.value <= 0x20 }
    }

    private static func dollarQuoteDelimiterEnd(
        in sql: String,
        from openingDollar: String.Index
    ) -> String.Index? {
        var cursor = sql.index(after: openingDollar)
        guard cursor < sql.endIndex else { return nil }
        if sql[cursor] == "$" {
            return cursor
        }
        guard sql[cursor].isLetter || sql[cursor] == "_" else { return nil }
        cursor = sql.index(after: cursor)
        while cursor < sql.endIndex {
            let character = sql[cursor]
            if character == "$" {
                return cursor
            }
            guard character.isLetter || character.isNumber || character == "_" else {
                return nil
            }
            cursor = sql.index(after: cursor)
        }
        return nil
    }
}
