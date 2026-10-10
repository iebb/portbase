import Foundation
@preconcurrency import SwiftBSON

struct MongoIndexDescriptor: Identifiable {
    struct Field: Identifiable { var id: String { name }; let name: String; let direction: String }
    var id: String { name }
    let name: String
    let fields: [Field]
    let unique: Bool
    let sparse: Bool
    let hidden: Bool
    let expiration: String?
    let json: String

    init(json: String) throws {
        let document = try MongoExtendedJSON.decode(json)
        guard let name = document["name"]?.stringValue, let keys = document["key"]?.documentValue else { throw MongoClientError.invalidCommand }
        self.name = name
        self.json = json
        self.fields = keys.map { Field(name: $0.key, direction: MongoDatabaseClient.cell($0.value).displayValue) }
        self.unique = document["unique"]?.boolValue ?? (name == "_id_" && keys.count == 1 && keys["_id"] != nil)
        self.sparse = document["sparse"]?.boolValue ?? false
        self.hidden = document["hidden"]?.boolValue ?? false
        self.expiration = document["expireAfterSeconds"].map { MongoDatabaseClient.cell($0).displayValue }
    }
}

extension DatabaseService {
    func mongoIndexes(profile: ConnectionProfile, database: String, collection: String) async throws -> (indexes: [MongoIndexDescriptor], truncated: Bool) {
        guard profile.engine == .mongodb, !collection.isEmpty else { throw DatabaseServiceError.unsupported }
        let query = MongoQueryService.template("listIndexes", collection: collection)
        let result = try await execute(query: query, profile: profile, database: database, policy: .readOnly)
        return (try (result.documents ?? []).map { try MongoIndexDescriptor(json: $0) }, result.isTruncated == true)
    }
}
