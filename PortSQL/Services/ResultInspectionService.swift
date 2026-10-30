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

/// Sorts loaded rows by one column without asking the server again, as TablePlus and DataGrip sort a
/// query's fetched rows. Values compare by type: numbers exactly, text in natural order, NULLs last.
struct LoadedResultSort: Equatable {
    var column: Int
    var descending = false

    /// The rows, in the given order, sorted by the column; ties keep their order.
    func ordered(_ rows: [Int], in result: QueryResultTable) -> [Int] {
        guard result.columns.indices.contains(column) else { return rows }
        let keys = rows.map { row in Key(result.rows[row].cells.indices.contains(column) ? result.rows[row].cells[column] : .null) }
        let order = rows.indices.sorted { left, right in
            let a = keys[left], b = keys[right]
            // NULLs stay last whichever way the column sorts.
            if a.isNull != b.isNull { return b.isNull }
            let comparison = a.compare(b)
            if comparison != .orderedSame { return descending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return left < right
        }
        return order.map { rows[$0] }
    }

    /// The next sort when a header is clicked: ascending, then descending, then none.
    static func next(after current: LoadedResultSort?, column: Int) -> LoadedResultSort? {
        guard let current, current.column == column else { return LoadedResultSort(column: column) }
        return current.descending ? nil : LoadedResultSort(column: column, descending: true)
    }

    private enum Key {
        case null, boolean(Bool), number(Decimal), text(String), binary(Data)

        init(_ cell: QueryCell) {
            switch cell {
            case .null: self = .null
            case .boolean(let value): self = .boolean(value)
            case .integer(let text), .decimal(let text):
                self = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).map { .number($0) } ?? .text(text)
            case .text(let text), .json(let text), .dateTime(let text), .extendedJSON(_, let text): self = .text(text)
            case .binary(let data): self = .binary(data)
            }
        }

        var isNull: Bool { if case .null = self { true } else { false } }

        private var rank: Int {
            switch self {
            case .boolean: 0
            case .number: 1
            case .text: 2
            case .binary: 3
            case .null: 4
            }
        }

        func compare(_ other: Key) -> ComparisonResult {
            switch (self, other) {
            case (.boolean(let a), .boolean(let b)): return a == b ? .orderedSame : (a ? .orderedDescending : .orderedAscending)
            case (.number(let a), .number(let b)): return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            // Natural order, so item2 comes before item10; ISO dates and times sort in time order this way too.
            case (.text(let a), .text(let b)): return a.localizedStandardCompare(b)
            case (.binary(let a), .binary(let b)):
                return a == b ? .orderedSame : (a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending)
            default: return rank == other.rank ? .orderedSame : (rank < other.rank ? .orderedAscending : .orderedDescending)
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
        case .json, .extendedJSON: "JSON"
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
        case .json(let value), .extendedJSON(let value, _): data = Data(value.utf8); suffix = "json"
        default: data = Data((cell.isNull ? "NULL" : cell.displayValue).utf8); suffix = "txt"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Portbase-cell-" + UUID().uuidString + "." + suffix)
        try data.write(to: url, options: WorkspaceFileStore.writingOptions)
        return url
    }
}
