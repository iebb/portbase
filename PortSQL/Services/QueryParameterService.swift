import Foundation

struct QueryParameterDraft: Identifiable, Hashable {
    let id = UUID()
    let sourceSQL: String
    var values: [String: String]
    var nullParameters: Set<String> = []

    var names: [String] {
        Array(values.keys).sorted()
    }
}

enum QueryBoundValue: Codable, Hashable, Sendable {
    case null
    case string(String)
    case integer(Int64)
    case decimal(String)
    case boolean(Bool)

    init(userInput: String) {
        self = .string(userInput)
    }

    var previewLiteral: String {
        switch self {
        case .null: "NULL"
        case .string(let value): "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        case .integer(let value): String(value)
        case .decimal(let value): value
        case .boolean(let value): value ? "TRUE" : "FALSE"
        }
    }
}

struct BoundQuery: Codable, Hashable, Sendable {
    let sql: String
    let values: [QueryBoundValue]
    var sourceSQL: String? = nil
}

enum QueryParameterError: LocalizedError, Equatable {
    case mixedPlaceholderStyles

    var errorDescription: String? {
        L10n.text("Named parameters cannot be mixed with native positional placeholders in the same query.")
    }
}

enum QueryParameterService {
    static func parameters(in sql: String, engine: DatabaseEngine = .postgresql) -> [String] {
        engine.supportsNativeParameters ? Array(Set(parameterTokens(in: sql, engine: engine).map(\.name))).sorted() : []
    }

    static func render(
        sql: String,
        values: [String: String],
        nullParameters: Set<String> = [],
        engine: DatabaseEngine = .postgresql
    ) -> String {
        let tokens = parameterTokens(in: sql, engine: engine)
        guard !tokens.isEmpty else { return sql }
        var rendered = ""
        var cursor = sql.startIndex
        for token in tokens {
            rendered += sql[cursor..<token.range.lowerBound]
            rendered += nullParameters.contains(token.name)
                ? "NULL"
                : QueryBoundValue(userInput: values[token.name] ?? "").previewLiteral
            cursor = token.range.upperBound
        }
        rendered += sql[cursor...]
        return rendered
    }

    static func boundQuery(
        sql: String,
        values: [String: String],
        nullParameters: Set<String> = [],
        engine: DatabaseEngine
    ) throws -> BoundQuery {
        guard engine.supportsNativeParameters else { return BoundQuery(sql: sql, values: []) }
        let tokens = parameterTokens(in: sql, engine: engine)
        guard !tokens.isEmpty else { return BoundQuery(sql: sql, values: []) }
        if containsNativePlaceholder(in: sql, engine: engine) {
            throw QueryParameterError.mixedPlaceholderStyles
        }

        var rendered = ""
        var cursor = sql.startIndex
        var binds: [QueryBoundValue] = []
        for token in tokens {
            rendered += sql[cursor..<token.range.lowerBound]
            if nullParameters.contains(token.name) {
                rendered += "NULL"
            } else {
                let value = QueryBoundValue(userInput: values[token.name] ?? "")
                binds.append(value)
                rendered += engine == .postgresql ? "$\(binds.count)" : "?"
            }
            cursor = token.range.upperBound
        }
        rendered += sql[cursor...]
        return BoundQuery(sql: rendered, values: binds, sourceSQL: sql)
    }

    private struct ParameterToken {
        let name: String
        let range: Range<String.Index>
    }

    private static func parameterTokens(in sql: String, engine: DatabaseEngine) -> [ParameterToken] {
        guard engine.supportsNativeParameters else { return [] }
        var tokens: [ParameterToken] = []
        var index = sql.startIndex
        var quote: Character?
        var lineComment = false
        var blockCommentDepth = 0

        while index < sql.endIndex {
            let character = sql[index]
            let nextIndex = sql.index(after: index)
            let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

            if lineComment {
                if character == "\n" || character == "\r" { lineComment = false }
                index = nextIndex
                continue
            }
            if blockCommentDepth > 0 {
                if engine != .sqlite, character == "/", next == "*" { blockCommentDepth += 1; index = sql.index(after: nextIndex); continue }
                if character == "*", next == "/" { blockCommentDepth -= 1; index = sql.index(after: nextIndex); continue }
                index = nextIndex
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    if next == activeQuote { index = sql.index(after: nextIndex); continue }
                    quote = nil
                } else if engine != .sqlite, character == "\\", (activeQuote == "'" || activeQuote == "\"") {
                    index = nextIndex < sql.endIndex ? sql.index(after: nextIndex) : nextIndex
                    continue
                }
                index = nextIndex
                continue
            }
            if character == "-", next == "-" { lineComment = true; index = sql.index(after: nextIndex); continue }
            if engine.isMySQLFamily, character == "#" { lineComment = true; index = nextIndex; continue }
            if character == "/", next == "*" { blockCommentDepth = 1; index = sql.index(after: nextIndex); continue }
            if engine == .sqlite, character == "[" { quote = "]"; index = nextIndex; continue }
            if character == "'" || character == "\"" || character == "`" { quote = character; index = nextIndex; continue }
            if engine == .postgresql,
               character == "$",
               let delimiter = dollarQuoteDelimiter(at: index, in: sql) {
                let bodyStart = sql.index(index, offsetBy: delimiter.count)
                if let closing = sql.range(of: delimiter, range: bodyStart..<sql.endIndex) {
                    index = closing.upperBound
                    continue
                }
            }

            if character == ":", next != ":", (index == sql.startIndex || sql[sql.index(before: index)] != ":"),
               let next, next == "_" || next.isLetter {
                var end = sql.index(after: nextIndex)
                while end < sql.endIndex, sql[end] == "_" || sql[end].isLetter || sql[end].isNumber {
                    end = sql.index(after: end)
                }
                tokens.append(ParameterToken(name: String(sql[nextIndex..<end]), range: index..<end))
                index = end
                continue
            }
            index = nextIndex
        }
        return tokens
    }

    private static func dollarQuoteDelimiter(at index: String.Index, in sql: String) -> String? {
        guard sql[index] == "$" else { return nil }
        var cursor = sql.index(after: index)
        while cursor < sql.endIndex, sql[cursor] == "_" || sql[cursor].isLetter || sql[cursor].isNumber {
            cursor = sql.index(after: cursor)
        }
        guard cursor < sql.endIndex, sql[cursor] == "$" else { return nil }
        return String(sql[index...cursor])
    }

    private static func containsNativePlaceholder(in sql: String, engine: DatabaseEngine) -> Bool {
        var index = sql.startIndex
        var quote: Character?
        var lineComment = false
        var blockCommentDepth = 0

        while index < sql.endIndex {
            let character = sql[index]
            let nextIndex = sql.index(after: index)
            let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil

            if lineComment {
                if character == "\n" || character == "\r" { lineComment = false }
                index = nextIndex
                continue
            }
            if blockCommentDepth > 0 {
                if engine != .sqlite, character == "/", next == "*" { blockCommentDepth += 1; index = sql.index(after: nextIndex); continue }
                if character == "*", next == "/" { blockCommentDepth -= 1; index = sql.index(after: nextIndex); continue }
                index = nextIndex
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    if next == activeQuote { index = sql.index(after: nextIndex); continue }
                    quote = nil
                } else if engine != .sqlite, character == "\\", activeQuote == "'" || activeQuote == "\"" {
                    index = nextIndex < sql.endIndex ? sql.index(after: nextIndex) : nextIndex
                    continue
                }
                index = nextIndex
                continue
            }
            if character == "-", next == "-" { lineComment = true; index = sql.index(after: nextIndex); continue }
            if engine.isMySQLFamily, character == "#" { lineComment = true; index = nextIndex; continue }
            if character == "/", next == "*" { blockCommentDepth = 1; index = sql.index(after: nextIndex); continue }
            if engine == .sqlite, character == "[" { quote = "]"; index = nextIndex; continue }
            if character == "'" || character == "\"" || character == "`" { quote = character; index = nextIndex; continue }
            if engine == .postgresql,
               character == "$",
               let delimiter = dollarQuoteDelimiter(at: index, in: sql) {
                let bodyStart = sql.index(index, offsetBy: delimiter.count)
                if let closing = sql.range(of: delimiter, range: bodyStart..<sql.endIndex) {
                    index = closing.upperBound
                    continue
                }
            }

            switch engine {
            case .mongodb, .redis, .elasticsearch, .clickhouse:
                return false
            case .mysql, .mariadb:
                if character == "?" { return true }
            case .sqlite:
                if character == "?" { return true }
                if (character == "$" || character == "@"), let next, next.isLetter || next.isNumber || next == "_" { return true }
            case .postgresql:
                if character == "$", let next, ("1"..."9").contains(String(next)) {
                    return true
                }
            }
            index = nextIndex
        }
        return false
    }
}

enum QueryResultExportFormat: String, CaseIterable, Identifiable {
    case csv
    case json

    var id: String { rawValue }

    var fileExtension: String { rawValue }
}

enum QueryResultExportService {
    static func write(_ result: QueryResultTable, format: QueryResultExportFormat) -> URL? {
        guard !result.columns.isEmpty || (format == .json && result.documents != nil) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortSQLExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("portbase-result.\(format.fileExtension)")
        let text: String
        switch format {
        case .csv:
            text = csv(result)
        case .json:
            text = json(result)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func csv(_ result: QueryResultTable) -> String {
        let header = result.columns.map { csvCell($0.name) }.joined(separator: ",")
        let rows = result.rows.map { row in
            result.columns.indices.map { index in
                let cell = row.cells[safe: index] ?? .null
                return cell.isNull ? "NULL" : csvCell(cell.displayValue)
            }.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private static func csvCell(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func json(_ result: QueryResultTable) -> String {
        if let documents = result.documents { return "[\n" + documents.joined(separator: ",\n") + "\n]" }
        let columnNames = QueryResultTable.disambiguatedColumnNames(result.columns.map(\.name))
        let objects = result.rows.map { row in
            Dictionary(uniqueKeysWithValues: columnNames.enumerated().map { index, name in
                let cell = row.cells[safe: index] ?? .null
                return (name, jsonValue(cell))
            })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private static func jsonValue(_ cell: QueryCell) -> Any {
        switch cell {
        case .null: NSNull()
        case .boolean(let value): value
        case .integer(let value): Int64(value) ?? value
        case .decimal(let value): Decimal(string: value).map(NSDecimalNumber.init(decimal:)) ?? value
        case .binary(let value): value.base64EncodedString()
        case .text(let value), .dateTime(let value), .json(let value): value
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
