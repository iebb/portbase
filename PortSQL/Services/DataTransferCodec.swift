import Foundation
@preconcurrency import SwiftBSON

enum DataTransferCodec {
    static let maximumImportRecordBytes = 1_048_576
    static let maximumColumns = 4_096

    static func jsonString(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    static func identifier(_ value: String, engine: DatabaseEngine) -> String {
        let quote = engine.isMySQLFamily ? "`" : "\""
        return quote + value.replacingOccurrences(of: quote, with: quote + quote) + quote
    }

    static func qualifiedTable(schema: String, table: String, engine: DatabaseEngine) -> String {
        (schema.isEmpty ? [] : [identifier(schema, engine: engine)])
            .appending(identifier(table, engine: engine)).joined(separator: ".")
    }

    static func isBinaryColumn(_ type: String) -> Bool {
        let lower = type.lowercased()
        return ["binary", "blob", "bytea", "geometry"].contains { lower.contains($0) }
    }

    static func sqlValueType(for type: String) -> DataImportValueType {
        let lower = type.lowercased()
        if lower.contains("bool") { return .boolean }
        if lower.contains("int"), !lower.contains("interval") { return .integer }
        if ["decimal", "numeric", "float", "double", "real", "money"].contains(where: lower.contains) { return .decimal }
        if lower.contains("json") { return .json }
        return .automatic
    }

    static func jsonValue(_ cell: QueryCell) -> String {
        switch cell {
        case .null: return "null"
        case .boolean(let value): return value ? "true" : "false"
        case .decimal(let value) where ["nan", "infinity", "-infinity", "inf", "-inf"].contains(value.lowercased()):
            let normalized = value.lowercased() == "nan" ? "NaN" : value.hasPrefix("-") ? "-Infinity" : "Infinity"
            return "{\"$numberDouble\":" + jsonString(normalized) + "}"
        case .integer(let value), .decimal(let value):
            return isJSONNumber(value) ? value : jsonString(value)
        case .binary(let data):
            return "{\"$binary\":{\"base64\":" + jsonString(data.base64EncodedString()) + ",\"subType\":\"00\"}}"
        case .json(let text):
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil ? text : jsonString(text)
        case .text(let text), .dateTime(let text): return jsonString(text)
        }
    }

    static func csvValue(_ cell: QueryCell) -> String {
        if cell.isNull { return "NULL" }
        if cell == .json("{\"$missing\":true}") { return "\\M" }
        return "\"" + cell.displayValue.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func mongoCSVCell(_ value: BSON?) -> QueryCell {
        guard let value else { return .json("{\"$missing\":true}") }
        if case .null = value { return .null }
        // Every MongoDB CSV field is a canonical Extended JSON value, including quoted strings.
        let wrapper = MongoExtendedJSON.encode(BSONDocument(dictionaryLiteral: ("value", value)), canonical: true)
        guard let colon = wrapper.firstIndex(of: ":") else { return .null }
        return .text(String(wrapper[wrapper.index(after: colon)...].dropLast()))
    }

    static func isJSONNumber(_ value: String) -> Bool {
        value.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
    }

    static func boundValue(_ cell: QueryCell, type: DataImportValueType, column: String, row: Int) throws -> QueryBoundValue {
        if cell.isNull { return .null }
        guard !cell.isBinary else { throw DataTransferError.binaryImportUnsupported }
        let text = cell.displayValue
        switch type {
        case .text: return .string(text)
        case .integer:
            guard isJSONNumber(text), !text.contains("."), !text.lowercased().contains("e") else {
                throw DataTransferError.invalidValue(column: column, row: row)
            }
            return Int64(text).map(QueryBoundValue.integer) ?? .string(text)
        case .decimal:
            guard isJSONNumber(text) || ["nan", "infinity", "-infinity", "inf", "-inf"].contains(text.lowercased()) else { throw DataTransferError.invalidValue(column: column, row: row) }
            // Native unknown/text binding lets the target NUMERIC type retain precision beyond Foundation.Decimal.
            return .string(text)
        case .boolean:
            if ["true", "1"].contains(text.lowercased()) { return .boolean(true) }
            if ["false", "0"].contains(text.lowercased()) { return .boolean(false) }
            throw DataTransferError.invalidValue(column: column, row: row)
        case .json:
            guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil else {
                throw DataTransferError.invalidValue(column: column, row: row)
            }
            return .string(text)
        case .automatic:
            switch cell {
            case .integer(let value): return Int64(value).map(QueryBoundValue.integer) ?? .string(value)
            case .boolean(let value): return .boolean(value)
            default: return .string(text)
            }
        }
    }

    static func mongoDocument(record: DataImportRecord, mappings: [DataImportColumnMapping], row: Int) throws -> BSONDocument {
        let original = try record.documentJSON.map { try MongoExtendedJSON.decode($0) }
        let pairs: [(String, BSON)] = try mappings.filter { !$0.targetName.isEmpty }.compactMap { mapping in
            guard let cell = record.fields[mapping.sourceName] else { return nil } // Missing BSON fields stay absent.
            let value: BSON
            if mapping.valueType == .automatic, let existing = original?[mapping.sourceName] { value = existing }
            else { value = try mongoValue(cell, type: mapping.valueType, column: mapping.targetName, row: row) }
            return (mapping.targetName, value)
        }
        return try MongoExtendedJSON.orderedDocument(pairs)
    }

    private static func mongoValue(_ cell: QueryCell, type: DataImportValueType, column: String, row: Int) throws -> BSON {
        if cell.isNull { return .null }
        let text = cell.displayValue
        switch type {
        case .text: return .string(text)
        case .integer:
            guard case .integer(let value) = try boundValue(cell, type: .integer, column: column, row: row) else {
                throw DataTransferError.invalidValue(column: column, row: row)
            }
            return .int64(value)
        case .boolean:
            guard case .boolean(let value) = try boundValue(cell, type: .boolean, column: column, row: row) else {
                throw DataTransferError.invalidValue(column: column, row: row)
            }
            return .bool(value)
        case .decimal:
            guard isJSONNumber(text) else { throw DataTransferError.invalidValue(column: column, row: row) }
            return try MongoExtendedJSON.decode("{\"value\":{\"$numberDecimal\":" + jsonString(text) + "}}")["value"]!
        case .json:
            do { return try MongoExtendedJSON.decode("{\"value\":" + text + "}")["value"]! }
            catch { throw DataTransferError.invalidValue(column: column, row: row) }
        case .automatic:
            if case .boolean(let value) = cell { return .bool(value) }
            if case .integer(let value) = cell, let number = Int64(value) { return .int64(number) }
            if ["true", "false"].contains(text) { return .bool(text == "true") }
            if isJSONNumber(text), let value = Int64(text) { return .int64(value) }
            if isJSONNumber(text), let value = try? MongoExtendedJSON.decode("{\"value\":{\"$numberDecimal\":" + jsonString(text) + "}}")["value"] { return value }
            if text.first == "{" || text.first == "[" || text.first == "\"", let value = try? MongoExtendedJSON.decode("{\"value\":" + text + "}")["value"] { return value }
            return .string(text)
        }
    }

    static func inspect(url: URL, format: DataImportFormat, hasHeader: Bool, nullToken: String,
                        progress: @Sendable (DataTransferProgress) -> Void = { _ in }) throws -> DataImportSource {
        let reader = try DataImportRecordReader(url: url, format: format, hasHeader: hasHeader, nullToken: nullToken)
        var names = reader.columnNames
        var seen = Set(names)
        var count = 0
        var preview: [DataImportRecord] = []
        while let record = try reader.next() {
            try Task.checkCancellation()
            count += 1
            for name in record.fields.keys.sorted() where seen.insert(name).inserted {
                names.append(name)
                guard names.count <= maximumColumns else { throw DataTransferError.tooManyColumns }
            }
            if preview.count < 12 { preview.append(record) }
            if count % 250 == 0 { progress(.init(phase: .reading, completed: count, total: nil)) }
        }
        guard count > 0 else { throw DataTransferError.emptyFile }
        return DataImportSource(url: url, format: format, hasHeader: hasHeader, nullToken: nullToken,
                                columnNames: names, rowCount: count, preview: preview)
    }
}

private extension Array {
    func appending(_ element: Element) -> [Element] { self + [element] }
}

final class DataFileByteReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var finished = false
    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        buffer = try handle.read(upToCount: 65_536) ?? Data()
        if buffer.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
    }
    deinit { try? handle.close() }
    func peek() throws -> UInt8? {
        if offset >= buffer.count, !finished {
            buffer = try handle.read(upToCount: 65_536) ?? Data()
            offset = 0
            finished = buffer.isEmpty
        }
        return offset < buffer.count ? buffer[offset] : nil
    }
    @discardableResult func read() throws -> UInt8? {
        guard let byte = try peek() else { return nil }
        offset += 1
        return byte
    }
    @discardableResult func skipWhitespace() throws -> Bool {
        var newline = false
        while let byte = try peek(), [9, 10, 13, 32].contains(byte) {
            newline = newline || byte == 10 || byte == 13
            try read()
        }
        return newline
    }
}

final class CSVRecordReader {
    struct Field { let text: String; let wasQuoted: Bool }
    private let input: DataFileByteReader
    init(url: URL) throws { input = try DataFileByteReader(url: url) }

    func next() throws -> [Field]? {
        guard try input.peek() != nil else { return nil }
        var fields: [Field] = []
        var recordBytes = 0
        while true {
            let quoted = try input.peek() == 34
            var bytes = Data()
            if quoted { try input.read() }
            var closedQuote = !quoted
            while let byte = try input.peek() {
                if quoted {
                    try input.read()
                    if byte == 34 {
                        if try input.peek() == 34 { try input.read(); bytes.append(34) }
                        else { closedQuote = true; break }
                    } else { bytes.append(byte) }
                } else {
                    if [44, 10, 13].contains(byte) { break }
                    guard byte != 34 else { throw DataTransferError.invalidCSV }
                    try input.read()
                    bytes.append(byte)
                }
                guard bytes.count + recordBytes <= DataTransferCodec.maximumImportRecordBytes else { throw DataTransferError.recordTooLarge }
            }
            guard closedQuote else { throw DataTransferError.invalidCSV }
            guard let text = String(data: bytes, encoding: .utf8) else { throw DataTransferError.invalidUTF8 }
            fields.append(Field(text: text, wasQuoted: quoted))
            recordBytes += bytes.count
            guard fields.count <= DataTransferCodec.maximumColumns else { throw DataTransferError.tooManyColumns }
            guard let separator = try input.read() else { return fields }
            if separator == 44 { continue }
            if separator == 13 {
                if try input.peek() == 10 { try input.read() }
                return fields
            }
            if separator == 10 { return fields }
            throw DataTransferError.invalidCSV
        }
    }
}

final class JSONRecordReader {
    private let input: DataFileByteReader
    private let maximumBytes: Int
    private var isArray = false
    private var started = false
    private var hasRecord = false
    private var finished = false

    init(url: URL, maximumBytes: Int = DataTransferCodec.maximumImportRecordBytes) throws {
        input = try DataFileByteReader(url: url)
        self.maximumBytes = maximumBytes
    }

    func next() throws -> String? {
        guard !finished else { return nil }
        let newline = try input.skipWhitespace()
        var consumedComma = false
        if !started {
            started = true
            isArray = try input.peek() == 91
            if isArray { try input.read(); try input.skipWhitespace() }
        } else if isArray, hasRecord {
            if try input.peek() == 44 { try input.read(); try input.skipWhitespace(); consumedComma = true }
            else if try input.peek() != 93 { throw DataTransferError.invalidJSON }
        } else if hasRecord, try input.peek() != nil, !newline { throw DataTransferError.invalidJSON }

        if isArray, try input.peek() == 93 {
            guard !consumedComma else { throw DataTransferError.invalidJSON }
            try input.read()
            try input.skipWhitespace()
            guard try input.peek() == nil else { throw DataTransferError.invalidJSON }
            finished = true
            return nil
        }
        guard let first = try input.peek() else {
            guard !isArray else { throw DataTransferError.invalidJSON }
            finished = true
            return nil
        }
        guard first == 123 else { throw DataTransferError.invalidJSON }
        var bytes = Data()
        var stack: [UInt8] = []
        var quoted = false
        var escaped = false
        while let byte = try input.read() {
            bytes.append(byte)
            guard bytes.count <= maximumBytes else { throw DataTransferError.recordTooLarge }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                stack.append(byte)
                guard stack.count <= 100 else { throw DataTransferError.invalidJSON }
            } else if byte == 125 || byte == 93 {
                guard stack.popLast() == (byte == 125 ? 123 : 91) else { throw DataTransferError.invalidJSON }
                if stack.isEmpty {
                    guard let text = String(data: bytes, encoding: .utf8) else { throw DataTransferError.invalidUTF8 }
                    hasRecord = true
                    return text
                }
            }
        }
        throw DataTransferError.invalidJSON
    }
}

final class DataImportRecordReader {
    let columnNames: [String]
    private let csv: CSVRecordReader?
    private let json: JSONRecordReader?
    private let nullToken: String
    private var firstRecord: [CSVRecordReader.Field]?

    init(url: URL, format: DataImportFormat, hasHeader: Bool, nullToken: String) throws {
        self.nullToken = nullToken
        if format == .csv {
            let reader = try CSVRecordReader(url: url)
            csv = reader; json = nil
            guard let first = try reader.next() else { throw DataTransferError.emptyFile }
            if hasHeader {
                let names = first.map(\.text)
                guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else { throw DataTransferError.invalidCSVHeader }
                columnNames = names
            } else {
                columnNames = first.indices.map { "column_\($0 + 1)" }
                firstRecord = first
            }
        } else {
            json = try JSONRecordReader(url: url); csv = nil; columnNames = []
        }
    }

    func next() throws -> DataImportRecord? {
        if let csv {
            let fields: [CSVRecordReader.Field]?
            if let initial = firstRecord { fields = initial; firstRecord = nil }
            else { fields = try csv.next() }
            guard let fields else { return nil }
            guard fields.count == columnNames.count else { throw DataTransferError.inconsistentColumns }
            return DataImportRecord(fields: Dictionary(uniqueKeysWithValues: zip(columnNames, fields).compactMap { name, field in
                if !field.wasQuoted, field.text == "\\M" { return nil }
                return (name, !field.wasQuoted && field.text == nullToken ? .null : .text(field.text))
            }), documentJSON: nil)
        }
        guard let text = try json?.next() else { return nil }
        return DataImportRecord(fields: try JSONImportFields.parse(text), documentJSON: text)
    }
}

/// Keep numeric lexemes intact; parsing through NSNumber or BSON Double would round large SQL values.
private enum JSONImportFields {
    static func parse(_ text: String) throws -> [String: QueryCell] {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] else { throw DataTransferError.invalidJSON }
        let bytes = Array(text.utf8)
        var offset = 1
        var fields: [String: QueryCell] = [:]
        func skipWhitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        func stringEnd(from start: Int) throws -> Int {
            var cursor = start + 1
            var escaped = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { return cursor + 1 }
                cursor += 1
            }
            throw DataTransferError.invalidJSON
        }
        skipWhitespace()
        while offset < bytes.count, bytes[offset] != 125 {
            guard bytes[offset] == 34 else { throw DataTransferError.invalidJSON }
            let keyEnd = try stringEnd(from: offset)
            let name = try JSONDecoder().decode(String.self, from: Data(bytes[offset..<keyEnd]))
            guard fields[name] == nil else { throw DataTransferError.invalidJSON }
            offset = keyEnd
            skipWhitespace()
            guard offset < bytes.count, bytes[offset] == 58 else { throw DataTransferError.invalidJSON }
            offset += 1
            skipWhitespace()
            let start = offset
            var depth = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == 34 { offset = try stringEnd(from: offset); continue }
                if byte == 123 || byte == 91 { depth += 1 }
                else if byte == 125 || byte == 93 {
                    if depth == 0 { break }
                    depth -= 1
                } else if byte == 44, depth == 0 { break }
                offset += 1
            }
            let raw = String(decoding: bytes[start..<offset], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[name] = try cell(raw)
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == 44 { offset += 1; skipWhitespace() }
            else { break }
        }
        return fields
    }

    private static func cell(_ raw: String) throws -> QueryCell {
        if raw == "null" { return .null }
        if raw == "true" || raw == "false" { return .boolean(raw == "true") }
        if raw.first == "\"" { return .text(try JSONDecoder().decode(String.self, from: Data(raw.utf8))) }
        if DataTransferCodec.isJSONNumber(raw) { return raw.contains(".") || raw.lowercased().contains("e") ? .decimal(raw) : .integer(raw) }
        if raw.first == "{", let document = try? MongoExtendedJSON.decode("{\"value\":" + raw + "}"), let value = document["value"] {
            switch value {
            case .document, .array: break
            default: return MongoDatabaseClient.cell(value)
            }
        }
        return .json(raw)
    }
}
