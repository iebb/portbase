import XCTest
@preconcurrency import SwiftBSON
@testable import PortSQL

final class MongoDocumentEditingTests: XCTestCase {
    func testURIExtractsSecretsAndPreservesExplicitTransportAndReplicaOptions() throws {
        let uri = try MongoConnectionURI.parse("mongodb://user:p%40ss%3Aword@db-a.example.com:27018,db-b.example.com/orders?authSource=admin&replicaSet=rs0&tls=false&w=majority")
        let base = ConnectionProfile(name: "Fixture", engine: .mysql, host: "localhost", port: 3306,
                                     username: "", password: "", database: "")
        let profile = uri.applying(to: base)
        XCTAssertEqual(profile.password, "p@ss:word")
        XCTAssertTrue(profile.passwordWasExplicitlySet)
        XCTAssertEqual(profile.host, "db-a.example.com")
        XCTAssertEqual(profile.mongoConnection.additionalHosts.first?.host, "db-b.example.com")
        XCTAssertEqual(profile.mongoConnection.replicaSet, "rs0")
        XCTAssertEqual(profile.authenticationDatabase, "admin")
        XCTAssertEqual(profile.transportSecurityMode, .plaintext)
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("p@ss:word"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("mongodb://"))
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: encoded).password, "")
        let srv = try MongoConnectionURI.parse("mongodb+srv://user:pw@cluster.example.com/?retryWrites=true&w=majority&appName=PortSQL")
        XCTAssertEqual(srv.tls, true)
        XCTAssertTrue(srv.options.usesSRV)
        for invalid in ["mongodb+srv://cluster.example.com:27017/", "mongodb://a,b/?directConnection=true",
                        "mongodb://a/?tls=false&ssl=true", "mongodb://a/?tlsAllowInvalidCertificates=true",
                        "mongodb://a/?authSource=admin&authsource=other"] {
            XCTAssertThrowsError(try MongoConnectionURI.parse(invalid))
        }
    }

    func testTypedDraftRoundTripsBSONAndMakesReplacementLiteral() throws {
        let json = #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"long":{"$numberLong":"9223372036854775807"},"decimal":{"$numberDecimal":"123.4500"},"date":{"$date":{"$numberLong":"-1"}},"binary":{"$binary":{"base64":"AP8=","subType":"80"}},"nested":[{"z":1,"a":2}],"empty":"","null":null,"$set":{"x":1}}"#
        let original = try MongoExtendedJSON.decode(json)
        let draft = try MongoDocumentDraft(mode: .edit, originalJSON: json)
        XCTAssertEqual(try draft.document().buffer, original.buffer)
        let command = try draft.request(collection: "documents").command()
        let literal = command["updates"]?.arrayValue?.first?.documentValue?["u"]?.arrayValue?.first?.documentValue?["$replaceWith"]?.documentValue?["$literal"]?.documentValue
        XCTAssertEqual(literal?.buffer, original.buffer)
        var duplicate = try MongoDocumentDraft(mode: .duplicate, originalJSON: json)
        XCTAssertNotEqual(try duplicate.document()["_id"], original["_id"])
        duplicate.fields.append(MongoDocumentField(name: "empty"))
        XCTAssertThrowsError(try duplicate.document())
        let changedID = MongoDocumentMutationRequest(operation: .replace, collection: "documents", originalJSON: json,
                                                    replacementJSON: #"{"_id":1}"#)
        XCTAssertThrowsError(try changedID.documents())
    }

    func testReplicaTransactionsSaveAndRejectConcurrentDocumentChanges() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTSQL_TEST_MONGODB_REPLICA_PORT"] ?? "") else {
            throw XCTSkip("Set the isolated MongoDB replica-set fixture port.")
        }
        let service = DatabaseService.shared
        var profile = ConnectionProfile(name: "Document transaction fixture", engine: .mongodb, host: "127.0.0.1", port: port,
                                        username: "", password: "", database: "portsql_codex_validation", usesTLS: false)
        let collection = "document_tx_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        func execute(_ command: BSONDocument, policy: DatabaseExecutionPolicy = .readOnly) async throws -> QueryResultTable {
            try await service.execute(query: MongoQueryService.pretty(command, canonical: true), profile: profile,
                                      database: "portsql_codex_validation", policy: policy, timeoutSeconds: 10)
        }
        _ = try await execute(["create": .string(collection)], policy: .userQuery(confirmed: true))
        do {
            let inserted = try MongoDocumentDraft(mode: .insert).request(collection: collection)
            _ = try await service.performMongoDocumentMutation(request: inserted, profile: profile, database: "portsql_codex_validation",
                                                               policy: .mutation(expectedAffectedRows: 1), timeoutSeconds: 10)
            var result = try await execute(["find": .string(collection)])
            let original = try XCTUnwrap(result.documents?.first)
            var draft = try MongoDocumentDraft(mode: .edit, originalJSON: original)
            draft.fields.append(MongoDocumentField(name: "value", type: .int64, value: "9223372036854775807"))
            let replacement = try draft.request(collection: collection)
            _ = try await service.performMongoDocumentMutation(request: replacement, profile: profile, database: "portsql_codex_validation",
                                                               policy: .mutation(expectedAffectedRows: 1), timeoutSeconds: 10)
            do {
                _ = try await service.performMongoDocumentMutation(request: replacement, profile: profile, database: "portsql_codex_validation",
                                                                   policy: .mutation(expectedAffectedRows: 1), timeoutSeconds: 10)
                XCTFail("A stale document must not overwrite the saved value")
            } catch MongoConnectionError.documentChanged { }
            result = try await execute(["find": .string(collection)])
            let current = try XCTUnwrap(result.documents?.first)
            XCTAssertEqual(try MongoExtendedJSON.decode(current)["value"]?.int64Value, Int64.max)
            let delete = try MongoDocumentDraft(mode: .delete, originalJSON: current).request(collection: collection)
            profile.isReadOnly = true
            do {
                _ = try await service.performMongoDocumentMutation(request: delete, profile: profile, database: "portsql_codex_validation",
                                                                   policy: .mutation(expectedAffectedRows: 1), timeoutSeconds: 10)
                XCTFail("Read-only profiles must block editor writes")
            } catch DatabaseServiceError.readOnlyViolation { }
            profile.isReadOnly = false
            _ = try await service.performMongoDocumentMutation(request: delete, profile: profile, database: "portsql_codex_validation",
                                                               policy: .mutation(expectedAffectedRows: 1), timeoutSeconds: 10)
            result = try await execute(["find": .string(collection)])
            XCTAssertTrue(result.rows.isEmpty)
            _ = try await execute(["drop": .string(collection)], policy: .userQuery(confirmed: true))
        } catch {
            profile.isReadOnly = false
            _ = try? await execute(["drop": .string(collection)], policy: .userQuery(confirmed: true))
            throw error
        }
    }
}
