import Foundation

enum SQLAssistService {
    private static let statementKeywords = [
        "SELECT", "INSERT INTO", "UPDATE", "DELETE FROM", "CREATE TABLE", "ALTER TABLE",
        "DROP TABLE", "EXPLAIN", "DESCRIBE", "SHOW TABLES"
    ]

    private static let clauseKeywords = [
        "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT",
        "VALUES", "SET", "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "ON"
    ]

    private static let aggregateFunctions = [
        "COUNT(*)", "COUNT(", "SUM(", "AVG(", "MIN(", "MAX(", "DISTINCT "
    ]

    private static let logicalOperators = ["AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "EXISTS"]
    private static let comparisonOperators = ["=", "!=", ">", ">=", "<", "<=", "IS NULL", "IS NOT NULL"]
    private static let valueLiterals = ["NULL", "TRUE", "FALSE", "''", "0"]

    static func suggestions(
        for query: String,
        catalog: [SchemaTableDescriptor],
        activeDatabase: String?,
        cursorOffset: Int
    ) -> [String] {
        let context = SQLAutocompleteContext(
            query: query,
            catalog: catalog,
            activeDatabase: activeDatabase,
            cursorOffset: cursorOffset
        )
        let candidates = deduplicatedCandidates(candidates(for: context), in: context)
        let ranked = rank(candidates: candidates, fragment: context.activeFragment)
        return Array(ranked.prefix(8))
    }

    static func applySuggestion(_ suggestion: String, to query: String, cursorOffset: Int) -> (query: String, cursorOffset: Int) {
        let trimmedSuggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSuggestion.isEmpty else { return (query, cursorOffset) }

        let fragmentRange = activeFragmentRange(in: query, cursorOffset: cursorOffset)
        let needsLeadingSpace = fragmentRange.lowerBound > query.startIndex
            && !query[query.index(before: fragmentRange.lowerBound)].isWhitespace
            && query[query.index(before: fragmentRange.lowerBound)] != "."
            && query[query.index(before: fragmentRange.lowerBound)] != "("

        let replacement = needsLeadingSpace ? " " + normalizedInsertion(trimmedSuggestion) : normalizedInsertion(trimmedSuggestion)
        let updated = query.replacingCharacters(in: fragmentRange, with: replacement)
        let normalized = normalizedSpacing(in: updated)
        let prefixLength = query.distance(from: query.startIndex, to: fragmentRange.lowerBound) + replacement.count
        let clampedOffset = min(prefixLength, normalized.count)
        return (normalized, clampedOffset)
    }

    static func hints(for query: String) -> [EditorHint] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return [] }

        var hints: [EditorHint] = []
        if normalized.hasPrefix("SELECT *") {
            hints.append(EditorHint(
                title: L10n.text("Projection can be narrower"),
                message: L10n.text("Selecting explicit columns improves readability and reduces bandwidth on mobile networks."),
                severity: .info
            ))
        }
        if normalized.hasPrefix("DELETE") && !normalized.contains("WHERE") {
            hints.append(EditorHint(
                title: L10n.text("DELETE without WHERE"),
                message: L10n.text("This will remove every row in the target table."),
                severity: .critical
            ))
        }
        if normalized.hasPrefix("UPDATE") && !normalized.contains("WHERE") {
            hints.append(EditorHint(
                title: L10n.text("UPDATE without WHERE"),
                message: L10n.text("All rows will be updated unless you scope the mutation."),
                severity: .critical
            ))
        }
        if normalized.hasPrefix("SELECT") && !normalized.contains("LIMIT") {
            hints.append(EditorHint(
                title: L10n.text("Consider a LIMIT"),
                message: L10n.text("Mobile result browsing remains responsive when large table scans are capped."),
                severity: .warning
            ))
        }
        return hints
    }

    static func format(_ query: String) -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return query }

        var formatted = query.replacingOccurrences(of: "\t", with: " ")
        let allKeywords = (statementKeywords + clauseKeywords + logicalOperators).sorted { $0.count > $1.count }
        for keyword in allKeywords {
            formatted = formatted.replacingOccurrences(of: keyword, with: keyword, options: .caseInsensitive)
        }

        let clauses = [" FROM ", " WHERE ", " GROUP BY ", " ORDER BY ", " HAVING ", " LIMIT ", " VALUES ", " SET ", " ON "]
        for clause in clauses {
            formatted = formatted.replacingOccurrences(
                of: clause,
                with: "\n" + clause.trimmingCharacters(in: .whitespaces) + " ",
                options: .caseInsensitive
            )
        }

        let lines = formatted
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private static func candidates(for context: SQLAutocompleteContext) -> [String] {
        if context.trimmedQuery.isEmpty || context.isAtStatementStart {
            return statementKeywords + ["SHOW DATABASES", "SELECT"]
        }

        if let forcedKeyword = context.requiredConnectorKeyword {
            return [forcedKeyword]
        }

        switch context.clause {
        case .select:
            if context.lastToken == "FROM" {
                return context.tableCandidates
            }
            if context.lastToken == "SELECT" || context.lastToken == "," || context.lastToken == "DISTINCT" {
                return aggregateFunctions + context.columnCandidates + context.tableScopedColumnCandidates
            }
            return context.columnCandidates + aggregateFunctions + ["FROM"]

        case .from:
            return context.tableCandidates + joinKeywords

        case .join:
            if ["JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN"].contains(context.lastCompoundToken) {
                return context.tableCandidates
            }
            if context.lastToken == "ON" || context.lastToken == "AND" || context.lastToken == "OR" {
                return context.columnCandidates + context.tableScopedColumnCandidates
            }
            if context.comparisonJustEntered {
                return valueLiterals + context.columnCandidates + context.tableScopedColumnCandidates
            }
            return ["ON"] + context.columnCandidates + context.tableScopedColumnCandidates + logicalOperators + comparisonOperators

        case .whereClause, .having:
            if context.lastToken == "WHERE" || context.lastToken == "HAVING" || context.lastToken == "AND" || context.lastToken == "OR" {
                return context.columnCandidates + context.tableScopedColumnCandidates + logicalOperators
            }
            if context.comparisonJustEntered {
                return valueLiterals + context.columnCandidates + context.tableScopedColumnCandidates
            }
            return logicalOperators + comparisonOperators + context.columnCandidates + context.tableScopedColumnCandidates

        case .groupBy, .orderBy:
            if context.lastCompoundToken == "ORDER BY" || context.lastCompoundToken == "GROUP BY" || context.lastToken == "," {
                return context.columnCandidates + context.tableScopedColumnCandidates
            }
            if context.clause == .orderBy {
                return ["ASC", "DESC", ","] + context.columnCandidates + context.tableScopedColumnCandidates
            }
            return [",", "HAVING", "ORDER BY"] + context.columnCandidates + context.tableScopedColumnCandidates

        case .insertInto:
            if context.lastCompoundToken == "INSERT INTO" {
                return context.tableCandidates
            }
            if context.lastToken == ")" {
                return ["VALUES"]
            }
            return context.columnCandidates + ["VALUES"]

        case .update:
            if context.lastToken == "UPDATE" {
                return context.tableCandidates
            }
            if context.lastToken == "SET" || context.lastToken == "," {
                return context.columnCandidates
            }
            if context.comparisonJustEntered {
                return valueLiterals + context.columnCandidates
            }
            return ["SET", "WHERE"] + context.columnCandidates + comparisonOperators

        case .delete:
            if context.lastToken == "DELETE" {
                return ["FROM"]
            }
            if context.lastToken == "FROM" {
                return context.tableCandidates
            }
            return ["WHERE"] + context.columnCandidates + context.tableScopedColumnCandidates

        case .ddl:
            return context.tableCandidates + context.columnCandidates + statementKeywords

        case .unknown:
            return context.columnCandidates
                + context.tableScopedColumnCandidates
                + aggregateFunctions
                + clauseKeywords
                + context.tableCandidates
        }
    }

    private static var joinKeywords: [String] {
        ["JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN"]
    }

    private static func deduplicatedCandidates(_ candidates: [String], in context: SQLAutocompleteContext) -> [String] {
        var chosenByKey: [String: String] = [:]
        var order: [String] = []

        for candidate in candidates {
            let key = canonicalKey(for: candidate, in: context)
            let preferred = preferredRepresentation(for: candidate, in: context)

            if let existing = chosenByKey[key] {
                if shouldPrefer(preferred, over: existing, in: context) {
                    chosenByKey[key] = preferred
                }
            } else {
                chosenByKey[key] = preferred
                order.append(key)
            }
        }

        return order.compactMap { chosenByKey[$0] }
    }

    private static func canonicalKey(for candidate: String, in context: SQLAutocompleteContext) -> String {
        let normalized = candidate.lowercased()
        return normalized
    }

    private static func preferredRepresentation(for candidate: String, in context: SQLAutocompleteContext) -> String {
        candidate
    }

    private static func shouldPrefer(_ candidate: String, over existing: String, in context: SQLAutocompleteContext) -> Bool {
        guard let candidateTable = context.catalog.first(where: { $0.matches(reference: candidate) }) else {
            return candidate.count < existing.count
        }

        if let activeDatabase = context.activeDatabase,
           candidateTable.schemaName.lowercased() == activeDatabase,
           candidate == candidateTable.name {
            return true
        }

        guard let existingTable = context.catalog.first(where: { $0.matches(reference: existing) }) else {
            return false
        }

        if let activeDatabase = context.activeDatabase,
           existingTable.schemaName.lowercased() == activeDatabase,
           existing == existingTable.name {
            return false
        }

        if candidate.count != existing.count {
            return candidate.count < existing.count
        }

        return candidate.localizedCaseInsensitiveCompare(existing) == .orderedAscending
    }

    private static func rank(candidates: [String], fragment: String) -> [String] {
        let deduplicated = orderedUnique(candidates)
        let needle = fragment.lowercased()
        guard !needle.isEmpty else { return deduplicated }

        return deduplicated
            .sorted { lhs, rhs in
                let leftRank = rank(candidate: lhs, needle: needle)
                let rightRank = rank(candidate: rhs, needle: needle)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .filter { rank(candidate: $0, needle: needle) < 4 }
    }

    private static func rank(candidate: String, needle: String) -> Int {
        let normalized = candidate.lowercased()
        if normalized == needle { return 0 }
        if normalized.hasPrefix(needle) { return 1 }
        if normalized.split(separator: ".").last?.hasPrefix(Substring(needle)) == true { return 2 }
        if normalized.contains(needle) { return 3 }
        return 4
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func activeFragmentRange(in query: String, cursorOffset: Int) -> Range<String.Index> {
        guard !query.isEmpty else { return query.startIndex..<query.startIndex }

        let clampedOffset = max(0, min(cursorOffset, query.count))
        var end = query.index(query.startIndex, offsetBy: clampedOffset)
        while end > query.startIndex, query[query.index(before: end)].isWhitespace {
            end = query.index(before: end)
        }

        var start = end
        while start > query.startIndex {
            let previous = query[query.index(before: start)]
            if previous.isLetter || previous.isNumber || previous == "_" || previous == "." {
                start = query.index(before: start)
            } else {
                break
            }
        }

        return start..<end
    }

    private static func normalizedInsertion(_ suggestion: String) -> String {
        let uppercase = suggestion.uppercased()
        if aggregateFunctions.contains(where: { $0.uppercased() == uppercase }) {
            return suggestion
        }
        if ["ASC", "DESC", "NULL", "TRUE", "FALSE"].contains(uppercase) {
            return suggestion + " "
        }
        if comparisonOperators.contains(where: { $0.uppercased() == uppercase }) || logicalOperators.contains(uppercase) {
            return suggestion + " "
        }
        if clauseKeywords.contains(where: { $0.uppercased() == uppercase }) || statementKeywords.contains(where: { $0.uppercased() == uppercase }) {
            return suggestion + " "
        }
        if suggestion == "," {
            return ", "
        }
        return suggestion
    }

    private static func normalizedSpacing(in query: String) -> String {
        query.replacingOccurrences(of: "  ", with: " ")
    }
}

private struct SQLAutocompleteContext {
    let trimmedQuery: String
    let activeFragment: String
    let lastToken: String
    let lastCompoundToken: String
    let clause: SQLClause
    let resolvedTables: [SchemaTableDescriptor]
    let activeDatabase: String?
    let catalog: [SchemaTableDescriptor]
    let comparisonJustEntered: Bool
    let requiredConnectorKeyword: String?
    let cursorOffset: Int
    let isAtStatementStart: Bool

    init(query: String, catalog: [SchemaTableDescriptor], activeDatabase: String?, cursorOffset: Int) {
        self.trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cursorOffset = max(0, min(cursorOffset, query.count))
        self.activeFragment = SQLAutocompleteContext.activeFragment(in: query, cursorOffset: self.cursorOffset)
        self.catalog = catalog
        self.activeDatabase = activeDatabase?.lowercased()

        let queryPrefix = String(query.prefix(self.cursorOffset))
        let normalizedQuery = trimmedQuery.uppercased()
        let normalizedPrefix = queryPrefix.uppercased()
        let tokens = SQLAutocompleteContext.tokens(in: normalizedPrefix)
        self.lastToken = tokens.last ?? ""
        self.lastCompoundToken = SQLAutocompleteContext.compoundToken(from: tokens)
        self.clause = SQLAutocompleteContext.detectClause(in: normalizedPrefix)
        self.resolvedTables = SQLAutocompleteContext.resolveTables(in: trimmedQuery, catalog: catalog)
        self.comparisonJustEntered = ["=", "!=", ">", ">=", "<", "<=", "LIKE", "IN"].contains(lastToken)
        self.requiredConnectorKeyword = SQLAutocompleteContext.requiredConnectorKeyword(from: tokens)
        self.isAtStatementStart = SQLAutocompleteContext.isAtStatementStart(in: queryPrefix)
    }

    var tableCandidates: [String] {
        catalog
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .flatMap { table -> [String] in
                if let activeDatabase, table.schemaName.lowercased() == activeDatabase {
                    return [table.name, table.displayName]
                }
                return [table.displayName, table.name]
            }
    }

    var columnCandidates: [String] {
        let source = resolvedTables.isEmpty ? catalog : resolvedTables
        return source
            .flatMap(\.columns)
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var tableScopedColumnCandidates: [String] {
        let source = resolvedTables.isEmpty ? catalog : resolvedTables
        return source
            .flatMap { table in
                table.columns.map { "\(table.name).\($0.name)" } + table.columns.map { "\(table.displayName).\($0.name)" }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func detectClause(in query: String) -> SQLClause {
        let normalized = query.replacingOccurrences(of: "\n", with: " ")
        var lastMatch: (offset: Int, clause: SQLClause)?

        func register(_ token: String, clause: SQLClause) {
            if let range = normalized.range(of: token, options: .backwards) {
                let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
                if lastMatch == nil || offset > lastMatch!.offset {
                    lastMatch = (offset, clause)
                }
            }
        }

        if normalized.hasPrefix("SELECT") {
            lastMatch = (0, .select)
        } else if normalized.hasPrefix("INSERT INTO") {
            lastMatch = (0, .insertInto)
        } else if normalized.hasPrefix("UPDATE ") {
            lastMatch = (0, .update)
        } else if normalized.hasPrefix("DELETE") {
            lastMatch = (0, .delete)
        } else if normalized.hasPrefix("ALTER ") || normalized.hasPrefix("CREATE ") || normalized.hasPrefix("DROP ") || normalized.hasPrefix("DESCRIBE ") || normalized.hasPrefix("EXPLAIN ") {
            lastMatch = (0, .ddl)
        }

        register(" FROM ", clause: .from)
        register(" LEFT JOIN ", clause: .join)
        register(" RIGHT JOIN ", clause: .join)
        register(" INNER JOIN ", clause: .join)
        register(" JOIN ", clause: .join)
        register(" WHERE ", clause: .whereClause)
        register(" HAVING ", clause: .having)
        register(" GROUP BY ", clause: .groupBy)
        register(" ORDER BY ", clause: .orderBy)

        if let lastMatch {
            return lastMatch.clause
        }
        return .unknown
    }

    private static func isAtStatementStart(in queryPrefix: String) -> Bool {
        let trimmed = queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let withoutFragment = String(trimmed.dropLast(activeFragment(in: trimmed, cursorOffset: trimmed.count).count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = withoutFragment.last else { return true }
        return last == ";" || last == "\n"
    }

    private static func requiredConnectorKeyword(from tokens: [String]) -> String? {
        guard let last = tokens.last else { return nil }
        switch last {
        case "ORDER", "GROUP":
            return "BY"
        case "DELETE":
            return "FROM"
        case "INSERT":
            return "INTO"
        default:
            return nil
        }
    }

    private static func compoundToken(from tokens: [String]) -> String {
        guard let last = tokens.last else { return "" }
        if let secondLast = tokens.dropLast().last {
            let pair = "\(secondLast) \(last)"
            if ["ORDER BY", "GROUP BY", "INSERT INTO", "DELETE FROM", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN"].contains(pair) {
                return pair
            }
        }
        return last
    }

    private static func tokens(in query: String) -> [String] {
        query
            .replacingOccurrences(of: ",", with: " , ")
            .replacingOccurrences(of: "(", with: " ( ")
            .replacingOccurrences(of: ")", with: " ) ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func activeFragment(in query: String, cursorOffset: Int) -> String {
        let prefix = String(query.prefix(max(0, min(cursorOffset, query.count))))
        let fragment = prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return String(fragment.reversed())
    }

    private static func resolveTables(in query: String, catalog: [SchemaTableDescriptor]) -> [SchemaTableDescriptor] {
        let patterns = [
            #"(?i)\bFROM\s+([A-Za-z0-9_\.]+)"#,
            #"(?i)\bJOIN\s+([A-Za-z0-9_\.]+)"#,
            #"(?i)\bUPDATE\s+([A-Za-z0-9_\.]+)"#,
            #"(?i)\bINTO\s+([A-Za-z0-9_\.]+)"#
        ]

        var resolved: [SchemaTableDescriptor] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsQuery = query as NSString
            let matches = regex.matches(in: query, range: NSRange(location: 0, length: nsQuery.length))
            for match in matches {
                guard match.numberOfRanges > 1 else { continue }
                let reference = nsQuery.substring(with: match.range(at: 1))
                if let table = catalog.first(where: { $0.matches(reference: reference) }),
                   !resolved.contains(where: { $0.id == table.id }) {
                    resolved.append(table)
                }
            }
        }
        return resolved
    }
}

private enum SQLClause {
    case select
    case from
    case join
    case whereClause
    case groupBy
    case having
    case orderBy
    case insertInto
    case update
    case delete
    case ddl
    case unknown
}
