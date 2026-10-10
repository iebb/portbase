import Foundation

enum ClickHouseQueryService {
    static func isReadOnly(_ sql: String) -> Bool { (try? classify(sql)) == true }

    static func classify(_ sql: String) throws -> Bool {
        guard !sql.isEmpty, sql.utf8.count <= 1_048_576 else { throw HTTPDatabaseError.invalidRequest }
        // ClickHouse uses backslash string escapes and backtick identifiers. Do not classify literal content.
        var tokens = SQLEditingService.tokens(sql, engine: .mysql)
        if tokens.last?.text == ";", tokens.last?.quoted == false { tokens.removeLast() }
        guard !tokens.isEmpty, !tokens.contains(where: { !$0.quoted && $0.text == ";" }),
              !tokens.contains(where: { ["FORMAT", "SETTINGS", "OUTFILE"].contains($0.keyword) }) else {
            throw HTTPDatabaseError.clickHouseFormat
        }
        let words = tokens.map(\.keyword)
        let writes: Set<String> = ["INSERT", "UPDATE", "DELETE", "ALTER", "CREATE", "DROP", "TRUNCATE", "RENAME", "EXCHANGE", "OPTIMIZE"]
        switch words[0] {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXISTS":
            guard !words.contains(where: writes.contains) else { throw HTTPDatabaseError.unsupportedRequest }
            return true
        case "WITH", "EXPLAIN":
            guard words.contains("SELECT"), !words.contains(where: writes.contains) else { throw HTTPDatabaseError.unsupportedRequest }
            return true
        default:
            guard writes.contains(words[0]) else { throw HTTPDatabaseError.unsupportedRequest }
            // User/role/configuration management has separate privilege semantics, outside the data editor.
            guard !words.prefix(5).contains(where: { ["USER", "ROLE", "QUOTA", "POLICY", "PROFILE", "COLLECTION"].contains($0) }) else {
                throw HTTPDatabaseError.unsupportedRequest
            }
            return false
        }
    }

    static func assessment(for sql: String, readOnly: Bool) -> SQLSafetyAssessment? {
        do {
            let isRead = try classify(sql)
            if readOnly && !isRead {
                return SQLSafetyAssessment(title: L10n.text("Read-only connection"),
                    message: L10n.text("This server is marked read-only. Disable read-only mode in the server bookmark before running write or schema statements."),
                    requiresConfirmation: false, blocksExecution: true)
            }
            guard !isRead else { return nil }
            return SQLSafetyAssessment(title: L10n.text("Confirm write"),
                message: L10n.text("This statement can change database data. Review it carefully before running it against a live database."),
                requiresConfirmation: true, blocksExecution: false)
        } catch {
            return SQLSafetyAssessment(title: L10n.text("Query"), message: error.localizedDescription,
                requiresConfirmation: false, blocksExecution: true)
        }
    }
}
