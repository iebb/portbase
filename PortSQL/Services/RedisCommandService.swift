import Foundation

enum RedisCommandService {
    static let maximumCommandBytes = 1_048_576
    static let maximumRows = 10_000
    static let keyTypes = ["string", "hash", "list", "set", "zset", "stream"]

    private static let reads: Set<String> = [
        "PING", "ECHO", "GET", "MGET", "GETRANGE", "STRLEN", "TYPE", "EXISTS", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME",
        "SCAN", "HSCAN", "SSCAN", "ZSCAN", "HGET", "HMGET", "HEXISTS", "HLEN", "HSTRLEN", "LLEN", "LINDEX", "LRANGE",
        "SCARD", "SISMEMBER", "SMISMEMBER", "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZSCORE", "ZMSCORE", "ZRANK", "ZREVRANK",
        "ZRANGE", "ZREVRANGE", "ZRANGEBYSCORE", "ZREVRANGEBYSCORE", "XLEN", "XRANGE", "XREVRANGE",
        "DBSIZE", "TIME", "INFO", "OBJECT", "MEMORY"
    ]
    private static let writes: Set<String> = [
        "SET", "SETNX", "SETEX", "PSETEX", "MSET", "MSETNX", "GETDEL", "APPEND", "SETRANGE", "INCR", "DECR", "INCRBY", "DECRBY", "INCRBYFLOAT",
        "DEL", "UNLINK", "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT", "PERSIST", "RENAME", "RENAMENX",
        "HSET", "HSETNX", "HDEL", "HINCRBY", "HINCRBYFLOAT", "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "LPOP", "RPOP", "LSET", "LREM", "LTRIM",
        "SADD", "SREM", "SMOVE", "ZADD", "ZREM", "ZINCRBY", "XADD", "XDEL", "XTRIM"
    ]

    static func parse(_ text: String) throws -> RedisCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumCommandBytes else { throw RedisClientError.invalidCommand }
        let bytes = Array(trimmed.utf8)
        var arguments: [Data] = []
        var current: [UInt8] = []
        var quote: UInt8?
        var started = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 92 {
                index += 1
                guard index < bytes.count else { throw RedisClientError.invalidCommand }
                switch bytes[index] {
                case 120:
                    guard index + 2 < bytes.count,
                          let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) else { throw RedisClientError.invalidCommand }
                    current.append(high * 16 + low); index += 2
                case 110: current.append(10)
                case 114: current.append(13)
                case 116: current.append(9)
                case 92, 34, 39, 32: current.append(bytes[index])
                default: throw RedisClientError.invalidCommand
                }
                started = true
            } else if let active = quote {
                if byte == active { quote = nil } else { current.append(byte) }
                started = true
            } else if byte == 34 || byte == 39 {
                quote = byte; started = true
            } else if byte == 10 || byte == 13 {
                throw RedisClientError.invalidCommand
            } else if byte == 32 || byte == 9 {
                if started { arguments.append(Data(current)); current.removeAll(keepingCapacity: true); started = false }
            } else {
                guard byte >= 32 else { throw RedisClientError.invalidCommand }
                current.append(byte); started = true
            }
            guard arguments.count < 4_096 else { throw RedisClientError.invalidCommand }
            index += 1
        }
        guard quote == nil else { throw RedisClientError.invalidCommand }
        if started { arguments.append(Data(current)) }
        return try validate(arguments)
    }

    static func command(_ name: String, _ arguments: [Data] = []) throws -> RedisCommand {
        try validate([Data(name.utf8)] + arguments)
    }

    static func validate(_ arguments: [Data]) throws -> RedisCommand {
        guard !arguments.isEmpty, arguments.count <= 4_096,
              arguments.reduce(0, { $0 + $1.count }) <= maximumCommandBytes,
              let command = String(data: arguments[0], encoding: .ascii), !command.isEmpty else { throw RedisClientError.invalidCommand }
        let name = command.uppercased()
        guard reads.contains(name) || writes.contains(name) else { throw RedisClientError.unsupportedCommand }
        var args = arguments
        args[0] = Data(name.utf8)
        guard args.map(quote).joined(separator: " ").utf8.count <= maximumCommandBytes else { throw RedisClientError.invalidCommand }
        func number(_ index: Int) -> Int64? { args.indices.contains(index) ? String(data: args[index], encoding: .ascii).flatMap(Int64.init) : nil }
        func word(_ index: Int) -> String { args.indices.contains(index) ? (String(data: args[index], encoding: .ascii)?.uppercased() ?? "") : "" }
        func count(_ range: ClosedRange<Int>) throws { guard range.contains(args.count) else { throw RedisClientError.invalidCommand } }
        func boundedRange(_ start: Int, _ end: Int, maximum: Int64 = Int64(maximumRows)) throws {
            guard let first = number(start), let last = number(end), first <= last,
                  (first >= 0 && last >= 0) || (first < 0 && last < 0),
                  last.subtractingReportingOverflow(first).overflow == false,
                  last - first < maximum else { throw RedisClientError.invalidCommand }
        }
        switch name {
        case "PING": try count(1...2)
        case "ECHO", "GET", "STRLEN", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "HLEN", "LLEN", "SCARD", "ZCARD", "XLEN",
             "GETDEL", "INCR", "DECR", "PERSIST": try count(2...2)
        case "DBSIZE", "TIME": try count(1...1)
        case "MGET", "EXISTS", "DEL", "UNLINK": try count(2...4_096)
        case "GETRANGE": try count(4...4); try boundedRange(2, 3, maximum: Int64(maximumCommandBytes))
        case "HGET", "HEXISTS", "HSTRLEN", "SISMEMBER", "ZSCORE", "ZRANK", "ZREVRANK": try count(3...3)
        case "HMGET", "SMISMEMBER", "ZMSCORE": try count(3...4_096)
        case "LINDEX": try count(3...3); guard number(2) != nil else { throw RedisClientError.invalidCommand }
        case "LRANGE": try count(4...4); try boundedRange(2, 3)
        case "SCAN", "HSCAN", "SSCAN", "ZSCAN":
            let cursorIndex = name == "SCAN" ? 1 : 2
            try count((cursorIndex + 1)...(cursorIndex + 7))
            guard let cursor = String(data: args[cursorIndex], encoding: .ascii), UInt64(cursor) != nil else { throw RedisClientError.invalidCommand }
            var seen = Set<String>()
            var index = cursorIndex + 1
            while index < args.count {
                let option = word(index)
                guard index + 1 < args.count, seen.insert(option).inserted else { throw RedisClientError.invalidCommand }
                switch option {
                case "MATCH": break
                case "COUNT": guard let count = number(index + 1), (1...1_000).contains(count) else { throw RedisClientError.invalidCommand }
                case "TYPE": guard name == "SCAN", keyTypes.contains(word(index + 1).lowercased()) else { throw RedisClientError.invalidCommand }
                default: throw RedisClientError.unsupportedCommand
                }
                index += 2
            }
        case "ZCOUNT", "ZLEXCOUNT": try count(4...4)
        case "ZRANGE", "ZREVRANGE":
            try count(4...6); try boundedRange(2, 3)
            let options = args.dropFirst(4).compactMap { String(data: $0, encoding: .ascii)?.uppercased() }
            guard options.count == args.count - 4, Set(options).count == options.count,
                  Set(options).isSubset(of: name == "ZRANGE" ? ["REV", "WITHSCORES"] : ["WITHSCORES"]) else { throw RedisClientError.unsupportedCommand }
        case "ZRANGEBYSCORE", "ZREVRANGEBYSCORE":
            try count(7...8)
            let limit = word(4) == "WITHSCORES" ? 5 : 4
            guard word(limit) == "LIMIT", args.count == limit + 3, let offset = number(limit + 1), offset >= 0,
                  let limitCount = number(limit + 2), (1...Int64(maximumRows)).contains(limitCount) else { throw RedisClientError.invalidCommand }
        case "XRANGE", "XREVRANGE":
            try count(6...6)
            guard word(4) == "COUNT", let limit = number(5), (1...Int64(maximumRows)).contains(limit) else { throw RedisClientError.invalidCommand }
        case "INFO":
            try count(1...2)
            guard args.count == 1 || ["DEFAULT", "SERVER", "CLIENTS", "MEMORY", "PERSISTENCE", "STATS", "REPLICATION", "CPU", "KEYSPACE", "ERRORSTATS"].contains(word(1)) else { throw RedisClientError.unsupportedCommand }
        case "OBJECT":
            try count(3...3)
            guard ["ENCODING", "IDLETIME", "FREQ", "REFCOUNT"].contains(word(1)) else { throw RedisClientError.unsupportedCommand }
        case "MEMORY":
            try count(3...5)
            guard word(1) == "USAGE", args.count == 3 || (args.count == 5 && word(3) == "SAMPLES" && (1...20).contains(number(4) ?? 0)) else { throw RedisClientError.unsupportedCommand }
        case "SET":
            try count(3...8)
            var options = Set<String>(); var index = 3
            while index < args.count {
                let option = word(index)
                guard options.insert(option).inserted else { throw RedisClientError.invalidCommand }
                if ["EX", "PX", "EXAT", "PXAT"].contains(option) {
                    guard let value = number(index + 1), value > 0 else { throw RedisClientError.invalidCommand }
                    index += 2
                } else if ["NX", "XX", "GET", "KEEPTTL"].contains(option) { index += 1 }
                else { throw RedisClientError.unsupportedCommand }
            }
            guard !options.isSuperset(of: ["NX", "XX"]), options.intersection(["EX", "PX", "EXAT", "PXAT", "KEEPTTL"]).count <= 1 else { throw RedisClientError.invalidCommand }
        case "SETNX", "APPEND", "RENAME", "RENAMENX": try count(3...3)
        case "SETEX", "PSETEX": try count(4...4); guard (number(2) ?? 0) > 0 else { throw RedisClientError.invalidCommand }
        case "MSET", "MSETNX": try count(3...4_095); guard args.count.isMultiple(of: 2) == false else { throw RedisClientError.invalidCommand }
        case "SETRANGE": try count(4...4); guard (number(2) ?? -1) >= 0 else { throw RedisClientError.invalidCommand }
        case "INCRBY", "DECRBY": try count(3...3); guard number(2) != nil else { throw RedisClientError.invalidCommand }
        case "INCRBYFLOAT": try count(3...3)
        case "EXPIRE", "PEXPIRE", "EXPIREAT", "PEXPIREAT":
            try count(3...4)
            guard number(2) != nil, args.count == 3 || ["NX", "XX", "GT", "LT"].contains(word(3)) else { throw RedisClientError.invalidCommand }
        case "HSET": try count(4...4_096); guard args.count.isMultiple(of: 2) else { throw RedisClientError.invalidCommand }
        case "HSETNX", "HINCRBY", "HINCRBYFLOAT", "SMOVE", "ZINCRBY": try count(4...4)
        case "HDEL", "LPUSH", "RPUSH", "LPUSHX", "RPUSHX", "SADD", "SREM", "ZREM", "XDEL": try count(3...4_096)
        case "LPOP", "RPOP":
            try count(2...3); guard args.count == 2 || (1...Int64(maximumRows)).contains(number(2) ?? 0) else { throw RedisClientError.invalidCommand }
        case "LSET", "LREM": try count(4...4); guard number(2) != nil else { throw RedisClientError.invalidCommand }
        case "LTRIM": try count(4...4); guard number(2) != nil, number(3) != nil else { throw RedisClientError.invalidCommand }
        case "ZADD":
            try count(4...4_096)
            var index = 2; var options = Set<String>()
            while ["NX", "XX", "GT", "LT", "CH", "INCR"].contains(word(index)) {
                guard options.insert(word(index)).inserted else { throw RedisClientError.invalidCommand }; index += 1
            }
            guard args.count - index >= 2, (args.count - index).isMultiple(of: 2),
                  !options.isSuperset(of: ["NX", "XX"]), !options.isSuperset(of: ["GT", "LT"]),
                  !(options.contains("NX") && !options.intersection(["GT", "LT"]).isEmpty),
                  !options.contains("INCR") || args.count - index == 2 else { throw RedisClientError.invalidCommand }
        case "XADD":
            // The basic form cannot conceal server-side scripts or an unbounded receive loop.
            try count(5...4_095)
            guard args.count.isMultiple(of: 2) == false,
                  word(2) == "*" || String(data: args[2], encoding: .ascii)?.split(separator: "-").count == 2 else { throw RedisClientError.invalidCommand }
        case "XTRIM":
            try count(4...5)
            guard ["MAXLEN", "MINID"].contains(word(2)), args.count == 4 || ["~", "="].contains(word(3)) else { throw RedisClientError.invalidCommand }
        default: throw RedisClientError.unsupportedCommand
        }
        return RedisCommand(arguments: args, name: name, isReadOnly: reads.contains(name))
    }

    static func assessment(for text: String, readOnly: Bool) -> SQLSafetyAssessment? {
        do {
            let command = try parse(text)
            guard !command.isReadOnly else { return nil }
            if readOnly {
                return SQLSafetyAssessment(title: L10n.text("Read-only connection"), message: L10n.text("This connection does not allow Redis writes."),
                                           requiresConfirmation: false, blocksExecution: true)
            }
            return SQLSafetyAssessment(title: L10n.text("Confirm write"),
                message: L10n.text("This Redis command changes data. Review the exact command before running it.") + "\n\n" + command.preview,
                requiresConfirmation: true, blocksExecution: false)
        } catch {
            return SQLSafetyAssessment(title: L10n.text("Redis command"), message: error.localizedDescription,
                                       requiresConfirmation: false, blocksExecution: true)
        }
    }

    static func quote(_ argument: Data) -> String {
        let safe = argument.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [95, 58, 45, 46, 47, 42, 43].contains($0) }
        if !argument.isEmpty, safe { return String(decoding: argument, as: UTF8.self) }
        return "\"" + argument.map { byte -> String in
            switch byte {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 10: return "\\n"
            case 13: return "\\r"
            case 9: return "\\t"
            case 32...126: return String(UnicodeScalar(byte))
            default: return String(format: "\\x%02x", byte)
            }
        }.joined() + "\""
    }

    private static func hex(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: nil
        }
    }

    static var help: [RedisCommandHelp] {
        [
            .init(name: "SCAN", syntax: "SCAN 0 MATCH \"*\" COUNT 100", summary: L10n.text("Browse keys with a cursor.")),
            .init(name: "GET", syntax: "GET \"key\"", summary: L10n.text("Read a string value.")),
            .init(name: "SET", syntax: "SET \"key\" \"value\" KEEPTTL", summary: L10n.text("Write a string and keep its expiration.")),
            .init(name: "TYPE", syntax: "TYPE \"key\"", summary: L10n.text("Inspect the key type.")),
            .init(name: "PTTL", syntax: "PTTL \"key\"", summary: L10n.text("Read remaining expiration in milliseconds.")),
            .init(name: "HSCAN", syntax: "HSCAN \"key\" 0 COUNT 100", summary: L10n.text("Browse hash fields and values.")),
            .init(name: "HSET", syntax: "HSET \"key\" \"field\" \"value\"", summary: L10n.text("Write a hash field.")),
            .init(name: "LRANGE", syntax: "LRANGE \"key\" 0 99", summary: L10n.text("Read a bounded list range.")),
            .init(name: "RPUSH", syntax: "RPUSH \"key\" \"value\"", summary: L10n.text("Append a list item.")),
            .init(name: "SSCAN", syntax: "SSCAN \"key\" 0 COUNT 100", summary: L10n.text("Browse set members.")),
            .init(name: "SADD", syntax: "SADD \"key\" \"member\"", summary: L10n.text("Add a set member.")),
            .init(name: "ZSCAN", syntax: "ZSCAN \"key\" 0 COUNT 100", summary: L10n.text("Browse sorted-set members and scores.")),
            .init(name: "ZADD", syntax: "ZADD \"key\" 1 \"member\"", summary: L10n.text("Write a sorted-set member and score.")),
            .init(name: "XRANGE", syntax: "XRANGE \"key\" - + COUNT 100", summary: L10n.text("Read a bounded stream range.")),
            .init(name: "XADD", syntax: "XADD \"key\" * \"field\" \"value\"", summary: L10n.text("Append a stream entry.")),
            .init(name: "PEXPIRE", syntax: "PEXPIRE \"key\" 60000", summary: L10n.text("Set expiration in milliseconds.")),
            .init(name: "UNLINK", syntax: "UNLINK \"key\"", summary: L10n.text("Delete a key asynchronously."))
        ]
    }
}
