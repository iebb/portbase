import Foundation

/// Narrows the loaded rows without asking the server again. Each condition tests one column, or any
/// column; a row is shown when it meets every condition.
struct LoadedResultFilter: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case contains, equals, greaterThan, lessThan, null, notNull, emptyText
        var title: String {
            switch self {
            case .contains: L10n.text("Contains")
            case .equals: L10n.text("Equals")
            case .greaterThan: L10n.text("Greater than")
            case .lessThan: L10n.text("Less than")
            case .null: "NULL"
            case .notNull: L10n.text("Not NULL")
            case .emptyText: L10n.text("Empty text")
            }
        }
        /// Whether the mode compares with a typed value.
        var takesValue: Bool { self == .contains || self == .equals || self == .greaterThan || self == .lessThan }
    }

    struct Condition: Equatable, Identifiable, Sendable {
        var id = UUID()
        var column: Int?
        var mode: Mode = .contains
        var text = ""
        var isActive: Bool { !mode.takesValue || !text.isEmpty }

        func matches(_ cell: QueryCell) -> Bool { Prepared(self).matches(cell) }
    }

    /// A condition readied for many cells: the typed text is folded once, and plain ASCII, which most
    /// database text is, is compared byte by byte rather than through the locale's collation.
    private struct Prepared {
        let condition: Condition
        /// The typed text in lowercase bytes, when it's ASCII.
        let needle: [UInt8]?

        init(_ condition: Condition) {
            self.condition = condition
            needle = condition.mode == .contains || condition.mode == .equals ? ASCIIFolding.lowercased(condition.text) : nil
        }

        func matches(_ cell: QueryCell) -> Bool {
            let text = condition.text
            switch condition.mode {
            case .null: return cell.isNull
            case .notNull: return !cell.isNull
            case .emptyText: return cell == .text("")
            case .contains:
                guard !cell.isNull else { return false }
                let value = cell.displayValue
                if let needle, let found = ASCIIFolding.contains(needle, in: value) { return found }
                return value.localizedCaseInsensitiveContains(text)
            case .equals:
                guard !cell.isNull else { return false }
                let value = cell.displayValue
                if let needle, let equal = ASCIIFolding.equals(needle, value) { return equal }
                return value.compare(text, options: .caseInsensitive) == .orderedSame
            // Numbers compare by value, dates and text in natural order; NULL is neither greater nor less.
            case .greaterThan, .lessThan:
                guard !cell.isNull else { return false }
                let order = LoadedValueKey(cell).compare(LoadedValueKey(typedLike: cell, text: text))
                return condition.mode == .greaterThan ? order == .orderedDescending : order == .orderedAscending
            }
        }
    }

    var conditions: [Condition]

    init(column: Int? = nil, mode: Mode = .contains, text: String = "") {
        conditions = [Condition(column: column, mode: mode, text: text)]
    }

    var isActive: Bool { conditions.contains(where: \.isActive) }

    /// The first condition, which the quick filters set.
    var column: Int? {
        get { conditions.first?.column }
        set { if conditions.isEmpty { conditions = [Condition()] }; conditions[0].column = newValue }
    }

    /// This filter with one more condition, replacing an inactive first one.
    func adding(_ condition: Condition) -> LoadedResultFilter {
        var copy = self
        copy.conditions = conditions.filter(\.isActive) + [condition]
        return copy
    }

    /// The rows meeting every condition. A cancelled task gets no rows, for its caller to drop.
    func matchingRows(in result: QueryResultTable) -> [Int] {
        let active = conditions.filter(\.isActive).map(Prepared.init)
        guard !active.isEmpty else { return Array(result.rows.indices) }
        let all = Array(result.columns.indices)
        var matching: [Int] = []
        for row in result.rows.indices {
            if row & 0xFF == 0, Task.isCancelled { return [] }
            let cells = result.rows[row].cells
            let meetsAll = active.allSatisfy { prepared in
                let columns = prepared.condition.column.map { result.columns.indices.contains($0) ? [$0] : [] } ?? all
                return columns.contains { index in prepared.matches(cells.indices.contains(index) ? cells[index] : .null) }
            }
            if meetsAll { matching.append(row) }
        }
        return matching
    }
}

/// Case-insensitive matching for ASCII text, which answers only when it can be sure: text with other
/// characters is left to the locale-aware comparison.
enum ASCIIFolding {
    /// The text as lowercase bytes; nil when it's empty or not all ASCII.
    static func lowercased(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        return text.utf8.map(fold)
    }

    @inline(__always) private static func fold(_ byte: UInt8) -> UInt8 { byte &- 65 < 26 ? byte | 0x20 : byte }

    /// Whether the text holds the needle, ignoring ASCII case; nil when only the locale can say.
    static func contains(_ needle: [UInt8], in text: String) -> Bool? {
        text.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            var onlyASCII = true
            let first = needle[0], last = bytes.count - needle.count
            var start = 0
            while start <= last {
                let byte = bytes[start]
                if byte >= 0x80 {
                    onlyASCII = false
                } else if fold(byte) == first {
                    var offset = 1
                    while offset < needle.count, fold(bytes[start + offset]) == needle[offset] { offset += 1 }
                    // A match can't end inside a letter and the marks combined with it.
                    if offset == needle.count, start + offset == bytes.count || bytes[start + offset] < 0x80 { return true }
                }
                start += 1
            }
            // Text of other characters may still match as the locale folds them: a Kelvin sign is a k.
            return onlyASCII && bytes[start...].allSatisfy({ $0 < 0x80 }) ? false : nil
        } ?? nil
    }

    /// Whether the text is the needle, ignoring ASCII case; nil when only the locale can say.
    static func equals(_ needle: [UInt8], _ text: String) -> Bool? {
        text.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            return bytes.count == needle.count && zip(bytes, needle).allSatisfy { fold($0) == $1 }
        } ?? nil
    }
}

/// Sorts loaded rows by one column without asking the server again, as TablePlus and DataGrip sort a
/// query's fetched rows. Values compare by type: numbers exactly, text in natural order, NULLs last.
struct LoadedResultSort: Equatable, Sendable {
    var column: Int
    var descending = false

    /// The rows, in the given order, sorted by the column; ties keep their order.
    func ordered(_ rows: [Int], in result: QueryResultTable) -> [Int] {
        guard result.columns.indices.contains(column) else { return rows }
        let keys = rows.map { row in LoadedValueKey(result.rows[row].cells.indices.contains(column) ? result.rows[row].cells[column] : .null) }
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
}

/// A loaded value as sorting and filtering compare it: numbers exactly at any size, text in natural
/// order, so item2 comes before item10 and ISO dates fall in time order.
enum LoadedValueKey {
    case null, boolean(Bool), number(ExactDecimal), text(String), binary(Data)

    init(_ cell: QueryCell) {
        switch cell {
        case .null: self = .null
        case .boolean(let value): self = .boolean(value)
        case .integer(let text), .decimal(let text):
            self = ExactDecimal(text).map { .number($0) } ?? .text(text)
        case .text(let text), .json(let text), .dateTime(let text), .extendedJSON(_, let text): self = .text(text)
        case .binary(let data): self = .binary(data)
        }
    }

    /// Text a person typed, read as the same kind of value as the cell it is compared with.
    init(typedLike cell: QueryCell, text: String) {
        switch cell {
        case .integer, .decimal: self = ExactDecimal(text).map { .number($0) } ?? .text(text)
        case .boolean: self = ["true", "t", "1", "yes"].contains(text.lowercased()) ? .boolean(true) : .boolean(false)
        default: self = .text(text)
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

    func compare(_ other: LoadedValueKey) -> ComparisonResult {
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

/// The loaded rows a grid shows, in display order: every row as loaded, or the rows a filter and a
/// sort leave. It remembers the result it was worked out for, so a grid never looks rows of a newer
/// result up by an older result's positions.
struct LoadedRowOrder: RandomAccessCollection, Equatable, Sendable {
    /// Positions into the result's rows; nil is every row as loaded.
    private let rows: [Int]?
    private let stamp: Stamp

    private struct Stamp: Equatable {
        let count: Int
        let first: UUID?
        let last: UUID?

        init(_ result: QueryResultTable) {
            count = result.rows.count
            first = result.rows.first?.id
            last = result.rows.last?.id
        }
    }

    init(of result: QueryResultTable, rows: [Int]? = nil) {
        self.rows = rows
        stamp = Stamp(result)
    }

    /// Works out the rows a filter and a sort leave, or nil when its task was cancelled meanwhile.
    static func make(of result: QueryResultTable, filter: LoadedResultFilter, sort: LoadedResultSort?) -> LoadedRowOrder? {
        var rows = filter.isActive ? filter.matchingRows(in: result) : nil
        if Task.isCancelled { return nil }
        if let sort { rows = sort.ordered(rows ?? Array(result.rows.indices), in: result) }
        return Task.isCancelled ? nil : LoadedRowOrder(of: result, rows: rows)
    }

    /// Whether this is the order of that result's rows.
    func isOrder(of result: QueryResultTable) -> Bool { stamp == Stamp(result) }

    /// Whether every loaded row is shown, in the order it was loaded.
    var isAsLoaded: Bool { rows == nil }

    var startIndex: Int { 0 }
    var endIndex: Int { rows?.count ?? stamp.count }
    subscript(position: Int) -> Int { rows?[position] ?? position }
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
