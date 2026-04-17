import Foundation

enum SQLAssistService {
    private static let keywords = [
        "SELECT", "FROM", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "JOIN",
        "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "CREATE TABLE", "ALTER TABLE",
        "DROP TABLE", "EXPLAIN", "DESCRIBE", "SHOW TABLES", "COUNT(*)", "DISTINCT"
    ]

    static func suggestions(for query: String, schema: [SchemaSuggestion]) -> [String] {
        let token = activeToken(in: query).uppercased()
        let candidates = keywords + schema.map(\.value)
        if token.isEmpty {
            return Array(candidates.prefix(8))
        }
        return candidates
            .filter { $0.uppercased().contains(token) }
            .sorted()
            .prefix(8)
            .map { $0 }
    }

    static func hints(for query: String) -> [EditorHint] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return [] }

        var hints: [EditorHint] = []
        if normalized.hasPrefix("SELECT *") {
            hints.append(EditorHint(
                title: "Projection can be narrower",
                message: "Selecting explicit columns improves readability and reduces bandwidth on mobile networks.",
                severity: .info
            ))
        }
        if normalized.hasPrefix("DELETE") && !normalized.contains("WHERE") {
            hints.append(EditorHint(
                title: "DELETE without WHERE",
                message: "This will remove every row in the target table.",
                severity: .critical
            ))
        }
        if normalized.hasPrefix("UPDATE") && !normalized.contains("WHERE") {
            hints.append(EditorHint(
                title: "UPDATE without WHERE",
                message: "All rows will be updated unless you scope the mutation.",
                severity: .critical
            ))
        }
        if normalized.hasPrefix("SELECT") && !normalized.contains("LIMIT") {
            hints.append(EditorHint(
                title: "Consider a LIMIT",
                message: "Mobile result browsing remains responsive when large table scans are capped.",
                severity: .warning
            ))
        }
        return hints
    }

    static func format(_ query: String) -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return query }

        var formatted = query.replacingOccurrences(of: "\t", with: " ")
        let allKeywords = keywords.sorted { $0.count > $1.count }
        for keyword in allKeywords {
            formatted = formatted.replacingOccurrences(of: keyword, with: keyword, options: .caseInsensitive)
        }

        let clauses = [" FROM ", " WHERE ", " GROUP BY ", " ORDER BY ", " HAVING ", " LIMIT ", " VALUES ", " SET "]
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

    private static func activeToken(in query: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let pieces = query.components(separatedBy: separators).filter { !$0.isEmpty }
        return pieces.last ?? ""
    }
}
