import Foundation
@preconcurrency import SwiftBSON

enum MongoEditorMode: String, Codable, CaseIterable, Identifiable {
    case find, aggregate, command
    var id: Self { self }
    var title: String {
        switch self {
        case .find: L10n.text("Find")
        case .aggregate: L10n.text("Aggregation")
        case .command: L10n.text("Command")
        }
    }
}

struct MongoPipelineStage: Identifiable, Codable {
    var id = UUID()
    var operation = "$match"
    var body = "{}"
    var isEnabled = true

    static let operations = ["$match", "$project", "$group", "$sort", "$limit", "$skip", "$unwind", "$lookup", "$set", "$unset", "$count", "$facet", "$bucket", "$replaceRoot"]

    static func template(for operation: String) -> String {
        switch operation {
        case "$group": #"{"_id": "$category", "total": {"$sum": "$amount"}}"#
        case "$sort": #"{"_id": 1}"#
        case "$limit": "100"
        case "$skip": "0"
        case "$unwind": #""$items""#
        case "$count": #""count""#
        case "$unset": #""field""#
        case "$lookup": #"{"from": "collection", "localField": "key", "foreignField": "_id", "as": "joined"}"#
        case "$bucket": #"{"groupBy": "$amount", "boundaries": [0, 100, 1000], "default": "other"}"#
        case "$replaceRoot": #"{"newRoot": "$document"}"#
        default: "{}"
        }
    }
}

struct MongoQueryDraft: Codable {
    var mode: MongoEditorMode = .find
    var collection = ""
    var filter = "{}"
    var projection = "{}"
    var sort = #"{"_id": 1}"#
    var skip = "0"
    var limit = "100"
    var stages = [MongoPipelineStage()]

    func command(fallbackCollection: String?) throws -> String {
        let name = collection.isEmpty ? (fallbackCollection ?? "") : collection
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.contains("\0") else {
            throw MongoDraftError.message(L10n.text("Choose a collection."))
        }
        let command: BSONDocument
        switch mode {
        case .find:
            guard let skipValue = Int(skip), skipValue >= 0,
                  let limitValue = Int(limit), (1...10_000).contains(limitValue) else {
                throw MongoDraftError.message(L10n.text("Skip must be zero or greater. Limit must be between 1 and 10,000."))
            }
            command = ["find": .string(name), "filter": .document(try object(filter, label: "Filter (JSON)")),
                       "projection": .document(try object(projection, label: "Projection (JSON)")),
                       "sort": .document(try object(sort, label: "Sort (JSON)")), "skip": BSON(skipValue), "limit": BSON(limitValue)]
        case .aggregate:
            let pipeline: [BSON] = try stages.enumerated().compactMap { index, stage in
                guard stage.isEnabled else { return nil }
                do {
                    guard MongoPipelineStage.operations.contains(stage.operation),
                          let value = try MongoExtendedJSON.decode("{\"value\":" + stage.body + "}")["value"] else {
                        throw MongoClientError.invalidCommand
                    }
                    return .document(try MongoExtendedJSON.orderedDocument([(stage.operation, value)]))
                } catch { throw MongoDraftError.message(L10n.format("Stage %d: Invalid JSON.", index + 1)) }
            }
            command = ["aggregate": .string(name), "pipeline": .array(pipeline), "cursor": [:]]
        case .command: throw MongoClientError.invalidCommand
        }
        let text = MongoQueryService.pretty(command)
        guard try MongoQueryService.parse(text).isReadOnly else { throw DatabaseServiceError.readOnlyQueryRequired }
        return text
    }

    private func object(_ text: String, label: String) throws -> BSONDocument {
        do { return try MongoQueryService.jsonObject(text) }
        catch { throw MongoDraftError.message(L10n.format("%@: Invalid JSON object.", L10n.text(label))) }
    }
}

private enum MongoDraftError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
