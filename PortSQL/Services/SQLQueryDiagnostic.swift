import Foundation
import MySQLNIO
import PostgresNIO

enum SQLQueryDiagnostic {
    static func message(for error: Error) -> String {
        if let error = error as? PSQLError, let message = error.serverInfo?[.message] {
            return L10n.format("Database error %@: %@", error.serverInfo?[.sqlState] ?? "", message)
        }
        return DatabaseErrorFormatter.message(for: error)
    }

    static func range(for error: Error, sql: String) -> NSRange? {
        if let error = error as? PSQLError, let raw = error.serverInfo?[.position], let position = Int(raw), position > 0 {
            // PostgreSQL counts Unicode scalar values, UIKit counts UTF-16 code units.
            let prefix = String(String.UnicodeScalarView(sql.unicodeScalars.prefix(position - 1)))
            let location = prefix.utf16.count
            guard location < sql.utf16.count else { return NSRange(location: sql.utf16.count, length: 0) }
            let index = String.Index(utf16Offset: location, in: sql)
            let token = SQLEditingService.tokens(sql, engine: .postgresql).first { $0.range.contains(index) }
            return token.map { NSRange($0.range, in: sql) } ?? NSRange(location: location, length: String(sql[index]).utf16.count)
        }
        if let error = error as? MySQLError {
            let message = error.message
            guard let match = message.range(of: #"(?i)\bat line [0-9]+\s*$"#, options: .regularExpression),
                  let number = message[match].split(separator: " ").last.flatMap({ Int($0) }), number > 0 else { return nil }
            let lines = sql.components(separatedBy: "\n")
            guard number <= lines.count else { return nil }
            let offset = lines.prefix(number - 1).reduce(0) { $0 + $1.utf16.count + 1 }
            return NSRange(location: offset, length: lines[number - 1].utf16.count)
        }
        return nil
    }
}
