import Foundation

/// Clipboard formats for result selections.
enum ResultCopyFormat: String, CaseIterable, Identifiable {
    case csv, tsv, json, markdown, sqlInsert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "CSV"
        case .tsv: L10n.text("Tab-Separated")
        case .json: "JSON"
        case .markdown: "Markdown"
        case .sqlInsert: L10n.text("SQL INSERT Statements")
        }
    }

    var systemImage: String {
        switch self {
        case .csv, .tsv: "tablecells"
        case .json: "curlybraces"
        case .markdown: "text.alignleft"
        case .sqlInsert: "chevron.left.forwardslash.chevron.right"
        }
    }

    static func available(for engine: DatabaseEngine?) -> [ResultCopyFormat] {
        engine?.isSQL == true ? allCases : allCases.filter { $0 != .sqlInsert }
    }
}

/// Renders typed cells as text. SQL NULL, empty text, numbers, booleans, JSON, and bytes stay distinct.
/// The SQL format only produces clipboard text; Portbase never executes it.
enum ResultCopyFormatter {
    static func text(_ payload: ResultGridClipboard.Payload, format: ResultCopyFormat,
                     engine: DatabaseEngine? = nil, table: String? = nil) -> String {
        switch format {
        case .tsv: return ResultGridClipboard.text(payload, headers: true)
        case .csv: return csv(payload)
        case .json: return json(payload)
        case .markdown: return markdown(payload)
        case .sqlInsert: return sqlInserts(payload, engine: engine ?? .postgresql, table: table)
        }
    }

    // MARK: CSV

    private static func csv(_ payload: ResultGridClipboard.Payload) -> String {
        func field(_ value: String) -> String {
            let needsQuotes = value.isEmpty || value.contains(where: { [",", "\"", "\n", "\r"].contains($0) })
                || value.first == " " || value.last == " "
            return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        var lines = [payload.columns.map { field($0.name) }.joined(separator: ",")]
        for row in payload.rows {
            // NULL is an empty unquoted field; empty text is a quoted empty field.
            lines.append(row.cells.map { $0.isNull ? "" : field($0.displayValue) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: JSON

    private static func json(_ payload: ResultGridClipboard.Payload) -> String {
        let keys = uniqueNames(payload.columns.map(\.name))
        let objects = payload.rows.map { row -> String in
            let members = keys.indices.map { index -> String in
                let cell = row.cells.indices.contains(index) ? row.cells[index] : .null
                return "    " + jsonString(keys[index]) + ": " + jsonValue(cell)
            }
            return "  {\n" + members.joined(separator: ",\n") + "\n  }"
        }
        return objects.isEmpty ? "[]" : "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    private static func jsonValue(_ cell: QueryCell) -> String {
        switch cell {
        case .null: return "null"
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value), .decimal(let value):
            return isJSONNumber(value) ? value : jsonString(value)
        case .json(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil {
                return trimmed
            }
            return jsonString(value)
        case .text, .dateTime, .binary:
            return jsonString(cell.displayValue)
        }
    }

    static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) }
                else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    private static func isJSONNumber(_ value: String) -> Bool {
        value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name)_\(count)"
        }
    }

    // MARK: Markdown

    private static func markdown(_ payload: ResultGridClipboard.Payload) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        let numeric = payload.columns.indices.map { index in
            let cells = payload.rows.compactMap { $0.cells.indices.contains(index) ? $0.cells[index] : nil }.filter { !$0.isNull }
            return !cells.isEmpty && cells.allSatisfy { cell in
                if case .integer = cell { return true }
                if case .decimal = cell { return true }
                return false
            }
        }
        var lines = ["| " + payload.columns.map { escape($0.name) }.joined(separator: " | ") + " |"]
        lines.append("| " + numeric.map { $0 ? "---:" : "---" }.joined(separator: " | ") + " |")
        for row in payload.rows {
            lines.append("| " + row.cells.map { $0.isNull ? "*NULL*" : escape($0.displayValue) }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: SQL

    private static func sqlInserts(_ payload: ResultGridClipboard.Payload, engine: DatabaseEngine, table: String?) -> String {
        let target = qualifiedTable(table, engine: engine)
        let columns = payload.columns.map { SQLTemplateService.identifier($0.name, engine: engine) }.joined(separator: ", ")
        return payload.rows.map { row in
            "INSERT INTO \(target) (\(columns)) VALUES (" + row.cells.map { literal($0, engine: engine) }.joined(separator: ", ") + ");"
        }.joined(separator: "\n")
    }

    static func literal(_ cell: QueryCell, engine: DatabaseEngine) -> String {
        switch cell {
        case .null: return "NULL"
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .integer(let value), .decimal(let value):
            return isJSONNumber(value) ? value : quoted(value, engine: engine)
        case .binary(let data):
            let hex = data.map { String(format: "%02X", $0) }.joined()
            switch engine {
            case .postgresql: return "'\\x\(hex)'::bytea"
            case .clickhouse: return "unhex('\(hex)')"
            default: return "X'\(hex)'"
            }
        case .text(let value), .dateTime(let value), .json(let value):
            return quoted(value, engine: engine)
        }
    }

    private static func quoted(_ value: String, engine: DatabaseEngine) -> String {
        // MySQL, MariaDB, and ClickHouse treat backslash as an escape inside string literals by default.
        var escaped = value
        if engine.isMySQLFamily || engine == .clickhouse { escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + escaped.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func qualifiedTable(_ table: String?, engine: DatabaseEngine) -> String {
        guard let table = table?.trimmingCharacters(in: .whitespacesAndNewlines), !table.isEmpty else { return "table_name" }
        let parts = table.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Reference strings are already-quoted SQL when they contain quote characters; leave those intact.
        if table.contains("\"") || table.contains("`") || parts.contains(where: \.isEmpty) { return table }
        return parts.map { SQLTemplateService.identifier($0, engine: engine) }.joined(separator: ".")
    }
}
