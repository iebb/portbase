import Foundation

struct LoadedResultFilter: Equatable {
    enum Mode: String, CaseIterable {
        case contains, equals, null, emptyText
        var title: String {
            switch self {
            case .contains: L10n.text("Contains")
            case .equals: L10n.text("Equals")
            case .null: "NULL"
            case .emptyText: L10n.text("Empty text")
            }
        }
    }
    var column: Int?
    var mode: Mode = .contains
    var text = ""
    var isActive: Bool { mode != .contains || !text.isEmpty }

    func matchingRows(in result: QueryResultTable) -> [Int] {
        guard isActive else { return Array(result.rows.indices) }
        let columns = column.map { result.columns.indices.contains($0) ? [$0] : [] } ?? Array(result.columns.indices)
        return result.rows.indices.filter { row in
            columns.contains { index in
                let cell = result.rows[row].cells.indices.contains(index) ? result.rows[row].cells[index] : .null
                switch mode {
                case .null: return cell.isNull
                case .emptyText: return cell == .text("")
                case .contains: return !cell.isNull && cell.displayValue.localizedCaseInsensitiveContains(text)
                case .equals: return !cell.isNull && cell.displayValue.compare(text, options: .caseInsensitive) == .orderedSame
                }
            }
        }
    }
}

enum ResultInspectionService {
    static func typeName(_ cell: QueryCell) -> String {
        switch cell {
        case .null: "NULL"
        case .text: L10n.text("Text")
        case .integer: L10n.text("Integer")
        case .decimal: L10n.text("Decimal")
        case .boolean: L10n.text("Boolean")
        case .dateTime: L10n.text("Date / Time")
        case .json: "JSON"
        case .binary: L10n.text("Binary")
        }
    }

    // Whitespace formatting preserves number tokens, field order and escape sequences.
    static func formattedJSON(_ source: String) -> String {
        guard source.utf8.count <= 1_048_576 else { return source }
        var result = "", depth = 0, quoted = false, escaped = false
        for character in source {
            if quoted {
                result.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"" { quoted = true; result.append(character) }
            else if character == "{" || character == "[" {
                depth += 1; if depth > 64 { return source }; result.append(character); result += "\n" + String(repeating: "  ", count: depth)
            } else if character == "}" || character == "]" {
                depth = max(0, depth - 1); result += "\n" + String(repeating: "  ", count: depth); result.append(character)
            } else if character == "," { result += ",\n" + String(repeating: "  ", count: depth) }
            else if character == ":" { result += ": " }
            else if !character.isWhitespace { result.append(character) }
        }
        return result
    }

    static func export(_ cell: QueryCell) throws -> URL {
        let data: Data
        let suffix: String
        switch cell {
        case .binary(let bytes): data = bytes; suffix = "bin"
        case .json(let value): data = Data(value.utf8); suffix = "json"
        default: data = Data((cell.isNull ? "NULL" : cell.displayValue).utf8); suffix = "txt"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Portbase-cell-" + UUID().uuidString + "." + suffix)
        try data.write(to: url, options: WorkspaceFileStore.writingOptions)
        return url
    }
}
