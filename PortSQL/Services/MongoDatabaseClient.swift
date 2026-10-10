import Foundation
import BSON
import Logging
import MongoClient
import NIOCore
import NIOPosix
import NIOSSL
@preconcurrency import SwiftBSON

// Own the socket from bootstrap through authentication, so cancellation also closes partial connections.
private final class MongoSocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: (Channel, MongoClientContext)] = [:]
    private var isClosed = false

    func install(_ channel: Channel, context: MongoClientContext) {
        lock.withLock {
            if isClosed {
                channel.close(promise: nil)
                Task { await context.cancelQueries(CancellationError()) }
            } else {
                connections[ObjectIdentifier(channel)] = (channel, context)
            }
        }
    }

    func context(for channel: Channel) throws -> MongoClientContext {
        try lock.withLock {
            guard !isClosed, let context = connections[ObjectIdentifier(channel)]?.1 else { throw CancellationError() }
            return context
        }
    }

    func close() {
        let active = lock.withLock {
            isClosed = true
            let active = Array(connections.values)
            connections.removeAll()
            return active
        }
        for (channel, context) in active {
            channel.close(promise: nil)
            // Closing a raw MongoKitten channel alone does not resolve pending replies.
            Task { await context.cancelQueries(CancellationError()) }
        }
    }
}

private final class MongoChannelLifecycleHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let mongoContext: MongoClientContext

    init(context: MongoClientContext) { mongoContext = context }

    func channelInactive(context: ChannelHandlerContext) {
        Task { [mongoContext] in await mongoContext.cancelQueries(ChannelError.ioOnClosedChannel) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Task { [mongoContext] in await mongoContext.cancelQueries(error) }
        context.close(promise: nil)
    }
}

private struct MongoBatch: @unchecked Sendable {
    let documents: [BSONDocument]
    let affectedRows: Int?
    let isTruncated: Bool
}

enum MongoDatabaseClient {
    static let maximumRows = 10_000
    static let maximumResultBytes = 32 * 1_024 * 1_024

    static func execute(
        query: MongoQuery,
        profile: ConnectionProfile,
        database: String,
        timeoutSeconds: Int,
        eventLoopGroup: EventLoopGroup
    ) async throws -> QueryResultTable {
        let batch: MongoBatch = try await withConnection(profile: profile, timeoutSeconds: timeoutSeconds,
            eventLoopGroup: eventLoopGroup, retryReadOnly: query.isReadOnly) { connected in
                try await materialize(query: query, connection: connected.connection, database: database,
                                      timeoutSeconds: timeoutSeconds, majority: connected.profile.mongoConnection.majorityWriteConcern)
            }
        return makeResult(documents: batch.documents, affectedRows: batch.affectedRows, truncated: batch.isTruncated, profileName: profile.name)
    }

    private struct Connected: @unchecked Sendable {
        let connection: MongoConnection
        let hello: BSONDocument
        let profile: ConnectionProfile
    }

    private static func withConnection<T: Sendable>(
        profile: ConnectionProfile, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
        retryReadOnly: Bool = false, operation: @escaping @Sendable (Connected) async throws -> T
    ) async throws -> T {
        let lifetime = MongoSocketLifetime()
        return try await withQueryTimeout(seconds: max(1, min(timeoutSeconds, 300)), closeConnection: { lifetime.close() }) {
            defer { lifetime.close() }
            var lastError: Error = MongoConnectionError.primaryUnavailable
            for attempt in 0..<(retryReadOnly ? 2 : 1) {
                try Task.checkCancellation()
                let connected = try await selectPrimary(profile: profile, timeoutSeconds: timeoutSeconds,
                                                        eventLoopGroup: eventLoopGroup, lifetime: lifetime)
                do {
                    let value = try await operation(connected)
                    await connected.connection.close()
                    return value
                } catch {
                    await connected.connection.close()
                    lastError = error
                    // Materialized reads can restart before delivering any rows. Never replay a write or streamed result.
                    guard retryReadOnly, attempt == 0, isPrimaryChange(error) else { throw error }
                }
            }
            throw lastError
        }
    }

    private static func selectPrimary(profile: ConnectionProfile, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
                                      lifetime: MongoSocketLifetime) async throws -> Connected {
        try MongoConnectionURI.validateProfile(profile)
        var effective = profile
        let base = try MongoHostAddress.parse(profile.host.contains(":") ? "[\(profile.host)]:\(profile.port)" : "\(profile.host):\(profile.port)")
        var seeds = [base] + profile.mongoConnection.additionalHosts
        if profile.mongoConnection.usesSRV {
            guard !profile.mongoConnection.directConnection, profile.mongoConnection.additionalHosts.isEmpty,
                  !DatabaseService.isIPAddress(profile.host) else { throw MongoConnectionError.invalidURI }
            let resolved = try await MongoDNSResolver.resolve(host: profile.host, timeoutSeconds: timeoutSeconds)
            seeds = resolved.hosts
            if !effective.mongoConnection.authenticationSourceIsExplicit, let source = resolved.options["authsource"] {
                effective.authenticationDatabase = source
            }
            if effective.mongoConnection.replicaSet.isEmpty { effective.mongoConnection.replicaSet = resolved.options["replicaset"] ?? "" }
        }
        let cached = await MongoTopologyCache.shared.hosts(for: profile)
        var candidates = profile.mongoConnection.directConnection ? [base] :
            (profile.mongoConnection.usesSRV ? (seeds + cached).uniqued() : (cached + seeds).uniqued())
        var known = Set(candidates)
        var expectedSet = effective.mongoConnection.replicaSet
        var lastError: Error = MongoConnectionError.primaryUnavailable
        var sawSecondary = false
        let selectionDeadline = ContinuousClock.now + .seconds(min(max(1, timeoutSeconds), 30))
        for round in 0..<60 {
            var index = 0
            while index < candidates.count, index < 32 {
                try Task.checkCancellation()
                let candidate = candidates[index]
                index += 1
                var memberProfile = effective
                memberProfile.host = candidate.host
                memberProfile.port = candidate.port
                do {
                    let connection = try await open(profile: memberProfile, timeoutSeconds: timeoutSeconds,
                                                    eventLoopGroup: eventLoopGroup, lifetime: lifetime)
                    let hello: BSONDocument
                    do { hello = try await send(["hello": 1], connection: connection, database: "admin") }
                    catch MongoClientError.serverFailure(let code) where code == 59 {
                        hello = try await send(["isMaster": 1], connection: connection, database: "admin")
                    }
                    let set = hello["setName"]?.stringValue ?? ""
                    if !expectedSet.isEmpty, set != expectedSet {
                        await connection.close()
                        throw MongoConnectionError.replicaSetMismatch
                    }
                    if expectedSet.isEmpty, !set.isEmpty { expectedSet = set }
                    if !profile.mongoConnection.directConnection, !set.isEmpty {
                        let discovered = ([hello["primary"]?.stringValue].compactMap { $0 }
                            + (hello["hosts"]?.arrayValue ?? []).compactMap(\.stringValue)
                            + (hello["passives"]?.arrayValue ?? []).compactMap(\.stringValue))
                        for name in discovered.prefix(32) {
                            guard let address = try? MongoHostAddress.parse(name), known.count < 32 else { continue }
                            if known.insert(address).inserted { candidates.append(address) }
                        }
                    }
                    let primary = hello["isWritablePrimary"]?.boolValue ?? hello["ismaster"]?.boolValue ?? false
                    if primary {
                        await MongoTopologyCache.shared.remember([candidate] + candidates.filter { $0 != candidate }, for: profile)
                        return Connected(connection: connection, hello: hello, profile: effective)
                    }
                    sawSecondary = true
                    await connection.close()
                } catch {
                    if error is CancellationError { throw error }
                    lastError = error
                }
            }
            guard !profile.mongoConnection.directConnection, sawSecondary, round < 59,
                  ContinuousClock.now < selectionDeadline else { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        if sawSecondary { throw MongoConnectionError.primaryUnavailable }
        throw lastError
    }

    private static func open(profile: ConnectionProfile, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
                             lifetime: MongoSocketLifetime) async throws -> MongoConnection {
        if profile.usesTLS, profile.usesSSHTunnel, DatabaseService.isIPAddress(profile.host) {
            throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
        }
        let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
        // MongoDB cannot safely signal that TLS is unsupported. All candidates keep the requested TLS policy.
        let tls = profile.usesTLS ? try NIOSSLContext(configuration: DatabaseService.tlsConfiguration(for: profile)) : nil
        let logger = Logger(label: "ad.neko.portsql.mongo", factory: { _ in SwiftLogNoOpLogHandler() })
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(Int64(min(max(1, timeoutSeconds), 5))))
            .channelInitializer { channel in
                let context = MongoClientContext(logger: logger)
                lifetime.install(channel, context: context)
                return channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        let hostname = DatabaseService.isIPAddress(endpoint.serverHostname) ? nil : endpoint.serverHostname
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: hostname))
                    }
                    try channel.pipeline.syncOperations.addHandler(MongoChannelLifecycleHandler(context: context))
                }.flatMap { MongoConnection.addHandlers(to: channel, context: context) }
            }
            .connect(host: endpoint.host, port: endpoint.port).get()
        let connection = MongoConnection(channel: channel, context: try lifetime.context(for: channel))
        do {
            try Task.checkCancellation()
            if !profile.mongoConnection.applicationName.isEmpty {
                let client: BSONDocument = ["application": ["name": .string(profile.mongoConnection.applicationName)],
                    "driver": ["name": "Portbase", "version": "1"], "os": ["type": "Darwin"], "platform": "Swift"]
                do { _ = try await send(["hello": 1, "client": .document(client)], connection: connection, database: "admin") }
                catch MongoClientError.serverFailure(let code) where code == 59 {
                    _ = try await send(["isMaster": 1, "client": .document(client)], connection: connection, database: "admin")
                }
            }
            // The first application handshake is ordered before authentication and never includes credentials in logs.
            switch profile.mongoConnection.authenticationMechanism {
            case "SCRAM-SHA-1" where !profile.username.isEmpty:
                try await connection.authenticate(clientDetails: nil, using: .scramSha1(username: profile.username, password: profile.password),
                                                  to: profile.authenticationDatabase)
            case "SCRAM-SHA-256" where !profile.username.isEmpty:
                try await connection.authenticate(clientDetails: nil, using: .scramSha256(username: profile.username, password: profile.password),
                                                  to: profile.authenticationDatabase)
            default:
                try await connection.authenticate(clientDetails: nil,
                    using: profile.username.isEmpty ? .unauthenticated : .auto(username: profile.username, password: profile.password),
                    to: profile.authenticationDatabase.isEmpty ? "admin" : profile.authenticationDatabase)
            }
            return connection
        } catch { await connection.close(); throw error }
    }

    private static func isPrimaryChange(_ error: Error) -> Bool {
        if case MongoClientError.serverFailure(let code) = error {
            return code.map { [91, 189, 10107, 11600, 11602, 13435, 13436].contains($0) } ?? false
        }
        return false
    }

    static func performDocumentMutation(
        request: MongoDocumentMutationRequest, profile: ConnectionProfile, database: String,
        timeoutSeconds: Int, eventLoopGroup: EventLoopGroup
    ) async throws -> QueryResultTable {
        guard profile.engine == .mongodb, !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        let documents = try request.documents()
        let command = try request.command()
        let response: MongoBatch = try await withConnection(profile: profile, timeoutSeconds: timeoutSeconds,
            eventLoopGroup: eventLoopGroup) { connected in
                let hello = connected.hello
                let wire = hello["maxWireVersion"]?.toInt() ?? 0
                let sharded = hello["msg"]?.stringValue == "isdbgrid"
                guard hello["logicalSessionTimeoutMinutes"] != nil, wire >= 8,
                      sharded || hello["setName"] != nil else {
                    throw MongoConnectionError.transactionsUnavailable
                }
                let session: BSONDocument = ["id": .binary(try BSONBinary(from: UUID()))]
                let connection = connected.connection
                var transactionStarted = false
                var commitAttempted = false
                var recoveryToken: BSONDocument?
                do {
                    if let original = documents.original, let identifier = original["_id"] {
                        let read: BSONDocument = ["find": .string(request.collection), "filter": ["_id": identifier],
                            "limit": 2, "singleBatch": true, "lsid": .document(session), "txnNumber": .int64(1),
                            "autocommit": false, "startTransaction": true, "readConcern": ["level": "snapshot"],
                            "maxTimeMS": BSON(timeoutSeconds * 1_000)]
                        transactionStarted = true
                        let current = try await send(read, connection: connection, database: database)
                        recoveryToken = current["recoveryToken"]?.documentValue
                        guard let batch = current["cursor"]?.documentValue?["firstBatch"]?.arrayValue,
                              batch.count == 1, let document = batch.first?.documentValue,
                              document.buffer == original.buffer else { throw MongoConnectionError.documentChanged }
                    }
                    var write = command
                    write["lsid"] = .document(session)
                    write["txnNumber"] = .int64(1)
                    write["autocommit"] = false
                    write["maxTimeMS"] = BSON(timeoutSeconds * 1_000)
                    if !transactionStarted {
                        write["startTransaction"] = true
                        write["readConcern"] = ["level": "snapshot"]
                        transactionStarted = true
                    }
                    let response = try await send(write, connection: connection, database: database)
                    recoveryToken = response["recoveryToken"]?.documentValue ?? recoveryToken
                    guard let affected = response["n"]?.toInt(), affected == 1 else {
                        throw DatabaseServiceError.unexpectedAffectedRowCount(expected: 1, actual: response["n"]?.toInt() ?? -1)
                    }
                    var commit: BSONDocument = ["commitTransaction": 1, "lsid": .document(session), "txnNumber": .int64(1),
                        "autocommit": false, "writeConcern": ["w": "majority", "wtimeout": BSON(timeoutSeconds * 1_000)],
                        "maxTimeMS": BSON(timeoutSeconds * 1_000)]
                    if let recoveryToken { commit["recoveryToken"] = .document(recoveryToken) }
                    commitAttempted = true
                    _ = try await send(commit, connection: connection, database: "admin")
                    return MongoBatch(documents: documents.replacement.map { [$0] } ?? [], affectedRows: 1, isTruncated: false)
                } catch {
                    // Never replay an uncertain commit. A lost acknowledgement may still mean the server committed.
                    if commitAttempted { throw MongoConnectionError.commitUnknown }
                    if transactionStarted {
                        var abort: BSONDocument = ["abortTransaction": 1, "lsid": .document(session), "txnNumber": .int64(1),
                            "autocommit": false, "maxTimeMS": BSON(min(timeoutSeconds, 5) * 1_000)]
                        if let recoveryToken { abort["recoveryToken"] = .document(recoveryToken) }
                        _ = try? await send(abort, connection: connection, database: "admin")
                    }
                    if case MongoClientError.serverFailure(let code) = error, code == 112 { throw MongoConnectionError.documentChanged }
                    throw error
                }
            }
        return makeResult(documents: response.documents, affectedRows: response.affectedRows,
                          truncated: false, profileName: profile.name)
    }

    static func stream(
        query: MongoQuery, profile: ConnectionProfile, database: String, timeoutSeconds: Int,
        eventLoopGroup: EventLoopGroup, onDocument: @escaping @Sendable (String) throws -> Void
    ) async throws -> Int {
        guard query.isReadOnly else { throw DatabaseServiceError.readOnlyQueryRequired }
        return try await withConnection(profile: profile, timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup) { connected in
            var command = query.command
            command["maxTimeMS"] = BSON(min(command["maxTimeMS"]?.toInt().flatMap { $0 > 0 ? $0 : nil } ?? timeoutSeconds * 1_000,
                                          timeoutSeconds * 1_000))
            if query.name == "find" { command["batchSize"] = 100 }
            if ["aggregate", "listCollections", "listIndexes"].contains(query.name) { command["cursor"] = ["batchSize": 100] }
            var response = try await send(command, connection: connected.connection, database: database)
            var count = 0
            if response["cursor"] != nil {
                var cursorID: Int64 = 0
                var collection: String?
                do {
                    repeat {
                        try Task.checkCancellation()
                        guard let cursor = response["cursor"]?.documentValue, let id = cursor["id"]?.toInt64(),
                              let namespace = cursor["ns"]?.stringValue, namespace.hasPrefix(database + "."),
                              let batch = (cursor["firstBatch"] ?? cursor["nextBatch"])?.arrayValue else { throw MongoClientError.serverFailure(nil) }
                        cursorID = id
                        collection = String(namespace.dropFirst(database.count + 1))
                        for value in batch {
                            try Task.checkCancellation()
                            guard let document = value.documentValue else { throw MongoClientError.serverFailure(nil) }
                            try onDocument(MongoExtendedJSON.encode(document, canonical: true))
                            count += 1
                        }
                        guard cursorID != 0, let collection else { break }
                        response = try await send(["getMore": .int64(cursorID), "collection": .string(collection), "batchSize": 100],
                                                  connection: connected.connection, database: database)
                    } while true
                } catch {
                    if cursorID != 0, let collection {
                        _ = try? await send(["killCursors": .string(collection), "cursors": [.int64(cursorID)]],
                                            connection: connected.connection, database: database)
                    }
                    throw error
                }
            } else {
                let documents: [BSONDocument]
                if let databases = response["databases"]?.arrayValue { documents = databases.compactMap(\.documentValue) }
                else if let values = response["values"]?.arrayValue { documents = values.map { ["value": $0] } }
                else { documents = [response] }
                for document in documents {
                    try Task.checkCancellation()
                    try onDocument(MongoExtendedJSON.encode(document, canonical: true))
                    count += 1
                }
            }
            return count
        }
    }

    private static func materialize(
        query: MongoQuery, connection: MongoConnection, database: String, timeoutSeconds: Int, majority: Bool
    ) async throws -> MongoBatch {
        var command = query.command
        command["maxTimeMS"] = BSON(min(command["maxTimeMS"]?.toInt().flatMap { $0 > 0 ? $0 : nil } ?? timeoutSeconds * 1_000, timeoutSeconds * 1_000))
        if !query.isReadOnly { command["writeConcern"] = ["w": majority ? .string("majority") : 1, "wtimeout": BSON(timeoutSeconds * 1_000)] }
        if query.name == "find" { command["batchSize"] = 100 }
        if ["aggregate", "listCollections", "listIndexes"].contains(query.name) { command["cursor"] = ["batchSize": 100] }
        var reply = try await send(command, connection: connection, database: database)
        var documents: [BSONDocument] = []
        var bytes = 0
        var truncated = false
        var cursorID: Int64 = 0
        var cursorCollection: String?

        if reply["cursor"] != nil {
            repeat {
                try Task.checkCancellation()
                guard let cursor = reply["cursor"]?.documentValue,
                      let id = cursor["id"]?.toInt64(),
                      let namespace = cursor["ns"]?.stringValue,
                      namespace.hasPrefix(database + "."),
                      let values = (cursor["firstBatch"] ?? cursor["nextBatch"])?.arrayValue else {
                    throw MongoClientError.serverFailure(nil)
                }
                cursorID = id
                cursorCollection = String(namespace.dropFirst(database.count + 1))
                for value in values {
                    guard let document = value.documentValue else { throw MongoClientError.serverFailure(nil) }
                    let size = document.buffer.readableBytes
                    guard documents.count < maximumRows, bytes + size <= maximumResultBytes else {
                        truncated = true
                        break
                    }
                    documents.append(document)
                    bytes += size
                }
                guard cursorID != 0, !truncated else { break }
                reply = try await send(["getMore": .int64(cursorID), "collection": .string(cursorCollection!), "batchSize": 100],
                                       connection: connection, database: database)
            } while true
            if cursorID != 0, let cursorCollection {
                _ = try await send(["killCursors": .string(cursorCollection), "cursors": [.int64(cursorID)]],
                                   connection: connection, database: database)
            }
        } else if let databases = reply["databases"]?.arrayValue {
            documents = databases.compactMap(\.documentValue)
        } else if let values = reply["values"]?.arrayValue {
            documents = values.map { ["value": $0] }
        } else {
            documents = [reply]
        }
        // Also cap non-cursor commands such as distinct/listDatabases.
        let bounded = bound(documents)
        return MongoBatch(documents: bounded.documents,
                          affectedRows: query.isReadOnly ? nil : reply["n"]?.toInt(),
                          isTruncated: truncated || bounded.isTruncated)
    }

    private static func send(_ command: BSONDocument, connection: MongoConnection, database: String) async throws -> BSONDocument {
        let reply = try await connection.execute(Document(buffer: command.buffer), namespace: MongoNamespace(to: "$cmd", inDatabase: database))
        let result = try BSONDocument(fromBSON: reply.getDocument().makeByteBuffer())
        guard result["ok"]?.toDouble() == 1,
              result["writeErrors"]?.arrayValue?.isEmpty != false,
              result["writeConcernError"] == nil else {
            let writeError = result["writeErrors"]?.arrayValue?.first?.documentValue
            let concernError = result["writeConcernError"]?.documentValue
            let code = result["code"]?.toInt() ?? writeError?["code"]?.toInt() ?? concernError?["code"]?.toInt()
            // Server error strings can echo submitted data; show the code without leaking it to diagnostics.
            throw MongoClientError.serverFailure(code)
        }
        return result
    }

    private static func bound(_ documents: [BSONDocument]) -> MongoBatch {
        var size = 0
        var count = 0
        for document in documents {
            guard count < maximumRows, size + document.buffer.readableBytes <= maximumResultBytes else { break }
            size += document.buffer.readableBytes
            count += 1
        }
        return MongoBatch(documents: Array(documents.prefix(count)), affectedRows: nil, isTruncated: count != documents.count)
    }

    static func makeResult(documents: [BSONDocument], affectedRows: Int?, truncated: Bool, profileName: String) -> QueryResultTable {
        // Limit tabular projection width; the complete documents remain available in the inspector/export.
        var names: [String] = []
        var seen = Set<String>()
        for document in documents {
            for name in document.keys where names.count < 256 {
                if seen.insert(name).inserted { names.append(name) }
            }
        }
        // Preserve original columns, then expose nested scalar paths for grids and charts.
        // Root keys containing dots win over derived paths with the same display name.
        var paths = names.map { [$0] }
        func visit(_ document: BSONDocument, prefix: [String]) {
            guard prefix.count < 8, names.count < 256 else { return }
            for (key, value) in document {
                let path = prefix + [key]
                if case .document(let child) = value { visit(child, prefix: path) }
                else if path.count > 1, names.count < 256 {
                    let name = path.joined(separator: ".")
                    if seen.insert(name).inserted { names.append(name); paths.append(path) }
                }
            }
        }
        for document in documents { visit(document, prefix: []) }
        let columns = names.map { QueryColumn(name: $0, type: "BSON") }
        let rows = documents.map { document in
            QueryRow(cells: paths.map { path in
                let value = path.dropFirst().reduce(document[path[0]]) { value, key in value?.documentValue?[key] }
                return cell(value)
            })
        }
        let summary: String
        if let affectedRows {
            summary = L10n.format("Statement executed successfully. Affected %@.", L10n.plural("row_count", count: affectedRows))
        } else if truncated {
            summary = L10n.text("Results were truncated at 10,000 documents or 32 MiB. Narrow the filter to retrieve more.")
        } else {
            summary = L10n.format("Fetched %@ from %@.", L10n.plural("row_count", count: documents.count), profileName)
        }
        var result = QueryResultTable(columns: columns, rows: rows, executionSummary: summary, generatedMutation: nil,
                                     profiles: DatabaseService.makeProfiles(columns: columns, rows: rows), sourceTableReference: nil,
                                     affectedRowCount: affectedRows, isTruncated: truncated)
        result.documents = documents.map { MongoExtendedJSON.encode($0, canonical: true) }
        return result
    }

    static func cell(_ value: BSON?) -> QueryCell {
        guard let value else { return .json("{\"$missing\":true}") }
        switch value {
        case .null: return .null
        case .string(let text): return .text(text)
        case .int32(let number): return .integer(String(number))
        case .int64(let number): return .integer(String(number))
        case .double(let number): return .decimal(String(number))
        case .decimal128(let number): return .decimal(number.description)
        case .bool(let flag): return .boolean(flag)
        case .datetime(let date): return .dateTime(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        default:
            // Typed JSON keeps ObjectId, binary subtype, arrays, and nested objects intact.
            let encoder = ExtendedJSONEncoder()
            encoder.format = .canonical
            guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return .null }
            return .json(text)
        }
    }
}

private actor MongoTopologyCache {
    static let shared = MongoTopologyCache()
    private struct Entry { let signature: String; let hosts: [MongoHostAddress]; let date: Date }
    private var entries: [UUID: Entry] = [:]
    private func signature(_ profile: ConnectionProfile) -> String {
        profile.host + ":" + String(profile.port) + ":" + profile.mongoConnection.replicaSet + ":" + String(profile.mongoConnection.usesSRV)
    }
    func hosts(for profile: ConnectionProfile) -> [MongoHostAddress] {
        guard let entry = entries[profile.id], entry.signature == signature(profile), Date().timeIntervalSince(entry.date) < 300 else { return [] }
        return entry.hosts
    }
    func remember(_ hosts: [MongoHostAddress], for profile: ConnectionProfile) {
        entries[profile.id] = Entry(signature: signature(profile), hosts: Array(hosts.prefix(32)), date: .now)
        if entries.count > 100 { entries = entries.filter { Date().timeIntervalSince($0.value.date) < 300 } }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
