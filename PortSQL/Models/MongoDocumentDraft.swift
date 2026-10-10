import Foundation
@preconcurrency import SwiftBSON

struct MongoDocumentMutationContext: Identifiable {
    var id: String { profile.id.uuidString + ":" + database + ":" + collection }
    let profile: ConnectionProfile
    let database: String
    let collection: String

    @MainActor
    static func from(workspace: WorkspaceViewModel) -> Self? {
        guard let profile = workspace.selectedBookmark, profile.engine == .mongodb, !profile.isReadOnly,
              let database = workspace.activeDatabaseName, let collection = workspace.selectedExplorerTable,
              workspace.result.isExplorerGenerated == true, workspace.result.sourceTableReference == collection.displayName,
              let query = try? MongoQueryService.parse(workspace.result.sourceQuery ?? ""), query.name == "find",
              query.command["find"]?.stringValue == collection.name,
              query.command["projection"] == nil || query.command["projection"]?.documentValue?.isEmpty == true else { return nil }
        return Self(profile: profile, database: database, collection: collection.name)
    }

    @MainActor
    static func insertionContext(workspace: WorkspaceViewModel) -> Self? {
        guard let profile = workspace.selectedBookmark, profile.engine == .mongodb, !profile.isReadOnly,
              let database = workspace.activeDatabaseName, let collection = workspace.selectedExplorerTable else { return nil }
        return Self(profile: profile, database: database, collection: collection.name)
    }
}

struct MongoDocumentMutationRequest: @unchecked Sendable {
    enum Operation: String, Sendable { case insert, replace, delete }
    let operation: Operation
    let collection: String
    let originalJSON: String?
    let replacementJSON: String?

    func documents() throws -> (original: BSONDocument?, replacement: BSONDocument?) {
        guard !collection.isEmpty, !collection.contains("\0"), !collection.hasPrefix("system."), collection.utf8.count <= 255 else {
            throw MongoConnectionError.invalidDocument
        }
        let original = try originalJSON.map { try MongoExtendedJSON.decode($0, maximumBytes: 128 * 1_024 * 1_024) }
        let replacement = try replacementJSON.map { try MongoExtendedJSON.decode($0, maximumBytes: 128 * 1_024 * 1_024) }
        guard original.map({ $0.buffer.readableBytes <= 16 * 1_024 * 1_024 }) ?? true,
              replacement.map({ $0.buffer.readableBytes <= 16 * 1_024 * 1_024 }) ?? true else { throw MongoConnectionError.invalidDocument }
        switch operation {
        case .insert:
            guard original == nil, replacement?["_id"] != nil else { throw MongoConnectionError.invalidDocument }
        case .replace:
            guard let original, let replacement, let identifier = original["_id"] else { throw MongoConnectionError.invalidDocument }
            guard replacement["_id"] == identifier else { throw MongoConnectionError.immutableIdentifier }
        case .delete:
            guard original?["_id"] != nil, replacement == nil else { throw MongoConnectionError.invalidDocument }
        }
        return (original, replacement)
    }

    func command() throws -> BSONDocument {
        let documents = try documents()
        switch operation {
        case .insert:
            return ["insert": .string(collection), "documents": [.document(documents.replacement!)], "ordered": true]
        case .replace:
            return ["update": .string(collection), "updates": [["q": ["_id": documents.original!["_id"]!],
                "u": [["$replaceWith": ["$literal": .document(documents.replacement!)]]],
                "multi": false, "upsert": false]], "ordered": true]
        case .delete:
            return ["delete": .string(collection), "deletes": [["q": ["_id": documents.original!["_id"]!], "limit": 1]], "ordered": true]
        }
    }

    func previewCommand() throws -> String { MongoQueryService.pretty(try command(), canonical: true) }
}

enum MongoFieldType: String, CaseIterable, Identifiable {
    case string = "String", int32 = "Int32", int64 = "Int64", double = "Double", decimal = "Decimal128"
    case boolean = "Boolean", null = "Null", date = "Date", objectID = "ObjectId", document = "Document", array = "Array"
    case extendedJSON = "Extended JSON"
    var id: String { rawValue }
    var title: String { L10n.text(rawValue) }
}

struct MongoDocumentField: Identifiable {
    let id = UUID()
    var name: String
    var type: MongoFieldType
    var value: String
    var isIdentifier = false
    private var originalValue: BSON?
    private var originalType: MongoFieldType?
    private var originalText: String?

    init(name: String, value: BSON, locksIdentifier: Bool) {
        self.name = name
        isIdentifier = name == "_id" && locksIdentifier
        switch value {
        case .string(let value): type = .string; self.value = value
        case .int32(let value): type = .int32; self.value = String(value)
        case .int64(let value): type = .int64; self.value = String(value)
        case .double(let value):
            type = .double
            self.value = value.isNaN ? "NaN" : (value == .infinity ? "Infinity" : (value == -.infinity ? "-Infinity" : String(value)))
        case .decimal128(let value): type = .decimal; self.value = value.description
        case .bool(let value): type = .boolean; self.value = String(value)
        case .null: type = .null; self.value = ""
        case .datetime(let value):
            type = .extendedJSON
            self.value = Self.encode(.datetime(value))
            let formatter = Self.dateFormatter()
            let text = formatter.string(from: value)
            if let parsed = formatter.date(from: text) {
                let original: BSONDocument = ["value": .datetime(value)]
                let roundTrip: BSONDocument = ["value": .datetime(parsed)]
                if original.buffer == roundTrip.buffer { type = .date; self.value = text }
            }
        case .objectID(let value): type = .objectID; self.value = value.hex
        case .document(let document): type = .document; self.value = MongoQueryService.pretty(document, canonical: true)
        case .array: type = .array; self.value = Self.encode(value)
        default: type = .extendedJSON; self.value = Self.encode(value)
        }
        originalValue = value
        originalType = type
        originalText = self.value
    }

    init(name: String = "", type: MongoFieldType = .string, value: String = "") {
        self.name = name; self.type = type; self.value = value
    }

    func bsonValue() throws -> BSON {
        // Formatting is for display. Unchanged fields retain the BSON value instead
        // of being parsed back through a lossy date or scalar text representation.
        if type == originalType, value == originalText, let originalValue { return originalValue }
        switch type {
        case .string: return .string(value)
        case .int32:
            guard let number = Int32(value) else { throw MongoConnectionError.invalidDocument }
            return .int32(number)
        case .int64:
            guard let number = Int64(value) else { throw MongoConnectionError.invalidDocument }
            return .int64(number)
        case .double: return try Self.scalar("$numberDouble", value)
        case .decimal: return try Self.scalar("$numberDecimal", value)
        case .boolean:
            guard value == "true" || value == "false" else { throw MongoConnectionError.invalidDocument }
            return .bool(value == "true")
        case .null: return .null
        case .date:
            let fractional = Self.dateFormatter()
            let plain = Self.dateFormatter(includingFractionalSeconds: false)
            guard let date = fractional.date(from: value) ?? plain.date(from: value) else { throw MongoConnectionError.invalidDocument }
            return .datetime(date)
        case .objectID: return .objectID(try BSONObjectID(value))
        case .document: return .document(try MongoExtendedJSON.decode(value, maximumBytes: 128 * 1_024 * 1_024))
        case .array, .extendedJSON:
            let document = try MongoExtendedJSON.decode("{\"value\":" + value + "}", maximumBytes: 128 * 1_024 * 1_024)
            guard let result = document["value"], type != .array || result.arrayValue != nil else { throw MongoConnectionError.invalidDocument }
            return result
        }
    }

    static func encode(_ value: BSON) -> String {
        MongoExtendedJSON.encode(value, canonical: true)
    }

    private static func dateFormatter(includingFractionalSeconds: Bool = true) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includingFractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func scalar(_ key: String, _ value: String) throws -> BSON {
        let quoted = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let document = try MongoExtendedJSON.decode("{\"v\":{\"" + key + "\":" + quoted + "}}")
        guard let result = document["v"] else { throw MongoConnectionError.invalidDocument }
        return result
    }
}

struct MongoDocumentDraft {
    enum Mode: String { case insert, edit, duplicate, delete }
    let mode: Mode
    let originalJSON: String?
    var fields: [MongoDocumentField]

    init(mode: Mode, originalJSON: String? = nil) throws {
        self.mode = mode
        self.originalJSON = originalJSON
        var document = try originalJSON.map { try MongoExtendedJSON.decode($0, maximumBytes: 128 * 1_024 * 1_024) } ?? BSONDocument()
        if mode == .insert || mode == .duplicate { document["_id"] = .objectID() }
        fields = document.map { MongoDocumentField(name: $0.key, value: $0.value, locksIdentifier: mode == .edit || mode == .delete) }
    }

    func document() throws -> BSONDocument {
        guard fields.count <= 10_000 else { throw MongoConnectionError.invalidDocument }
        return try MongoExtendedJSON.orderedDocument(fields.map { field in
            guard !field.name.contains("\0") else { throw MongoConnectionError.invalidDocument }
            return (field.name, try field.bsonValue())
        })
    }

    func request(collection: String) throws -> MongoDocumentMutationRequest {
        let operation: MongoDocumentMutationRequest.Operation = mode == .delete ? .delete : (mode == .edit ? .replace : .insert)
        let request = MongoDocumentMutationRequest(operation: operation, collection: collection,
            originalJSON: mode == .edit || mode == .delete ? originalJSON : nil,
            replacementJSON: mode == .delete ? nil : MongoExtendedJSON.encode(try document(), canonical: true))
        _ = try request.documents()
        return request
    }
}
