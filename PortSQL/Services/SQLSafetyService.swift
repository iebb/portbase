import Foundation

struct SQLSafetyAssessment: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
    let requiresConfirmation: Bool
    let blocksExecution: Bool
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

    static func isReadOnlyStatement(_ normalized: String) -> Bool {
        guard !containsMutatingKeyword(in: normalized), !containsSelectInto(in: normalized) else { return false }
        let allowed = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH"]
        return allowed.contains { normalized == $0 || normalized.hasPrefix($0 + " ") }
    }

    static func isReadOnlySQL(
        _ sql: String,
        engine: DatabaseEngine = .postgresql
    ) -> Bool {
        let statements = normalizedStatements(sql, engine: engine)
        return !statements.isEmpty && statements.allSatisfy(isReadOnlyStatement)
    }

    static func explainQuery(
        for sql: String,
        engine: DatabaseEngine = .postgresql
    ) -> String? {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isReadOnlySQL(trimmed, engine: engine) else { return nil }
        return "EXPLAIN \(trimmed)"
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
        normalized.range(of: #"(?<![A-Z0-9_])\#(word)(?![A-Z0-9_])"#, options: .regularExpression) != nil
    }

    private static func normalizedStatements(_ sql: String, engine: DatabaseEngine) -> [String] {
        let backslashModes = engine == .mysql ? [true, false] : [false]
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


            if engine == .mysql, character == "#" {
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
                    if ((engine == .mysql && mysqlBackslashEscapes) || postgresEscapeString),
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
        guard engine == .mysql else { return true }
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
