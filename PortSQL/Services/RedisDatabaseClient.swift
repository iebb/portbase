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

/// Confirmed writes of an import batch, read after the connection's work ends either way.
private final class RedisWriteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Where a Redis Cluster told a command to go: MOVED for the slot's owner, ASK for one command during a migration.
struct RedisRedirect: Error, Equatable {
    let isAsk: Bool
    let host: String
    let port: Int

    /// Reads "MOVED 3999 10.0.0.5:6381"; IPv6 hosts come with their colons, so the port is after the last one.
    static func parse(_ message: Data) -> RedisRedirect? {
        let parts = String(decoding: message.prefix(512), as: UTF8.self).split(separator: " ")
        guard parts.count == 3, parts[0] == "MOVED" || parts[0] == "ASK", let colon = parts[2].lastIndex(of: ":"),
              let port = Int(parts[2][parts[2].index(after: colon)...]), (1...65_535).contains(port) else { return nil }
        var host = String(parts[2][..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"),
              !host.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { return nil }
        return RedisRedirect(isAsk: parts[0] == "ASK", host: host, port: port)
    }
}

/// A range of cluster slots and the primary that serves them.
private struct RedisSlotRange: Sendable {
    let slots: ClosedRange<Int>
    let node: RedisTarget
}

/// A server other than the profile's own: a cluster node a redirect named, or the primary Sentinel reported.
private struct RedisTarget: Sendable {
    let host: String
    let port: Int
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
                if code == "MOVED" || code == "ASK" {
                    // Only the node's address is read from the message; the rest may name the key.
                    throw RedisRedirect.parse(message) ?? RedisClientError.clusterRedirect
                }
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
        // Each attempt has its own socket lifetime, since the first one's is closed when it ends; the write
        // flag spans both, so a write whose outcome is unknown is never reported as a plain failure.
        let writes = RedisSocketLifetime()
        do {
            // A redirect means the node didn't run the command, so it's sent once more to the node named.
            let reply = try await followingRedirect(profile: profile) { target, asking in
                try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                         eventLoopGroup: eventLoopGroup, target: target) { connection in
                    if asking { _ = try await connection.send([Data("ASKING".utf8)]) }
                    if !checked.isReadOnly { writes.markWrite() }
                    return try await connection.send(checked.arguments)
                }
            }
            return try makeResult(reply: reply, command: checked)
        } catch {
            if writes.writeStarted {
                if case RedisClientError.server = error { throw error }
                if case RedisClientError.clusterRedirect = error { throw error }
                if error is RedisRedirect { throw RedisClientError.clusterRedirect }
                throw RedisClientError.writeOutcomeUnknown
            }
            throw error
        }
    }

    // MARK: Export and import

    /// Rows per page of an export.
    static let exportPageSize = 1_000

    /// Runs a read command to its end: SCAN-family cursors until they return to 0, LRANGE in slices, and
    /// XRANGE/XREVRANGE from each page's last entry. Other commands give one page. Each page uses its own
    /// connection and timeout; the commands carry no state between pages but the cursor or range.
    static func exportPages(query: RedisCommand, profile: ConnectionProfile, database: String, timeoutSeconds: Int,
                            eventLoopGroup: EventLoopGroup, page: (QueryResultTable) throws -> Void) async throws {
        let command = try RedisCommandService.validate(query.arguments)
        guard command.isReadOnly else { throw DatabaseServiceError.readOnlyQueryRequired }
        var arguments = command.arguments
        func word(_ index: Int) -> String { arguments.indices.contains(index) ? String(decoding: arguments[index], as: UTF8.self).uppercased() : "" }
        // A key's command goes to the node that owns it; a SCAN of the keyspace goes to each primary in turn.
        func run(_ arguments: [Data], on node: RedisTarget? = nil) async throws -> (RedisReply, RedisCommand) {
            let current = try RedisCommandService.validate(arguments)
            let reply: RedisReply
            if let node {
                reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                                 eventLoopGroup: eventLoopGroup, target: node) { try await $0.send(current.arguments) }
            } else {
                reply = try await followingRedirect(profile: profile) { target, asking in
                    try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup, target: target) { connection in
                        if asking { _ = try await connection.send([Data("ASKING".utf8)]) }
                        return try await connection.send(current.arguments)
                    }
                }
            }
            return (reply, current)
        }
        switch command.name {
        case "SCAN", "HSCAN", "SSCAN", "ZSCAN":
            let cursorIndex = command.name == "SCAN" ? 1 : 2
            // Larger pages than the browser's, within the client's bound.
            if let count = (0..<arguments.count).first(where: { word($0) == "COUNT" }), arguments.indices.contains(count + 1) {
                arguments[count + 1] = Data(String(exportPageSize).utf8)
            } else { arguments += [Data("COUNT".utf8), Data(String(exportPageSize).utf8)] }
            // SCAN on a cluster node sees only that node's keys, so each primary is scanned to its end.
            let nodes: [RedisTarget?] = command.name == "SCAN" && !profile.usesSSHTunnel
                ? try await clusterPrimaries(profile: profile, database: database, timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup).map { Optional($0) }
                : []
            // SCAN can return a key more than once while the keyspace changes; each key is written once.
            var seen = Set<Data>()
            for node in nodes.isEmpty ? [nil] : nodes {
                arguments[cursorIndex] = Data("0".utf8)
                repeat {
                    try Task.checkCancellation()
                    let (reply, current) = try await run(arguments, on: node)
                    guard let parts = reply.elements, parts.count == 2, let next = parts[0].bytes else { throw RedisClientError.malformedReply }
                    var result = try makeResult(reply: reply, command: current)
                    if command.name == "SCAN" {
                        result.rows = result.rows.filter { row in
                            guard let first = row.cells.first else { return false }
                            return seen.insert(RedisBytes.data(of: first)).inserted
                        }
                    }
                    try page(result)
                    arguments[cursorIndex] = next
                } while arguments[cursorIndex] != Data("0".utf8)
            }
        case "LRANGE":
            let key = arguments[1]
            let length = try await run([Data("LLEN".utf8), key]).0.integer ?? 0
            func resolve(_ index: Int64) -> Int64 { index < 0 ? max(0, length + index) : index }
            guard let first = Int64(String(decoding: arguments[2], as: UTF8.self)), let last = Int64(String(decoding: arguments[3], as: UTF8.self)) else {
                throw RedisClientError.invalidCommand
            }
            var start = resolve(first)
            let end = min(resolve(last), length - 1)
            while start <= end {
                try Task.checkCancellation()
                let stop = min(end, start + Int64(exportPageSize) - 1)
                let (reply, current) = try await run([Data("LRANGE".utf8), key, Data(String(start).utf8), Data(String(stop).utf8)])
                var result = try makeResult(reply: reply, command: current)
                // Indexes count from the start of the list, not of the page.
                result.rows = result.rows.enumerated().map { offset, row in
                    var cells = row.cells
                    if !cells.isEmpty { cells[0] = .integer(String(start + Int64(offset))) }
                    return QueryRow(cells: cells)
                }
                try page(result)
                start = stop + 1
            }
        case "XRANGE", "XREVRANGE":
            arguments = Array(arguments.prefix(4)) + [Data("COUNT".utf8), Data(String(exportPageSize).utf8)]
            while true {
                try Task.checkCancellation()
                let (reply, current) = try await run(arguments)
                let result = try makeResult(reply: reply, command: current, namedStreamFields: false)
                try page(result)
                guard let entries = reply.elements, entries.count == exportPageSize,
                      let lastID = entries.last?.elements?.first?.bytes else { break }
                // The next page continues just past the last entry: XRANGE's start and XREVRANGE's end are both
                // the first bound, and "(" makes it exclusive.
                arguments[2] = Data("(".utf8) + lastID
            }
        default:
            let (reply, current) = try await run(arguments)
            try page(try makeResult(reply: reply, command: current))
        }
    }

    /// Writes each record as a hash named by its key column, with the other included fields as the
    /// hash's fields. Redis has no transaction across the file, so an import that stops part way leaves
    /// the hashes already written; writes are never repeated after a connection fails.
    static func importHashes(plan: DataImportPlan, profile: ConnectionProfile, database: String, timeoutSeconds: Int,
                             eventLoopGroup: EventLoopGroup, progress: @escaping @Sendable (DataTransferProgress) -> Void) async throws -> DataTransferResult {
        guard !profile.isReadOnly else { throw DatabaseServiceError.readOnlyViolation }
        guard let keyColumn = plan.keyColumn, !keyColumn.isEmpty else { throw DataTransferError.invalidMapping }
        let fields = plan.mappings.filter { !$0.targetName.isEmpty }
        guard !fields.isEmpty, Set(fields.map(\.targetName)).count == fields.count else { throw DataTransferError.invalidMapping }
        let prefix = Data(plan.tableName.utf8)
        let reader = try DataImportRecordReader(url: plan.source.url, format: plan.source.format,
                                                hasHeader: plan.source.hasHeader, nullToken: plan.source.nullToken)
        var completed = 0, record = 0
        var batch: [RedisCommand] = []
        // On a cluster each hash goes to the primary owning its key's slot, one connection per node and batch.
        let slots = profile.usesSSHTunnel ? [] : try await clusterSlotRanges(profile: profile, database: database,
                                                                              timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
        func send() async throws {
            let commands = batch; batch = []
            var groups: [(node: RedisTarget?, commands: [RedisCommand])] = []
            if slots.isEmpty { groups = [(nil, commands)] } else {
                var positions: [String: Int] = [:]
                for command in commands {
                    let slot = keySlot(command.arguments[1])
                    let node = slots.first { $0.slots.contains(slot) }?.node
                    let name = node.map { $0.host + ":" + String($0.port) } ?? ""
                    if let position = positions[name] { groups[position].commands.append(command) }
                    else { positions[name] = groups.count; groups.append((node, [command])) }
                }
            }
            let written = RedisWriteCount()
            do {
                for group in groups {
                    try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup, target: group.node) { connection in
                        for command in group.commands {
                            try Task.checkCancellation()
                            do { _ = try await connection.send(command.arguments) }
                            catch let redirect as RedisRedirect {
                                // The slot moved since the map was read. This node didn't write it, so it goes once to the node named.
                                try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup,
                                                         target: RedisTarget(host: redirect.host, port: redirect.port)) { other in
                                    if redirect.isAsk { _ = try await other.send([Data("ASKING".utf8)]) }
                                    _ = try await other.send(command.arguments)
                                }
                            }
                            written.increment()
                        }
                    }
                }
                completed += written.value
            } catch {
                completed += written.value
                let reason: String
                if case RedisClientError.server = error { reason = error.localizedDescription }
                else if error is RedisRedirect { reason = RedisClientError.clusterRedirect.localizedDescription }
                else if error is CancellationError { reason = L10n.text("Cancelled") }
                else { reason = RedisClientError.writeOutcomeUnknown.localizedDescription }
                throw DataTransferError.partialImport(completed: completed, underlying: reason)
            }
            progress(.init(phase: .importing, completed: completed, total: plan.source.rowCount))
        }
        do {
            while let next = try reader.next() {
                try Task.checkCancellation()
                record += 1
                guard let keyCell = next.fields[keyColumn], !keyCell.isNull else { throw DataTransferError.invalidValue(column: keyColumn, row: record) }
                var arguments = [prefix + RedisBytes.data(of: keyCell)]
                for mapping in fields {
                    // Redis has no NULL: a NULL or missing value leaves the field out.
                    guard let cell = next.fields[mapping.sourceName], !cell.isNull else { continue }
                    let value: Data
                    if mapping.valueType == .automatic || mapping.valueType == .text { value = RedisBytes.data(of: cell) }
                    else {
                        switch try DataTransferCodec.boundValue(cell, type: mapping.valueType, column: mapping.targetName, row: record) {
                        case .null: continue
                        case .string(let text), .decimal(let text): value = Data(text.utf8)
                        case .integer(let number): value = Data(String(number).utf8)
                        case .boolean(let flag): value = Data((flag ? "1" : "0").utf8)
                        }
                    }
                    arguments += [Data(mapping.targetName.utf8), value]
                }
                guard arguments.count > 1 else { continue }
                batch.append(try RedisCommandService.command("HSET", arguments))
                if batch.count >= exportPageSize { try await send() }
            }
            try Task.checkCancellation()
            if !batch.isEmpty { try await send() }
        } catch let error as DataTransferError {
            if case .partialImport = error { throw error }
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error.localizedDescription)
        } catch {
            guard completed > 0 else { throw error }
            throw DataTransferError.partialImport(completed: completed, underlying: error is CancellationError ? L10n.text("Cancelled") : error.localizedDescription)
        }
        return DataTransferResult(rowCount: completed, fileURL: nil)
    }

    /// SCAN on one cluster node sees only that node's keys, so on a cluster the browser walks every primary
    /// in turn. Its cursor is then "node:cursor"; "0" still starts and ends the walk.
    static func scan(profile: ConnectionProfile, database: String, cursor: String, pattern: Data?, type: String?,
                     timeoutSeconds: Int, eventLoopGroup: EventLoopGroup) async throws -> RedisScanPage {
        // A tunnel reaches only its own host, so it scans that node alone.
        let nodes = profile.usesSSHTunnel ? [] : try await clusterPrimaries(profile: profile, database: database,
                                                                             timeoutSeconds: timeoutSeconds, eventLoopGroup: eventLoopGroup)
        var nodeIndex = 0, nodeCursor = cursor
        if !nodes.isEmpty, let colon = cursor.firstIndex(of: ":") {
            nodeIndex = Int(cursor[..<colon]) ?? -1
            nodeCursor = String(cursor[cursor.index(after: colon)...])
        }
        guard nodeIndex >= 0, nodeIndex < max(nodes.count, 1), UInt64(nodeCursor) != nil else { throw RedisClientError.invalidCommand }
        let target = nodes.isEmpty ? nil : nodes[nodeIndex]
        let requestedCursor = nodeCursor
        let reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup, target: target) { connection in
            var arguments = [Data(requestedCursor.utf8), Data("COUNT".utf8), Data("100".utf8)]
            if let pattern { arguments += [Data("MATCH".utf8), pattern] }
            if let type, !type.isEmpty { arguments += [Data("TYPE".utf8), Data(type.utf8)] }
            return try await connection.read("SCAN", arguments)
        }
        let (next, values) = try scanValues(reply)
        var nextCursor = next
        if !nodes.isEmpty {
            if next != "0" { nextCursor = "\(nodeIndex):\(next)" }
            else { nextCursor = nodeIndex + 1 < nodes.count ? "\(nodeIndex + 1):0" : "0" }
        }
        var seen = Set<Data>()
        let keys = try values.map { value -> RedisKey in
            guard let bytes = value.bytes else { throw RedisClientError.malformedReply }
            return RedisKey(bytes: bytes)
        }.filter { seen.insert($0.bytes).inserted }
        return RedisScanPage(keys: Array(keys.prefix(RedisCommandService.maximumRows)), cursor: nextCursor,
                             isTruncated: keys.count > RedisCommandService.maximumRows)
    }

    /// The cluster's primaries in a stable order, or none when the server isn't a cluster node.
    private static func clusterPrimaries(profile: ConnectionProfile, database: String, timeoutSeconds: Int,
                                         eventLoopGroup: EventLoopGroup) async throws -> [RedisTarget] {
        let reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup) { connection -> RedisReply? in
            // A standalone server answers "cluster support disabled".
            do { return try await connection.send([Data("CLUSTER".utf8), Data("SLOTS".utf8)]) }
            catch RedisClientError.server { return nil }
        }
        guard let reply else { return [] }
        return clusterPrimaries(fromSlots: reply, defaultHost: profile.host).map { RedisTarget(host: $0.host, port: $0.port) }
    }

    /// Each slot range and the primary that owns it, or none when the server isn't a cluster node.
    private static func clusterSlotRanges(profile: ConnectionProfile, database: String, timeoutSeconds: Int,
                                          eventLoopGroup: EventLoopGroup) async throws -> [RedisSlotRange] {
        let reply = try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                             eventLoopGroup: eventLoopGroup) { connection -> RedisReply? in
            do { return try await connection.send([Data("CLUSTER".utf8), Data("SLOTS".utf8)]) }
            catch RedisClientError.server { return nil }
        }
        guard let reply else { return [] }
        return (reply.elements ?? []).compactMap { range in
            guard let parts = range.elements, parts.count >= 3, let first = parts[0].integer, let last = parts[1].integer,
                  0 <= first, first <= last, last < 16_384,
                  let primary = clusterPrimaries(fromSlots: .array([range]), defaultHost: profile.host).first else { return nil }
            return RedisSlotRange(slots: Int(first)...Int(last), node: RedisTarget(host: primary.host, port: primary.port))
        }
    }

    /// The cluster slot of a key: CRC16 (XMODEM) of its hash tag, the text in its first non-empty {…}, or of the whole key.
    static func keySlot(_ key: Data) -> Int {
        var hashed = key[...]
        if let open = key.firstIndex(of: 123), let close = key[key.index(after: open)...].firstIndex(of: 125),
           close > key.index(after: open) {
            hashed = key[key.index(after: open)..<close]
        }
        var crc: UInt16 = 0
        for byte in hashed {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return Int(crc) % 16_384
    }

    /// Reads CLUSTER SLOTS: each range's third element is its primary as [host, port, id]. An empty host
    /// means the node answering, which is the connection's own host.
    static func clusterPrimaries(fromSlots reply: RedisReply, defaultHost: String) -> [(host: String, port: Int)] {
        var seen = Set<String>()
        var primaries: [(host: String, port: Int)] = []
        for range in reply.elements ?? [] {
            guard let parts = range.elements, parts.count >= 3, let node = parts[2].elements, node.count >= 2,
                  let port = node[1].integer, (1...65_535).contains(port) else { continue }
            var host = node[0].bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if host.isEmpty || host == "?" { host = defaultHost }
            guard !host.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 || $0 == "/" || $0 == "@" }),
                  seen.insert(host + ":" + String(port)).inserted else { continue }
            primaries.append((host, Int(port)))
        }
        return primaries.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    static func inspect(profile: ConnectionProfile, database: String, key: RedisKey, cursor: String = "0",
                        timeoutSeconds: Int, eventLoopGroup: EventLoopGroup) async throws -> RedisKeyInspection {
        try await followingRedirect(profile: profile) { target, asking in
        try await withConnection(profile: profile, database: database, timeoutSeconds: timeoutSeconds,
                                 eventLoopGroup: eventLoopGroup, target: target) { connection in
            if asking { _ = try await connection.send([Data("ASKING".utf8)]) }
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
    }

    /// Runs an operation, and once more on the node a cluster redirect names. A second redirect, or one
    /// through an SSH tunnel, which reaches only the profile's host, is reported instead of followed.
    private static func followingRedirect<Value: Sendable>(profile: ConnectionProfile,
        _ operation: (RedisTarget?, Bool) async throws -> Value) async throws -> Value {
        do {
            return try await operation(nil, false)
        } catch let redirect as RedisRedirect {
            guard !profile.usesSSHTunnel else { throw RedisClientError.discoveryThroughTunnel }
            do {
                return try await operation(RedisTarget(host: redirect.host, port: redirect.port), redirect.isAsk)
            } catch is RedisRedirect { throw RedisClientError.clusterRedirect }
        }
    }

    /// The primary a Sentinel at the profile's address reports for its master name.
    private static func sentinelPrimary(profile: ConnectionProfile, timeout: Int, eventLoopGroup: EventLoopGroup,
                                        lifetime: RedisSocketLifetime) async throws -> RedisTarget {
        let master = profile.redisSentinelMaster.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = try await openChannel(profile: profile, host: profile.host, port: profile.port, tlsName: profile.host,
                                            timeout: timeout, eventLoopGroup: eventLoopGroup, lifetime: lifetime)
        defer { channel.close(promise: nil) }
        let connection = RedisConnection(channel: channel)
        let query = [Data("SENTINEL".utf8), Data("get-master-addr-by-name".utf8), Data(master.utf8)]
        var reply: RedisReply
        do { reply = try await connection.send(query) }
        catch RedisClientError.server(let code) where code == "NOAUTH" {
            // A Sentinel protected by requirepass takes the connection's own credentials.
            try await authenticate(connection, profile: profile)
            reply = try await connection.send(query)
        }
        guard let parts = reply.elements, parts.count == 2, let hostBytes = parts[0].bytes, let portBytes = parts[1].bytes,
              let host = String(data: hostBytes, encoding: .utf8), let port = Int(String(decoding: portBytes, as: UTF8.self)),
              (1...65_535).contains(port), !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 || $0 == "/" || $0 == "@" }) else {
            throw RedisClientError.sentinelMasterUnknown(master)
        }
        return RedisTarget(host: host, port: port)
    }

    private static func authenticate(_ connection: RedisConnection, profile: ConnectionProfile) async throws {
        guard !profile.password.isEmpty || !profile.username.isEmpty else { return }
        var auth = [Data("AUTH".utf8)]
        if !profile.username.isEmpty { auth.append(Data(profile.username.utf8)) }
        auth.append(Data(profile.password.utf8))
        do {
            let result = try await connection.send(auth)
            guard result.bytes == Data("OK".utf8) else { throw RedisClientError.authenticationFailed }
        } catch RedisClientError.server { throw RedisClientError.authenticationFailed }
    }

    /// TLS for another server keeps full verification: a node named by hostname must present that name; one
    /// named by IP address must present the hostname configured for the connection.
    private static func openChannel(profile: ConnectionProfile, host: String, port: Int, tlsName: String, timeout: Int,
                                    eventLoopGroup: EventLoopGroup, lifetime: RedisSocketLifetime) async throws -> Channel {
        // RESP has no TLS-upgrade negotiation. Prefer TLS must never downgrade after a failed handshake.
        let tls = profile.usesTLS ? try NIOSSLContext(configuration: DatabaseService.tlsConfiguration(for: profile)) : nil
        return try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(Int64(min(timeout, 5))))
            .channelInitializer { channel in
                lifetime.install(channel)
                return channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        let hostname = DatabaseService.isIPAddress(tlsName) ? nil : tlsName
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: hostname))
                        if let verifier = TunnelCertificateNameVerifier.handler(for: profile, hostname: hostname) {
                            try channel.pipeline.syncOperations.addHandler(verifier)
                        }
                    }
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(RedisRESPDecoder()))
                    try channel.pipeline.syncOperations.addHandler(RedisReplyHandler())
                }
            }
            .connect(host: host, port: port).get()
    }

    private static func withConnection<Value: Sendable>(
        profile: ConnectionProfile, database: String, timeoutSeconds: Int, eventLoopGroup: EventLoopGroup,
        lifetime: RedisSocketLifetime = .init(), target: RedisTarget? = nil,
        operation: @escaping @Sendable (RedisConnection) async throws -> Value
    ) async throws -> Value {
        let timeout = max(1, min(timeoutSeconds, 300))
        guard let number = Int32(database.trimmingCharacters(in: .whitespacesAndNewlines)), number >= 0 else { throw RedisClientError.invalidDatabase }
        return try await withQueryTimeout(seconds: timeout, closeConnection: { lifetime.close() }) {
            defer { lifetime.close() }
            if profile.usesTLS, profile.usesSSHTunnel, DatabaseService.isIPAddress(profile.host) {
                throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
            }
            let usesSentinel = !profile.redisSentinelMaster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if (usesSentinel || target != nil), profile.usesSSHTunnel { throw RedisClientError.discoveryThroughTunnel }
            var server = target
            if server == nil, usesSentinel {
                server = try await sentinelPrimary(profile: profile, timeout: timeout, eventLoopGroup: eventLoopGroup, lifetime: RedisSocketLifetime())
            }
            let channel: Channel
            if let server {
                let tlsName = DatabaseService.isIPAddress(server.host) ? profile.host : server.host
                channel = try await openChannel(profile: profile, host: server.host, port: server.port, tlsName: tlsName,
                                                timeout: timeout, eventLoopGroup: eventLoopGroup, lifetime: lifetime)
            } else {
                let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
                channel = try await openChannel(profile: profile, host: endpoint.host, port: endpoint.port, tlsName: endpoint.serverHostname,
                                                timeout: timeout, eventLoopGroup: eventLoopGroup, lifetime: lifetime)
            }
            let connection = RedisConnection(channel: channel)
            try Task.checkCancellation()
            try await authenticate(connection, profile: profile)
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

    /// With `namedStreamFields` off, stream entries keep their raw field list, so every page of an export
    /// has the same columns.
    static func makeResult(reply: RedisReply, command: RedisCommand, namedStreamFields: Bool = true) throws -> QueryResultTable {
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
            let parsed = try entries.map { entry -> (id: RedisReply, fields: [RedisReply]) in
                guard let values = entry.elements, values.count == 2, let fields = values[1].elements,
                      fields.count.isMultiple(of: 2) else { throw RedisClientError.malformedReply }
                return (values[0], fields)
            }
            if namedStreamFields, let names = streamFieldNames(parsed.map(\.fields)) {
                // One column per field; an entry without a field shows NULL there.
                columns = [L10n.text("Entry ID")] + names
                rows = parsed.map { entry in
                    var cells = [QueryCell](repeating: .null, count: names.count)
                    for index in stride(from: 0, to: entry.fields.count, by: 2) {
                        if let name = entry.fields[index].bytes.flatMap({ String(data: $0, encoding: .utf8) }),
                           let column = names.firstIndex(of: name) { cells[column] = entry.fields[index + 1].cell }
                    }
                    return [entry.id.cell] + cells
                }
            } else {
                columns = [L10n.text("Entry ID"), L10n.text("Fields")]
                rows = parsed.map { [$0.id.cell, RedisReply.array($0.fields).cell] }
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

    /// Stream field names in order of first appearance, when every name is text, none repeats within an
    /// entry, and there are few enough for columns; otherwise each entry keeps its raw field list.
    static func streamFieldNames(_ entries: [[RedisReply]], limit: Int = 64) -> [String]? {
        var names: [String] = []
        var known = Set<String>([L10n.text("Entry ID")])
        for fields in entries {
            var seen = Set<String>()
            for index in stride(from: 0, to: fields.count, by: 2) {
                guard let bytes = fields[index].bytes, let name = String(data: bytes, encoding: .utf8), !name.isEmpty,
                      seen.insert(name).inserted else { return nil }
                if !names.contains(name) {
                    guard known.insert(name).inserted, names.count < limit else { return nil }
                    names.append(name)
                }
            }
        }
        return names.isEmpty ? nil : names
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
