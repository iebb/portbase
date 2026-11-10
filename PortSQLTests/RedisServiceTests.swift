import XCTest
import NIOCore
@testable import PortSQL

final class RedisServiceTests: XCTestCase {
    func testCommandByteRoundTripAndSafetyBoundary() throws {
        let key = Data([0, 32, 34, 39, 92, 10, 255])
        let command = try RedisCommandService.command("SET", [key, Data(), Data("KEEPTTL".utf8)])
        XCTAssertEqual(try RedisCommandService.parse(command.preview).arguments, command.arguments)
        XCTAssertFalse(command.isReadOnly)
        XCTAssertEqual(try RedisCommandService.parse(#"GET "\x00\xff""#).arguments[1], Data([0, 255]))
        XCTAssertTrue(try RedisCommandService.parse("SCAN 0 MATCH * COUNT 100 TYPE hash").isReadOnly)
        XCTAssertFalse(try RedisCommandService.parse("XADD events * event value").isReadOnly)
        for query in ["EVAL return 1 0", "FLUSHALL", "CONFIG GET *", "KEYS *", "SUBSCRIBE a", "BLPOP a 1", "AUTH password",
                      "GET a\nDEL b", "LRANGE a 0 -1", "XRANGE a - +", "SCAN 0 COUNT 999999999999", "SET a b EX 1 KEEPTTL"] {
            XCTAssertThrowsError(try RedisCommandService.parse(query), query)
        }
        XCTAssertTrue(try XCTUnwrap(RedisCommandService.assessment(for: "SET a b", readOnly: false)).requiresConfirmation)
        XCTAssertTrue(try XCTUnwrap(RedisCommandService.assessment(for: "SET a b", readOnly: true)).blocksExecution)
        XCTAssertTrue(try XCTUnwrap(RedisCommandService.assessment(for: "MODULE LIST", readOnly: false)).blocksExecution)
    }

    func testFragmentedRESPPreservesBinaryNullAndIntegerAndBoundsInput() throws {
        var parser = RedisRESPParser()
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        var wire = Data("*5\r\n$3\r\n".utf8)
        wire += Data([0, 255, 10])
        wire += Data("\r\n$0\r\n\r\n$-1\r\n:9223372036854775807\r\n*2\r\n+OK\r\n*-1\r\n".utf8)
        var replies: [RedisReply] = []
        for byte in wire {
            buffer.writeInteger(byte)
            if let reply = try parser.next(from: &buffer) { replies.append(reply) }
        }
        XCTAssertEqual(replies, [.array([
            .bulk(Data([0, 255, 10])), .bulk(Data()), .bulk(nil), .integer(Int64.max),
            .array([.simple(Data("OK".utf8)), .array(nil)])
        ])])
        XCTAssertEqual(replies.first?.elements?[0].cell, .binary(Data([0, 255, 10])))
        XCTAssertEqual(replies.first?.elements?[1].cell, .text(""))
        XCTAssertEqual(replies.first?.elements?[2].cell, .null)
        for input in ["$33554433\r\n", "*100001\r\n", "$-2\r\n", ":9223372036854775808\r\n", "+bad\n"] {
            var invalidParser = RedisRESPParser()
            var invalid = ByteBufferAllocator().buffer(capacity: input.utf8.count)
            invalid.writeString(input)
            XCTAssertThrowsError(try invalidParser.next(from: &invalid), input)
        }
    }

    func testLiveTypedBrowserAndConfirmedWrites() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["PORTBASE_TEST_REDIS_PORT"] ?? "") else { throw XCTSkip("Set the isolated Redis fixture port.") }
        let profile = ConnectionProfile(name: "Redis fixture", engine: .redis, host: "127.0.0.1", port: port,
            username: "", password: environment["PORTBASE_TEST_REDIS_PASSWORD"] ?? "", database: "0", usesTLS: false)
        let prefix = "portbase_test_" + UUID().uuidString + ":"
        let types = ["string", "hash", "list", "set", "zset", "stream"]
        let keys = types.map { RedisKey(bytes: Data((prefix + $0).utf8) + Data([0, 255])) }
        let service = DatabaseService.shared
        func run(_ name: String, _ arguments: [Data], policy: DatabaseExecutionPolicy = .userQuery(confirmed: true)) async throws -> QueryResultTable {
            let command = try RedisCommandService.command(name, arguments)
            return try await service.execute(query: command.preview, profile: profile, database: "0", policy: policy, timeoutSeconds: 10)
        }
        do {
            _ = try await run("SET", [keys[0].bytes, Data([0, 255, 10])])
            _ = try await run("HSET", [keys[1].bytes, Data([255]), Data()])
            _ = try await run("RPUSH", [keys[2].bytes, Data("one".utf8), Data("two".utf8)])
            _ = try await run("SADD", [keys[3].bytes, Data([255])])
            _ = try await run("ZADD", [keys[4].bytes, Data("1.25".utf8), Data([255])])
            _ = try await run("XADD", [keys[5].bytes, Data("*".utf8), Data("field".utf8), Data([255])])
            _ = try await run("PEXPIRE", [keys[0].bytes, Data("60000".utf8)])
            var cursor = "0"
            var discovered = Set<Data>()
            repeat {
                let page = try await service.scanRedisKeys(profile: profile, database: "0", cursor: cursor,
                    pattern: Data((prefix + "*").utf8), type: nil, policy: .readOnly, timeoutSeconds: 10)
                discovered.formUnion(page.keys.map(\.bytes)); cursor = page.cursor
            } while cursor != "0"
            XCTAssertTrue(Set(keys.map(\.bytes)).isSubset(of: discovered))
            for (index, key) in keys.enumerated() {
                let inspection = try await service.inspectRedisKey(profile: profile, database: "0", key: key, policy: .readOnly, timeoutSeconds: 10)
                XCTAssertEqual(inspection.type, types[index])
                XCTAssertFalse(inspection.result.rows.isEmpty)
                if index == 0 {
                    XCTAssertEqual(inspection.result.rows.first?.cells.first, .binary(Data([0, 255, 10])))
                    XCTAssertGreaterThan(inspection.ttlMilliseconds, 0)
                }
                if index == 1 { XCTAssertEqual(inspection.result.rows.first?.cells, [.binary(Data([255])), .text("")]) }
                if index == 4 { XCTAssertEqual(inspection.result.rows.first?.cells.last, .decimal("1.25")) }
            }
            let rejectedPolicies: [DatabaseExecutionPolicy] = [.readOnly, .userQuery(confirmed: false), .mutation(expectedAffectedRows: 1)]
            for policy in rejectedPolicies {
                do {
                    _ = try await run("SET", [keys[0].bytes, Data("changed".utf8)], policy: policy)
                    XCTFail("The execution policy must reject this Redis write")
                } catch { }
            }
            let unchanged = try await run("GET", [keys[0].bytes], policy: .readOnly)
            XCTAssertEqual(unchanged.rows.first?.cells.first, .binary(Data([0, 255, 10])))
            _ = try await run("UNLINK", keys.map(\.bytes))
        } catch {
            _ = try? await run("UNLINK", keys.map(\.bytes))
            throw error
        }
    }

    func testTLSPrivateCAIdentityAndPreferTLSFailClosed() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["PORTBASE_TEST_REDIS_TLS_PORT"] ?? ""),
              let encoded = environment["PORTBASE_TEST_REDIS_CA_B64"], let data = Data(base64Encoded: encoded),
              let certificate = String(data: data, encoding: .utf8) else { throw XCTSkip("Set the isolated TLS Redis fixture and CA.") }
        var profile = ConnectionProfile(name: "TLS Redis fixture", engine: .redis, host: "localhost", port: port,
            username: "", password: environment["PORTBASE_TEST_REDIS_PASSWORD"] ?? "", database: "0")
        profile.transportSecurityMode = .privateCA
        profile.privateCACertificate = certificate
        let result = try await DatabaseService.shared.execute(query: "PING", profile: profile, database: "0", policy: .readOnly, timeoutSeconds: 5)
        XCTAssertEqual(result.rows.first?.cells.first, .text("PONG"))
        for (host, mode) in [("127.0.0.1", TransportSecurityMode.privateCA), ("localhost", .systemCA), ("localhost", .preferTLS)] {
            profile.host = host; profile.transportSecurityMode = mode
            do {
                _ = try await DatabaseService.shared.execute(query: "PING", profile: profile, database: "0", policy: .readOnly, timeoutSeconds: 5)
                XCTFail("The invalid Redis TLS identity/trust must fail closed")
            } catch { }
        }
    }

    func testWholeKeyCommandsPointToTheirCursorCommand() {
        for (query, alternative) in [("HGETALL h", "HSCAN"), ("KEYS *", "SCAN"), ("SMEMBERS s", "SSCAN"), ("hvals h", "HSCAN")] {
            XCTAssertThrowsError(try RedisCommandService.parse(query), query) { error in
                guard case RedisClientError.unboundedCommand(_, let suggested) = error else { return XCTFail("\(query): \(error)") }
                XCTAssertEqual(suggested, alternative)
                XCTAssertTrue(error.localizedDescription.contains(alternative))
            }
        }
    }

    func testStreamEntriesShowOneColumnPerField() throws {
        func bulk(_ text: String) -> RedisReply { .bulk(Data(text.utf8)) }
        let reply = RedisReply.array([
            .array([bulk("1-0"), .array([bulk("event"), bulk("signup"), bulk("plan"), bulk("pro")])]),
            .array([bulk("2-0"), .array([bulk("event"), bulk("login")])]),
        ])
        let command = try RedisCommandService.parse("XRANGE events - + COUNT 10")
        let result = try RedisDatabaseClient.makeResult(reply: reply, command: command)
        XCTAssertEqual(result.columns.map(\.name), [L10n.text("Entry ID"), "event", "plan"])
        XCTAssertEqual(result.rows[0].cells, [.text("1-0"), .text("signup"), .text("pro")])
        XCTAssertEqual(result.rows[1].cells, [.text("2-0"), .text("login"), .null], "A field the entry lacks is NULL, not empty text")

        let repeated = RedisReply.array([.array([bulk("1-0"), .array([bulk("a"), bulk("1"), bulk("a"), bulk("2")])])])
        XCTAssertEqual(try RedisDatabaseClient.makeResult(reply: repeated, command: command).columns.count, 2,
                       "Repeated field names keep the raw field list")
    }

    func testClusterRedirectsAndSlotsNameOnlyUsableNodes() {
        XCTAssertEqual(RedisRedirect.parse(Data("MOVED 3999 10.0.0.5:6381".utf8)), RedisRedirect(isAsk: false, host: "10.0.0.5", port: 6381))
        XCTAssertEqual(RedisRedirect.parse(Data("ASK 12 [fd00::1]:7000".utf8)), RedisRedirect(isAsk: true, host: "fd00::1", port: 7000))
        XCTAssertEqual(RedisRedirect.parse(Data("MOVED 1 fd00::2:7001".utf8))?.host, "fd00::2", "The port follows the last colon")
        for bad in ["MOVED 1 host:0", "MOVED 1 host", "ASK 1 user@host:6379", "MOVED 1 a/b:6379", "ERR something"] {
            XCTAssertNil(RedisRedirect.parse(Data(bad.utf8)), bad)
        }
        func bulk(_ text: String) -> RedisReply { .bulk(Data(text.utf8)) }
        let slots = RedisReply.array([
            .array([.integer(5461), .integer(10922), .array([bulk("10.0.0.2"), .integer(7001), bulk("b")]), .array([bulk("10.0.0.9"), .integer(7009)])]),
            .array([.integer(0), .integer(5460), .array([bulk(""), .integer(7000), bulk("a")])]),
            .array([.integer(10923), .integer(16383), .array([bulk("10.0.0.2"), .integer(7001), bulk("b")])]),
        ])
        let primaries = RedisDatabaseClient.clusterPrimaries(fromSlots: slots, defaultHost: "cluster.example.com")
        XCTAssertEqual(primaries.map { "\($0.host):\($0.port)" }, ["10.0.0.2:7001", "cluster.example.com:7000"],
                       "Each primary once, replicas left out, and an empty host is the connection's own")
    }

    /// Against a local three-node cluster seeded with portbase:cluster:1…60, entered at one node.
    func testLiveClusterScansEveryPrimaryAndFollowsRedirects() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTBASE_TEST_REDIS_CLUSTER_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_REDIS_CLUSTER_PORT to one node of the isolated Redis Cluster fixture.")
        }
        let profile = ConnectionProfile(name: "Cluster fixture", engine: .redis, host: "127.0.0.1", port: port,
                                        username: "", password: "", database: "0", usesTLS: false)
        var keys = Set<Data>()
        var cursor = "0"
        repeat {
            let page = try await DatabaseService.shared.scanRedisKeys(profile: profile, database: "0", cursor: cursor,
                                                                     pattern: Data("portbase:cluster:*".utf8), type: nil, policy: .readOnly)
            keys.formUnion(page.keys.map(\.bytes))
            cursor = page.cursor
        } while cursor != "0"
        XCTAssertEqual(keys.count, 60, "Keys on every primary, not only the node connected to")
        for index in 1...60 {
            let key = "portbase:cluster:\(index)"
            let read = try await DatabaseService.shared.execute(query: "GET \(key)", profile: profile, database: "0", policy: .readOnly)
            XCTAssertEqual(read.rows.first?.cells.first, .text("v"), key)
        }
        _ = try await DatabaseService.shared.execute(query: "SET portbase:cluster:written yes", profile: profile, database: "0",
                                                     policy: .userQuery(confirmed: true))
        let written = try await DatabaseService.shared.execute(query: "GET portbase:cluster:written", profile: profile, database: "0", policy: .readOnly)
        XCTAssertEqual(written.rows.first?.cells.first, .text("yes"), "A write redirected to another node lands there")
        _ = try await DatabaseService.shared.execute(query: "DEL portbase:cluster:written", profile: profile, database: "0",
                                                     policy: .userQuery(confirmed: true))
        let inspected = try await DatabaseService.shared.inspectRedisKey(profile: profile, database: "0",
                                                                          key: RedisKey(bytes: Data("portbase:cluster:7".utf8)), policy: .readOnly)
        XCTAssertEqual(inspected.type, "string")
    }

    /// Against a local Sentinel monitoring a primary named portbase-primary.
    func testLiveSentinelConnectsToTheReportedPrimary() async throws {
        guard let port = Int(ProcessInfo.processInfo.environment["PORTBASE_TEST_REDIS_SENTINEL_PORT"] ?? "") else {
            throw XCTSkip("Set PORTBASE_TEST_REDIS_SENTINEL_PORT to the isolated Sentinel fixture.")
        }
        var profile = ConnectionProfile(name: "Sentinel fixture", engine: .redis, host: "127.0.0.1", port: port,
                                        username: "", password: "", database: "0", usesTLS: false)
        profile.redisSentinelMaster = "portbase-primary"
        let key = "portbase:sentinel:" + UUID().uuidString
        _ = try await DatabaseService.shared.execute(query: "SET \(key) primary", profile: profile, database: "0", policy: .userQuery(confirmed: true))
        let read = try await DatabaseService.shared.execute(query: "GET \(key)", profile: profile, database: "0", policy: .readOnly)
        XCTAssertEqual(read.rows.first?.cells.first, .text("primary"), "Commands reach the primary, not the Sentinel")
        _ = try await DatabaseService.shared.execute(query: "DEL \(key)", profile: profile, database: "0", policy: .userQuery(confirmed: true))
        profile.redisSentinelMaster = "no-such-primary"
        do {
            _ = try await DatabaseService.shared.execute(query: "PING", profile: profile, database: "0", policy: .readOnly)
            XCTFail("An unknown master name must fail")
        } catch RedisClientError.sentinelMasterUnknown(let name) {
            XCTAssertEqual(name, "no-such-primary")
        }
        profile.redisSentinelMaster = "portbase-primary"
        profile.usesSSHTunnel = true
        do {
            _ = try await DatabaseService.shared.execute(query: "PING", profile: profile, database: "0", policy: .readOnly)
            XCTFail("Sentinel discovery can't go through a tunnel")
        } catch RedisClientError.discoveryThroughTunnel { }
    }
}
