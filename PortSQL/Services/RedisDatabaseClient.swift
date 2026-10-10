import Foundation
import NIOCore
import NIOPosix
import NIOSSL

private struct RedisRequest: @unchecked Sendable {
    let arguments: [Data]
    let reply: EventLoopPromise<RedisReply>
}

private final class RedisReplyHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = RedisReply
    typealias OutboundIn = RedisRequest
    typealias OutboundOut = ByteBuffer
    private var pending: EventLoopPromise<RedisReply>?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        guard pending == nil else {
            request.reply.fail(RedisClientError.malformedReply)
            promise?.fail(RedisClientError.malformedReply)
            return
        }
        do {
            let buffer = try RedisRESPCodec.encode(request.arguments, allocator: context.channel.allocator)
            pending = request.reply
            context.write(wrapOutboundOut(buffer), promise: promise)
        } catch {
            request.reply.fail(error)
            promise?.fail(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let promise = pending else { context.close(promise: nil); return }
        pending = nil
        promise.succeed(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        pending?.fail(error); pending = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        pending?.fail(RedisClientError.connectionClosed); pending = nil
        context.fireChannelInactive()
    }
}

private final class RedisSocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var closed = false
    private var writing = false

    func install(_ channel: Channel) {
        lock.withLock {
            if closed { channel.close(promise: nil) } else { self.channel = channel }
        }
    }

    func close() {
        let current = lock.withLock { () -> Channel? in
            closed = true
            let current = channel; channel = nil
            return current
        }
        current?.close(promise: nil)
    }

    func markWrite() { lock.withLock { writing = true } }
    var writeStarted: Bool { lock.withLock { writing } }
}

private struct RedisConnection: @unchecked Sendable {
    let channel: Channel

    func send(_ arguments: [Data]) async throws -> RedisReply {
        try Task.checkCancellation()
        let promise = channel.eventLoop.makePromise(of: RedisReply.self)
        do {
            try await channel.writeAndFlush(RedisRequest(arguments: arguments, reply: promise)).get()
            let reply = try await promise.futureResult.get()
            if case .error(let message) = reply {
                // Error messages may echo keys or credentials; expose only the stable server code.
                let token = message.prefix { $0 != 32 && $0 != 13 && $0 != 10 }.prefix(64)
                let code = String(decoding: token.filter { (65...90).contains($0) || $0 == 95 }, as: UTF8.self)
                if code == "MOVED" || code == "ASK" { throw RedisClientError.clusterRedirect }
                throw RedisClientError.server(code.isEmpty ? "ERR" : code)
            }
            return reply
        } catch {
            // A failed flush may not trigger errorCaught; closing resolves any pending reply.
            channel.close(promise: nil)
            throw error
        }
    }

    func read(_ name: String, _ arguments: [Data] = []) async throws -> RedisReply {
        let command = try RedisCommandService.command(name, arguments)
        guard command.isReadOnly else { throw DatabaseServiceError.readOnlyQueryRequired }
        return try await send(command.arguments)
    }
}

enum RedisDatabaseClient {
    static func execute(query: RedisCommand, profile: ConnectionProfile, database: String,
                        timeoutSeconds: Int, eventLoopGroup: EventLoopGroup) async throws -> QueryResultTable {
        let checked = try RedisCommandService.validate(query.arguments)
        guard !profile.isReadOnly || checked.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        let lifetime = RedisSocketLifetime()
        do {
            let reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                                 eventLoopGroup: eventLoopGroup, lifetime: lifetime) { connection in
                if !checked.isReadOnly { lifetime.markWrite() }
                return try await connection.send(checked.arguments)
            }
            return try makeResult(reply: reply, command: checked)
        } catch {
            if lifetime.writeStarted {
                if case RedisClientError.server = error { throw error }
                if case RedisClientError.clusterRedirect = error { throw error }
                throw RedisClientError.writeOutcomeUnknown
            }
            throw error
        }
    }

    static func scan(profile: ConnectionProfile, database: String, cursor: String, pattern: Data?, type: String?,
                     timeoutSeconds: Int, eventLoopGroup: EventLoopGroup) async throws -> RedisScanPage {
        let reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup) { connection in
            var arguments = [Data(cursor.utf8), Data("COUNT".utf8), Data("100".utf8)]
            if let pattern { arguments += [Data("MATCH".utf8), pattern] }
            if let type, !type.isEmpty { arguments += [Data("TYPE".utf8), Data(type.utf8)] }
            return try await connection.read("SCAN", arguments)
        }
        let (next, values) = try scanValues(reply)
        var seen = Set<Data>()
        let keys = try values.map { value -> RedisKey in
            guard let bytes = value.bytes else { throw RedisClientError.malformedReply }
            return RedisKey(bytes: bytes)
        }.filter { seen.insert($0.bytes).inserted }
        return RedisScanPage(keys: Array(keys.prefix(RedisCommandService.maximumRows)), cursor: next,
                             isTruncated: keys.count > RedisCommandService.maximumRows)
    }

    static func inspect(profile: ConnectionProfile, database: String, key: RedisKey, cursor: String = "0",
                        timeoutSeconds: Int, eventLoopGroup: EventLoopGroup) async throws -> RedisKeyInspection {
        try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                 eventLoopGroup: eventLoopGroup) { connection in
            let typeReply = try await connection.read("TYPE", [key.bytes])
            guard let bytes = typeReply.bytes, let type = String(data: bytes, encoding: .ascii) else { throw RedisClientError.malformedReply }
            guard type == "none" || RedisCommandService.keyTypes.contains(type) else { throw RedisClientError.unsupportedKeyType }
            let ttlReply = try await connection.read("PTTL", [key.bytes])
            guard let ttl = ttlReply.integer else { throw RedisClientError.malformedReply }
            if type == "none" || ttl == -2 {
                return RedisKeyInspection(key: key, type: "none", ttlMilliseconds: -2, length: nil,
                                          result: table(columns: [L10n.text("Value")], rows: []), nextCursor: nil)
            }
            let lengthCommand = ["string": "STRLEN", "hash": "HLEN", "list": "LLEN", "set": "SCARD", "zset": "ZCARD", "stream": "XLEN"][type]!
            let length = try await connection.read(lengthCommand, [key.bytes]).integer
            let command: RedisCommand
            var next: String?
            switch type {
            case "string":
                guard let offset = Int64(cursor), offset >= 0, offset <= Int64.max - 65_535 else { throw RedisClientError.invalidCommand }
                command = try RedisCommandService.command("GETRANGE", [key.bytes, Data(String(offset).utf8), Data(String(offset + 65_535).utf8)])
                if let length, length > offset + 65_536 { next = String(offset + 65_536) }
            case "hash", "set", "zset":
                command = try RedisCommandService.command(type == "hash" ? "HSCAN" : type == "set" ? "SSCAN" : "ZSCAN",
                                                          [key.bytes, Data(cursor.utf8), Data("COUNT".utf8), Data("100".utf8)])
            case "list":
                guard let offset = Int64(cursor), offset >= 0, offset <= Int64.max - 99 else { throw RedisClientError.invalidCommand }
                command = try RedisCommandService.command("LRANGE", [key.bytes, Data(String(offset).utf8), Data(String(offset + 99).utf8)])
                if let length, length > offset + 100 { next = String(offset + 100) }
            case "stream":
                let start = cursor == "0" ? "-" : cursor
                guard start == "-" || (start.hasPrefix("(") && start.dropFirst().allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") })) else { throw RedisClientError.invalidCommand }
                command = try RedisCommandService.command("XRANGE", [key.bytes, Data(start.utf8), Data("+".utf8), Data("COUNT".utf8), Data("100".utf8)])
            default: throw RedisClientError.unsupportedKeyType
            }
            let reply: RedisReply
            do { reply = try await connection.send(command.arguments) }
            catch RedisClientError.server(let code) where code == "WRONGTYPE" { throw RedisClientError.keyChanged }
            if ["hash", "set", "zset"].contains(type) {
                let values = try scanValues(reply)
                next = values.cursor == "0" ? nil : values.cursor
            } else if type == "stream", let entries = reply.elements, entries.count == 100,
                      let lastID = entries.last?.elements?.first?.bytes, let value = String(data: lastID, encoding: .ascii) {
                next = "(" + value
            }
            let finalType = try await connection.read("TYPE", [key.bytes])
            guard finalType.bytes == bytes else { throw RedisClientError.keyChanged }
            var result = try makeResult(reply: reply, command: command)
            if type == "list", let offset = Int64(cursor) {
                result.rows = result.rows.enumerated().map { index, row in
                    var cells = row.cells
                    if !cells.isEmpty { cells[0] = .integer(String(offset + Int64(index))) }
                    return QueryRow(cells: cells)
                }
            }
            return RedisKeyInspection(key: key, type: type, ttlMilliseconds: ttl, length: length, result: result, nextCursor: next)
        }
    }

    private static func withConnection<Value: Sendable>(
        profile: ConnectionProfile, database: String, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
        lifetime: RedisSocketLifetime = .init(), operation: @escaping @Sendable (RedisConnection) async throws -> Value
    ) async throws -> Value {
        let timeout = max(1, min(timeoutSeconds, 300))
        guard let number = Int32(database.trimmingCharacters(in: .whitespacesAndNewlines)), number >= 0 else { throw RedisClientError.invalidDatabase }
        return try await withQueryTimeout(seconds: timeout, closeConnection: { lifetime.close() }) {
            defer { lifetime.close() }
            if profile.usesTLS, profile.usesSSHTunnel, DatabaseService.isIPAddress(profile.host) {
                throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
            }
            let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
            // RESP has no TLS-upgrade negotiation. Prefer TLS must never downgrade after a failed handshake.
            let tls = profile.usesTLS ? try NIOSSLContext(configuration: DatabaseService.tlsConfiguration(for: profile)) : nil
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(.seconds(Int64(min(timeout, 5))))
                .channelInitializer { channel in
                    lifetime.install(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        if let tls {
                            let hostname = DatabaseService.isIPAddress(endpoint.serverHostname) ? nil : endpoint.serverHostname
                            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: hostname))
                        }
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(RedisRESPDecoder()))
                        try channel.pipeline.syncOperations.addHandler(RedisReplyHandler())
                    }
                }
                .connect(host: endpoint.host, port: endpoint.port).get()
            let connection = RedisConnection(channel: channel)
            try Task.checkCancellation()
            if !profile.password.isEmpty || !profile.username.isEmpty {
                var auth = [Data("AUTH".utf8)]
                if !profile.username.isEmpty { auth.append(Data(profile.username.utf8)) }
                auth.append(Data(profile.password.utf8))
                do {
                    let result = try await connection.send(auth)
                    guard result.bytes == Data("OK".utf8) else { throw RedisClientError.authenticationFailed }
                } catch RedisClientError.server { throw RedisClientError.authenticationFailed }
            }
            // Database zero is the initial selection and is also the only database on Redis Cluster.
            if number != 0 {
                let result = try await connection.send([Data("SELECT".utf8), Data(String(number).utf8)])
                guard result.bytes == Data("OK".utf8) else { throw RedisClientError.invalidDatabase }
            }
            return try await operation(connection)
        }
    }

    private static func scanValues(_ reply: RedisReply) throws -> (cursor: String, values: [RedisReply]) {
        guard let parts = reply.elements, parts.count == 2, let cursorBytes = parts[0].bytes,
              let cursor = String(data: cursorBytes, encoding: .ascii), UInt64(cursor) != nil,
              let values = parts[1].elements else { throw RedisClientError.malformedReply }
        return (cursor, values)
    }

    static func makeResult(reply: RedisReply, command: RedisCommand) throws -> QueryResultTable {
        var columns = [L10n.text("Index"), L10n.text("Value")]
        var rows: [[QueryCell]] = []
        var cursor: String?
        switch command.name {
        case "SCAN", "HSCAN", "SSCAN", "ZSCAN":
            let page = try scanValues(reply)
            cursor = page.cursor
            if command.name == "HSCAN" || command.name == "ZSCAN" {
                guard page.values.count.isMultiple(of: 2) else { throw RedisClientError.malformedReply }
                columns = command.name == "HSCAN" ? [L10n.text("Field"), L10n.text("Value")] : [L10n.text("Member"), L10n.text("Score")]
                rows = stride(from: 0, to: page.values.count, by: 2).map { index in
                    [page.values[index].cell, command.name == "ZSCAN" ? numeric(page.values[index + 1]) : page.values[index + 1].cell]
                }
            } else {
                columns = [command.name == "SCAN" ? L10n.text("Key") : L10n.text("Member")]
                rows = page.values.map { [$0.cell] }
            }
        case "MGET", "HMGET", "ZMSCORE":
            guard let values = reply.elements else { throw RedisClientError.malformedReply }
            let arguments = command.arguments.dropFirst(command.name == "MGET" ? 1 : 2)
            guard arguments.count == values.count else { throw RedisClientError.malformedReply }
            columns = [command.name == "MGET" ? L10n.text("Key") : L10n.text("Field"), L10n.text("Value")]
            rows = zip(arguments, values).map { [RedisBytes.cell($0), command.name == "ZMSCORE" ? numeric($1) : $1.cell] }
        case "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE":
            guard let values = reply.elements else { throw RedisClientError.malformedReply }
            if command.arguments.dropFirst(4).contains(where: { String(data: $0, encoding: .ascii)?.uppercased() == "WITHSCORES" }) {
                guard values.count.isMultiple(of: 2) else { throw RedisClientError.malformedReply }
                columns = [L10n.text("Member"), L10n.text("Score")]
                rows = stride(from: 0, to: values.count, by: 2).map { [values[$0].cell, numeric(values[$0 + 1])] }
            } else {
                rows = values.enumerated().map { [.integer(String($0.offset)), $0.element.cell] }
            }
        case "XRANGE", "XREVRANGE":
            guard let entries = reply.elements else { throw RedisClientError.malformedReply }
            columns = [L10n.text("Entry ID"), L10n.text("Fields")]
            rows = try entries.map { entry in
                guard let values = entry.elements, values.count == 2, let fields = values[1].elements,
                      fields.count.isMultiple(of: 2) else { throw RedisClientError.malformedReply }
                return [values[0].cell, values[1].cell]
            }
        case "INFO":
            guard let bytes = reply.bytes, let text = String(data: bytes, encoding: .utf8) else { throw RedisClientError.malformedReply }
            columns = [L10n.text("Field"), L10n.text("Value")]
            rows = text.split(whereSeparator: \.isNewline).compactMap { line in
                guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
                let value = String(line[line.index(after: colon)...])
                return [.text(String(line[..<colon])), numeric(.bulk(Data(value.utf8)))]
            }
        default:
            if let values = reply.elements {
                rows = values.enumerated().map { [.integer(String($0.offset)), $0.element.cell] }
            } else {
                columns = [L10n.text("Value")]
                rows = [[reply.cell]]
            }
        }
        var result = table(columns: columns, rows: rows)
        result.sourceQuery = command.preview
        result.generatedMutation = command.isReadOnly ? nil : command.preview
        if let cursor { result.executionSummary += " · " + L10n.format("Cursor %@", cursor) }
        return result
    }

    private static func numeric(_ reply: RedisReply) -> QueryCell {
        guard let bytes = reply.bytes, let string = String(data: bytes, encoding: .ascii) else { return reply.cell }
        if Int64(string) != nil { return .integer(string) }
        if Double(string) != nil { return .decimal(string) }
        return reply.cell
    }

    private static func table(columns: [String], rows: [[QueryCell]]) -> QueryResultTable {
        let bounded = Array(rows.prefix(RedisCommandService.maximumRows))
        return QueryResultTable(columns: columns.map { QueryColumn(name: $0, type: "RESP") }, rows: bounded.map { QueryRow(cells: $0) },
            executionSummary: L10n.format("Redis returned %d rows.", bounded.count), generatedMutation: nil, profiles: [],
            sourceTableReference: nil, isTruncated: rows.count > RedisCommandService.maximumRows)
    }
}
