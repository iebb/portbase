import Foundation
import NIOCore
@preconcurrency import SwiftBSON

/// JSON dictionaries are unordered in the BSON library's Codable path. MongoDB sort,
/// compound index, and embedded-document predicates require the user's field order.
enum MongoExtendedJSON {
    static func decode(_ text: String, maximumBytes: Int = 1_048_576) throws -> BSONDocument {
        guard text.utf8.count <= max(1, min(maximumBytes, 128 * 1_024 * 1_024)) else { throw MongoClientError.invalidCommand }
        var parser = OrderedParser(bytes: Array(text.utf8))
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count, let document = value.documentValue else { throw MongoClientError.invalidCommand }
        return document
    }

    // SwiftBSON 3's array writer repeatedly scans all prior keys. Build only the
    // container framing here in linear time; SwiftBSON still encodes every scalar
    // and validates the complete BSON document. https://bsonspec.org/spec.html
    static func orderedDocument(_ pairs: [(String, BSON)]) throws -> BSONDocument {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        buffer.writeInteger(Int32(0), endianness: .little)
        var keys = Set<String>()
        for (key, value) in pairs {
            guard !key.contains("\0"), keys.insert(key).inserted else { throw MongoClientError.invalidCommand }
            switch value {
            case .document(let document):
                buffer.writeInteger(UInt8(3))
                buffer.writeString(key)
                buffer.writeInteger(UInt8(0))
                buffer.writeImmutableBuffer(document.buffer)
            case .array(let values):
                let array = try orderedDocument(values.enumerated().map { (String($0.offset), $0.element) })
                buffer.writeInteger(UInt8(4))
                buffer.writeString(key)
                buffer.writeInteger(UInt8(0))
                buffer.writeImmutableBuffer(array.buffer)
            default:
                let scalar: BSONDocument = [key: value]
                buffer.writeImmutableBuffer(scalar.buffer.getSlice(at: 4, length: scalar.buffer.readableBytes - 5)!)
            }
        }
        buffer.writeInteger(UInt8(0))
        guard buffer.readableBytes <= 16 * 1_024 * 1_024 else { throw MongoClientError.invalidCommand }
        buffer.setInteger(Int32(buffer.readableBytes), at: 0, endianness: .little)
        return try BSONDocument(fromBSON: buffer)
    }

    static func encode(_ document: BSONDocument, canonical: Bool) -> String {
        encode(.document(document), canonical: canonical)
    }

    static func encode(_ value: BSON, canonical: Bool) -> String {
        let encoder = ExtendedJSONEncoder()
        encoder.format = canonical ? .canonical : .relaxed
        return encodeValue(value, encoder: encoder)
    }

    /// Readable relaxed Extended JSON for grids, summaries and the document tree. Numbers drop their BSON
    /// width and binary values show only their size, so copy, export and edits use the canonical form.
    static func display(_ value: BSON, pretty: Bool = false) -> String {
        displayValue(value, indent: pretty ? "" : nil)
    }

    /// The readable form of one canonical Extended JSON value, or nil when it doesn't parse.
    static func display(canonical: String, pretty: Bool) -> String? {
        guard let value = try? decode("{\"v\":" + canonical + "}", maximumBytes: 128 * 1_024 * 1_024)["v"] else { return nil }
        return display(value, pretty: pretty)
    }

    static func binarySummary(_ binary: BSONBinary) -> String {
        if binary.subtype == .uuid, let uuid = try? binary.toUUID() { return "UUID(\"" + uuid.uuidString.lowercased() + "\")" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(binary.data.readableBytes), countStyle: .file)
        return L10n.format("Binary(%@, subtype %@)", size, String(format: "%02x", binary.subtype.rawValue))
    }

    private static func displayValue(_ value: BSON, indent: String?) -> String {
        let childIndent = indent.map { $0 + "  " }
        switch value {
        case .document(let document):
            return container("{", "}", document.map { ResultCopyFormatter.jsonString($0.key) + ": " + displayValue($0.value, indent: childIndent) },
                             indent: indent)
        case .array(let values):
            return container("[", "]", values.map { displayValue($0, indent: childIndent) }, indent: indent)
        case .string(let text): return ResultCopyFormatter.jsonString(text)
        case .int32(let number): return String(number)
        case .int64(let number): return String(number)
        case .double(let number):
            if number.isNaN { return "NaN" }
            return number.isInfinite ? (number < 0 ? "-Infinity" : "Infinity") : String(number)
        case .decimal128(let number): return number.description
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .objectID(let id): return "{\"$oid\": \"" + id.hex + "\"}"
        // Relaxed Extended JSON writes dates in years 1970 through 9999 as ISO-8601 text.
        case .datetime(let date) where (0...253_402_300_799).contains(date.timeIntervalSince1970):
            return "{\"$date\": \"" + isoDate(date) + "\"}"
        case .binary(let binary): return binarySummary(binary)
        default: return encode(value, canonical: false)
        }
    }

    /// ISO-8601 text with the BSON date's exact milliseconds; formatting the Double directly can drop one.
    static func isoDate(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        let seconds = (milliseconds / 1_000).rounded(.down)
        let text = Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle())
        return text.dropLast() + "." + String(format: "%03d", Int(milliseconds - seconds * 1_000)) + "Z"
    }

    private static func container(_ open: String, _ close: String, _ members: [String], indent: String?) -> String {
        guard !members.isEmpty else { return open + close }
        guard let indent else { return open + members.joined(separator: ", ") + close }
        let line = "\n" + indent + "  "
        return open + line + members.joined(separator: "," + line) + "\n" + indent + close
    }

    private static func encodeValue(_ value: BSON, encoder: ExtendedJSONEncoder) -> String {
        switch value {
        case .document(let document):
            return "{" + document.map { key, value in
                let encodedKey = String(decoding: try! JSONEncoder().encode(key), as: UTF8.self)
                return encodedKey + ":" + encodeValue(value, encoder: encoder)
            }.joined(separator: ",") + "}"
        case .array(let values):
            return "[" + values.map { encodeValue($0, encoder: encoder) }.joined(separator: ",") + "]"
        default:
            // All BSON scalar cases are supported by the official Extended JSON encoder.
            return String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
    }

    private struct OrderedParser {
        let bytes: [UInt8]
        var index = 0
        private static let typeMarkers: Set<String> = [
            "$oid", "$date", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal", "$binary",
            "$regularExpression", "$timestamp", "$minKey", "$maxKey", "$undefined", "$symbol", "$dbPointer", "$code"
        ]

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> BSON {
            guard depth <= 100 else { throw MongoClientError.invalidCommand }
            skipWhitespace()
            guard index < bytes.count else { throw MongoClientError.invalidCommand }
            let start = index
            if bytes[index] == 123 { // {
                index += 1
                skipWhitespace()
                var pairs: [(String, BSON)] = []
                var keys = Set<String>()
                if consume(125) { return .document(BSONDocument()) }
                while true {
                    skipWhitespace()
                    let key = try string()
                    guard !key.contains("\0"), keys.insert(key).inserted else { throw MongoClientError.invalidCommand }
                    skipWhitespace()
                    guard consume(58) else { throw MongoClientError.invalidCommand }
                    pairs.append((key, try value(depth: depth + 1)))
                    skipWhitespace()
                    if consume(125) { break }
                    guard consume(44) else { throw MongoClientError.invalidCommand }
                }
                if !keys.isDisjoint(with: Self.typeMarkers) {
                    return try scalar(start: start, end: index)
                }
                return .document(try MongoExtendedJSON.orderedDocument(pairs))
            }
            if bytes[index] == 91 { // [
                index += 1
                skipWhitespace()
                var values: [BSON] = []
                if consume(93) { return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    skipWhitespace()
                    if consume(93) { break }
                    guard consume(44) else { throw MongoClientError.invalidCommand }
                }
                return .array(values)
            }
            if bytes[index] == 34 { return .string(try string()) }
            while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw MongoClientError.invalidCommand }
            return try scalar(start: start, end: index)
        }

        private func scalar(start: Int, end: Int) throws -> BSON {
            let literal = String(decoding: bytes[start..<end], as: UTF8.self)
            do {
                let document = try BSONDocument(fromJSON: "{\"v\":" + literal + "}")
                guard let value = document["v"] else { throw MongoClientError.invalidCommand }
                return value
            } catch { throw MongoClientError.invalidCommand }
        }

        private mutating func string() throws -> String {
            let start = index
            guard consume(34) else { throw MongoClientError.invalidCommand }
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw MongoClientError.invalidCommand }
                }
                index += 1
            }
            throw MongoClientError.invalidCommand
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
