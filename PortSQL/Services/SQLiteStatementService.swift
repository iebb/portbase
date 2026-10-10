import Foundation
import SQLite3

enum SQLiteStatementService {
    /// sqlite3_complete recognizes trigger bodies; every returned index belongs to the original buffer.
    static func statementRanges(in sql: String) -> [Range<String.Index>] {
        guard !sql.isEmpty else { return [] }
        guard !sql.contains("\0") else { return [sql.startIndex..<sql.endIndex] }
        let protected = SQLEditingService.protectedRanges(in: sql, engine: .sqlite)
        var spanIndex = 0
        var index = sql.startIndex
        var start = index
        var hasCode = false
        var result: [Range<String.Index>] = []
        while index < sql.endIndex {
            if spanIndex < protected.count, protected[spanIndex].lowerBound == index {
                let span = protected[spanIndex]
                if !sql[span].hasPrefix("--") && !sql[span].hasPrefix("/*") { hasCode = true }
                index = span.upperBound; spanIndex += 1
                continue
            }
            let next = sql.index(after: index)
            if sql[index] == ";" {
                let complete = String(sql[start..<next]).withCString { sqlite3_complete($0) == 1 }
                if complete {
                    if hasCode { result.append(trimmed(start..<next, in: sql)) }
                    start = next; hasCode = false
                }
            } else if !sql[index].isWhitespace { hasCode = true }
            index = next
        }
        if hasCode { result.append(trimmed(start..<sql.endIndex, in: sql)) }
        return result
    }

    private static func trimmed(_ range: Range<String.Index>, in sql: String) -> Range<String.Index> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, sql[start].isWhitespace { start = sql.index(after: start) }
        while end > start, sql[sql.index(before: end)].isWhitespace { end = sql.index(before: end) }
        return start..<end
    }
}
