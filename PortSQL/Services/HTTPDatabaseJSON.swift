import Foundation

// Keep JSON number lexemes: NSNumber/Double round large IDs and fixed-point values.
indirect enum HTTPJSONValue: Sendable, Equatable {
    case object([String: HTTPJSONValue]), array([HTTPJSONValue]), string(String), number(String), bool(Bool), null

    var object: [String: HTTPJSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [HTTPJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var scalar: String? {
        switch self { case .string(let value), .number(let value): return value; default: return nil }
    }
    var integer: Int? { scalar.flatMap(Int.init) }
    subscript(_ key: String) -> HTTPJSONValue? { object?[key] }

    var cell: QueryCell {
        switch self {
        case .null: return .null
        case .bool(let value): return .boolean(value)
        case .string(let value): return .text(value)
        case .number(let value): return value.contains(".") || value.lowercased().contains("e") ? .decimal(value) : .integer(value)
        case .object, .array: return .json(json())
        }
    }

    func json(pretty: Bool = false, depth: Int = 0) -> String {
        let indent = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let ending = pretty ? "\n" + String(repeating: "  ", count: depth) : ""
        let separator = pretty ? ",\n" : ","
        switch self {
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            return "{" + (pretty ? "\n" : "") + fields.keys.sorted().map {
                indent + DataTransferCodec.jsonString($0) + (pretty ? ": " : ":") + fields[$0]!.json(pretty: pretty, depth: depth + 1)
            }.joined(separator: separator) + ending + "}"
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            return "[" + (pretty ? "\n" : "") + values.map { indent + $0.json(pretty: pretty, depth: depth + 1) }.joined(separator: separator) + ending + "]"
        case .string(let value): return DataTransferCodec.jsonString(value)
        case .number(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    static func parse(_ data: Data, maximumBytes: Int = 32 * 1_024 * 1_024) throws -> HTTPJSONValue {
        guard data.count <= maximumBytes else { throw HTTPDatabaseError.responseTooLarge }
        var parser = HTTPJSONParser(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw HTTPDatabaseError.invalidResponse }
        return value
    }

    static func parse(_ text: String, maximumBytes: Int = 1_048_576) throws -> HTTPJSONValue {
        try parse(Data(text.utf8), maximumBytes: maximumBytes)
    }
}

private struct HTTPJSONParser {
    let bytes: [UInt8]
    var index = 0
    var remainingNodes = 500_000

    mutating func skipWhitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }

    mutating func value(depth: Int) throws -> HTTPJSONValue {
        remainingNodes -= 1
        guard depth <= 100, remainingNodes >= 0 else { throw HTTPDatabaseError.responseTooLarge }
        skipWhitespace()
        guard index < bytes.count else { throw HTTPDatabaseError.invalidResponse }
        switch bytes[index] {
        case 123:
            index += 1; skipWhitespace()
            var fields: [String: HTTPJSONValue] = [:]
            if take(125) { return .object(fields) }
            repeat {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                guard take(58), fields[key] == nil else { throw HTTPDatabaseError.invalidResponse }
                fields[key] = try value(depth: depth + 1)
                skipWhitespace()
                if take(125) { return .object(fields) }
                guard take(44) else { throw HTTPDatabaseError.invalidResponse }
            } while true
        case 91:
            index += 1; skipWhitespace()
            var values: [HTTPJSONValue] = []
            if take(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1)); skipWhitespace()
                if take(93) { return .array(values) }
                guard take(44) else { throw HTTPDatabaseError.invalidResponse }
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default:
            let start = index
            while index < bytes.count && ([45, 43, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index])) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard DataTransferCodec.isJSONNumber(text) else { throw HTTPDatabaseError.invalidResponse }
            return .number(text)
        }
    }

    mutating func string() throws -> String {
        let start = index
        guard take(34) else { throw HTTPDatabaseError.invalidResponse }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                catch { throw HTTPDatabaseError.invalidResponse }
            }
            guard byte >= 32 else { throw HTTPDatabaseError.invalidResponse }
        }
        throw HTTPDatabaseError.invalidResponse
    }

    mutating func literal(_ text: String) throws {
        let expected = Array(text.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else { throw HTTPDatabaseError.invalidResponse }
        index += expected.count
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
}
