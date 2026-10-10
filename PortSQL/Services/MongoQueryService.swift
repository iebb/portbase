import Foundation
@preconcurrency import SwiftBSON

enum MongoClientError: LocalizedError {
    case invalidCommand
    case unsupportedCommand
    case serverFailure(Int?)

    var errorDescription: String? {
        switch self {
        case .invalidCommand:
            L10n.text("Enter one valid MongoDB Extended JSON command (up to 1 MiB).")
        case .unsupportedCommand:
            L10n.text("This MongoDB command or option is not supported. Server-side JavaScript and unbounded cursors are disabled.")
        case .serverFailure(let code):
            L10n.format("MongoDB rejected the operation (code %@). Check permissions, command syntax, and server logs.", code.map(String.init) ?? "—")
        }
    }
}

// SwiftBSON predates Sendable. This value owns an immutable, copy-on-write document.
struct MongoQuery: @unchecked Sendable {
    let command: BSONDocument
    let name: String
    let isReadOnly: Bool
}

enum MongoQueryService {
    private static let options: [String: Set<String>] = [
        "find": ["filter", "sort", "projection", "skip", "limit", "batchSize", "singleBatch", "hint", "collation"],
        "aggregate": ["pipeline", "cursor", "allowDiskUse", "hint", "collation"],
        "count": ["query", "limit", "skip", "hint", "collation"],
        "distinct": ["key", "query", "collation"],
        "listDatabases": ["nameOnly", "authorizedDatabases", "filter"],
        "listCollections": ["nameOnly", "authorizedCollections", "filter", "cursor"],
        "listIndexes": ["cursor"],
        "collStats": ["scale"],
        "dbStats": ["scale", "freeStorage"],
        "ping": [],
        "explain": ["verbosity"],
        "insert": ["documents", "ordered", "writeConcern"],
        "update": ["updates", "ordered", "writeConcern"],
        "delete": ["deletes", "ordered", "writeConcern"],
        "create": ["validator", "validationLevel", "validationAction", "capped", "size", "max", "collation"],
        "drop": ["writeConcern"],
        "createIndexes": ["indexes", "writeConcern", "commitQuorum"],
        "dropIndexes": ["index", "writeConcern"]
    ]
    private static let writes: Set<String> = ["insert", "update", "delete", "create", "drop", "createIndexes", "dropIndexes"]
    private static let prohibited: Set<String> = ["$where", "$function", "$accumulator", "$changeStream"]

    static func parse(_ text: String) throws -> MongoQuery {
        guard text.utf8.count <= 1_048_576 else { throw MongoClientError.invalidCommand }
        let document: BSONDocument
        do { document = try MongoExtendedJSON.decode(text) }
        catch { throw MongoClientError.invalidCommand }
        return try validate(document)
    }

    private static func validate(_ document: BSONDocument) throws -> MongoQuery {
        let commands = document.keys.filter { options[$0] != nil }
        guard commands.count == 1, let name = commands.first, let allowed = options[name] else {
            throw MongoClientError.unsupportedCommand
        }
        guard Set(document.keys).isSubset(of: allowed.union([name, "maxTimeMS", "comment"])) else {
            throw MongoClientError.unsupportedCommand
        }
        try validateValues(.document(document), depth: 0)
        var isReadOnly = !writes.contains(name)
        if name == "aggregate" {
            guard let pipeline = document["pipeline"]?.arrayValue,
                  pipeline.allSatisfy({ $0.documentValue?.count == 1 }) else {
                throw MongoClientError.invalidCommand
            }
            isReadOnly = !containsWriteStage(.array(pipeline))
        }
        if name == "explain" {
            guard let nested = document["explain"]?.documentValue else { throw MongoClientError.invalidCommand }
            let explained = try validate(nested)
            guard ["find", "aggregate", "count", "distinct"].contains(explained.name), explained.isReadOnly else {
                throw DatabaseServiceError.readOnlyQueryRequired
            }
        }
        // Command name must be first in the wire document, regardless of JSON key order.
        let ordered = document.keys.first == name ? document : try MongoExtendedJSON.orderedDocument(
            [(name, document[name]!)] + document.filter { $0.key != name }.map { ($0.key, $0.value) })
        return MongoQuery(command: ordered, name: name, isReadOnly: isReadOnly)
    }

    private static func validateValues(_ value: BSON, depth: Int) throws {
        guard depth <= 100 else { throw MongoClientError.invalidCommand }
        switch value {
        case .document(let document):
            guard Set(document.keys).count == document.keys.count else { throw MongoClientError.invalidCommand }
            for (key, child) in document {
                guard !key.contains("\0"), !prohibited.contains(key) else { throw MongoClientError.unsupportedCommand }
                try validateValues(child, depth: depth + 1)
            }
        case .array(let values):
            for child in values { try validateValues(child, depth: depth + 1) }
        case .code, .codeWithScope:
            throw MongoClientError.unsupportedCommand
        default: break
        }
    }

    private static func containsWriteStage(_ value: BSON) -> Bool {
        switch value {
        case .document(let document):
            return document.contains { key, value in
                key == "$out" || key == "$merge" || containsWriteStage(value)
            }
        case .array(let values): return values.contains(where: containsWriteStage)
        default: return false
        }
    }

    static func assessment(for text: String, readOnly: Bool) -> SQLSafetyAssessment? {
        do {
            let query = try parse(text)
            guard !query.isReadOnly else { return nil }
            return SQLSafetyAssessment(
                title: L10n.text(readOnly ? "Read-only connection" : "Confirm write"),
                message: L10n.text(readOnly
                    ? "This server is read-only. Disable read-only mode before making changes."
                    : "This statement can change database data. Review it carefully before running it against a live database.") + "\n\n" + text,
                requiresConfirmation: !readOnly,
                blocksExecution: readOnly
            )
        } catch {
            return SQLSafetyAssessment(title: L10n.text("Execution failed"), message: error.localizedDescription,
                                       requiresConfirmation: false, blocksExecution: true)
        }
    }

    static func explain(_ text: String) -> String? {
        guard let query = try? parse(text), query.isReadOnly,
              ["find", "aggregate", "count", "distinct"].contains(query.name) else { return nil }
        return pretty(["explain": .document(query.command), "verbosity": "queryPlanner"])
    }

    static func browse(collection: String, filter: String, sort: String, limit: Int, skip: Int) throws -> String {
        let filterDocument = try jsonObject(filter)
        let sortDocument = try jsonObject(sort)
        var command: BSONDocument = ["find": .string(collection), "filter": .document(filterDocument),
                                     "limit": BSON(limit), "skip": BSON(skip)]
        command["sort"] = .document(sortDocument.isEmpty ? ["_id": 1] : sortDocument)
        let text = pretty(command)
        _ = try parse(text)
        return text
    }

    static func jsonObject(_ text: String) throws -> BSONDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 1_048_576 else { throw MongoClientError.invalidCommand }
        do { return try MongoExtendedJSON.decode(trimmed.isEmpty ? "{}" : trimmed) }
        catch { throw MongoClientError.invalidCommand }
    }

    static func pretty(_ document: BSONDocument, canonical: Bool = false) -> String {
        // Do not round-trip through JSONSerialization: it can reorder sort keys and round Int64 values.
        formattedJSON(MongoExtendedJSON.encode(document, canonical: canonical))
    }

    static func formattedJSON(_ text: String) -> String {
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; output.append(character)
            case "{", "[":
                depth += 1
                output.append(character)
                output += "\n" + String(repeating: "  ", count: depth)
            case "}", "]":
                depth = max(0, depth - 1)
                output += "\n" + String(repeating: "  ", count: depth)
                output.append(character)
            case ",": output += ",\n" + String(repeating: "  ", count: depth)
            case ":": output += ": "
            default: if !character.isWhitespace { output.append(character) }
            }
        }
        return output
    }

    static func template(_ kind: String, collection: String) -> String {
        switch kind {
        case "aggregate": return pretty(["aggregate": .string(collection), "pipeline": [["$match": [:]], ["$limit": 100]], "cursor": [:]])
        case "insert": return pretty(["insert": .string(collection), "documents": [["name": ""]]])
        case "update": return pretty(["update": .string(collection), "updates": [["q": ["_id": .objectID()], "u": ["$set": ["name": ""]], "multi": false]]])
        case "delete": return pretty(["delete": .string(collection), "deletes": [["q": ["_id": .objectID()], "limit": 1]]])
        case "listIndexes": return pretty(["listIndexes": .string(collection)])
        default: return (try? browse(collection: collection, filter: "", sort: "", limit: 25, skip: 0)) ?? "{}"
        }
    }
}
