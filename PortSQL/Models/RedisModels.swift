import Foundation

enum RedisClientError: LocalizedError, Sendable {
    case invalidCommand, unsupportedCommand, invalidDatabase, malformedReply, replyTooLarge, connectionClosed
    case server(String), authenticationFailed, unsupportedKeyType, keyChanged, writeOutcomeUnknown, clusterRedirect

    var errorDescription: String? {
        switch self {
        case .invalidCommand: L10n.text("Enter one Redis command with valid arguments. Use quotes and \\xNN escapes for binary bytes.")
        case .unsupportedCommand: L10n.text("This Redis command is unavailable. Use bounded data commands; administration, scripts, subscriptions and blocking operations are disabled.")
        case .invalidDatabase: L10n.text("Enter a Redis database number from 0 to 2147483647.")
        case .malformedReply: L10n.text("Redis returned an invalid or unsupported RESP2 reply.")
        case .replyTooLarge: L10n.text("The Redis reply exceeds the client limit. Use a smaller range or a SCAN cursor.")
        case .connectionClosed: L10n.text("The Redis connection closed before the reply arrived.")
        case .server(let code): L10n.format("Redis rejected the command (%@). Check its arguments and your account permissions.", code)
        case .authenticationFailed: L10n.text("Redis authentication failed. Check the username and password in the connection.")
        case .unsupportedKeyType: L10n.text("This Redis key type cannot be inspected here.")
        case .keyChanged: L10n.text("The Redis key changed or expired during inspection. Refresh its value.")
        case .writeOutcomeUnknown: L10n.text("The connection ended before Redis confirmed the write. Refresh the key before trying again.")
        case .clusterRedirect: L10n.text("This Redis Cluster endpoint redirected the command. Connect through a cluster-aware proxy or to the node that owns this key.")
        }
    }
}

struct RedisCommand: Hashable, Sendable {
    let arguments: [Data]
    let name: String
    let isReadOnly: Bool
    var preview: String { arguments.map(RedisCommandService.quote).joined(separator: " ") }
}

indirect enum RedisReply: Hashable, Sendable {
    case simple(Data), error(Data), integer(Int64), bulk(Data?), array([RedisReply]?)

    var bytes: Data? {
        switch self {
        case .simple(let value): value
        case .bulk(let value): value
        default: nil
        }
    }

    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var elements: [RedisReply]? { if case .array(let value) = self { value } else { nil } }

    var cell: QueryCell {
        switch self {
        case .simple(let value), .error(let value): RedisBytes.cell(value)
        case .integer(let value): .integer(String(value))
        case .bulk(let value): value.map(RedisBytes.cell) ?? .null
        case .array(let values): values.map { .json(Self.json(.array($0))) } ?? .null
        }
    }

    // Explicit wrappers retain binary bytes, RESP integers and nulls in nested replies.
    static func json(_ reply: RedisReply) -> String {
        switch reply {
        case .simple(let value), .bulk(.some(let value)): RedisBytes.json(value)
        case .error(let value): "{\"error\":" + RedisBytes.json(value) + "}"
        case .integer(let value): String(value)
        case .bulk(nil), .array(nil): "null"
        case .array(.some(let values)): "[" + values.map(Self.json).joined(separator: ",") + "]"
        }
    }
}

enum RedisBytes {
    static func cell(_ bytes: Data) -> QueryCell {
        guard let text = String(data: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) else { return .binary(bytes) }
        return .text(text)
    }

    static func display(_ bytes: Data) -> String {
        if case .text(let value) = cell(bytes) { return value.isEmpty ? L10n.text("Empty string") : value }
        return "0x" + bytes.prefix(256).map { String(format: "%02x", $0) }.joined() + (bytes.count > 256 ? "…" : "")
    }

    static func json(_ bytes: Data) -> String {
        if let string = String(data: bytes, encoding: .utf8) {
            return String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
        }
        return "{\"$binary\":\"" + bytes.base64EncodedString() + "\"}"
    }
}

struct RedisKey: Identifiable, Hashable, Sendable {
    let bytes: Data
    var id: Data { bytes }
    var displayName: String { RedisBytes.display(bytes) }
}

struct RedisScanPage: Sendable {
    let keys: [RedisKey]
    let cursor: String
    let isTruncated: Bool
}

struct RedisKeyInspection: Sendable {
    let key: RedisKey
    let type: String
    let ttlMilliseconds: Int64
    let length: Int64?
    let result: QueryResultTable
    let nextCursor: String?

    var ttlDescription: String {
        if ttlMilliseconds == -2 { return L10n.text("Key no longer exists") }
        if ttlMilliseconds == -1 { return L10n.text("No expiration") }
        return L10n.format("%@ ms remaining", String(ttlMilliseconds))
    }
}

struct RedisCommandHelp: Identifiable {
    let name: String
    let syntax: String
    let summary: String
    var id: String { syntax }
}
