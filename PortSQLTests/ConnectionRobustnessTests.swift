import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@testable import PortSQL
import XCTest

final class ConnectionRobustnessTests: XCTestCase {
    private struct StillWaiting: Error {}

    /// A server that takes the connection and then says nothing, as a dead tunnel, a filtered port or the
    /// wrong kind of server does.
    private func silentServer(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    /// The error an operation ends with, or `StillWaiting` when it hasn't ended in time. The operation isn't
    /// waited for past that, so one that never ends fails its test instead of stopping the run.
    private func outcome(within seconds: Int, of operation: @escaping @Sendable () async throws -> Void) async -> Error? {
        let result = NIOLockedValueBox<Result<Void, Error>?>(nil)
        let work = Task { do { try await operation(); result.withLockedValue { $0 = .success(()) } } catch { result.withLockedValue { $0 = .failure(error) } } }
        defer { work.cancel() }
        for _ in 0..<(seconds * 20) {
            if let done = result.withLockedValue({ $0 }) {
                if case .failure(let error) = done { return error }
                return nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return StillWaiting()
    }

    func testAServerThatNeverAnswersEndsInAnErrorOnEveryEngine() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try await silentServer(group: group)
        defer { try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)

        let queries: [(DatabaseEngine, String)] = [
            (.mysql, "SELECT 1"), (.mariadb, "SELECT 1"), (.postgresql, "SELECT 1"), (.redis, "PING"),
            (.mongodb, #"{"ping": 1}"#), (.clickhouse, "SELECT 1"), (.elasticsearch, #"{"method": "GET", "path": "/"}"#),
        ]
        let service = DatabaseService(handshakeTimeoutSeconds: 1)
        for (engine, query) in queries {
            let profile = ConnectionProfile(name: "Silent", engine: engine, host: "127.0.0.1", port: port, username: "user",
                                            password: "", database: engine == .redis ? "0" : "app", usesTLS: false)
            let error = await outcome(within: 8) {
                _ = try await service.execute(query: query, profile: profile, timeoutSeconds: 2)
            }
            let expected: DatabaseServiceError = engine.supportsConsoleTransactions ? .connectionTimedOut : .queryTimedOut
            XCTAssertEqual(error.map(DatabaseErrorFormatter.message), expected.errorDescription, "\(engine)")
            XCTAssertEqual(error.map { ConnectionIssue.classify(DatabaseErrorFormatter.message(for: $0)).kind }, .timeout, "\(engine)")
            guard engine.supportsConsoleTransactions else { continue }
            // The sidebar's schema and database list, and a console's own connection, open the same way.
            let schema = await outcome(within: 8) { _ = try await service.loadSchema(profile: profile) }
            XCTAssertEqual(schema as? DatabaseServiceError, .connectionTimedOut, "\(engine) schema")
            let databases = await outcome(within: 8) { _ = try await service.listDatabases(profile: profile) }
            XCTAssertEqual(databases as? DatabaseServiceError, .connectionTimedOut, "\(engine) databases")
            let console = await outcome(within: 8) {
                _ = try await service.execute(query: query, profile: profile, timeoutSeconds: 2, sessionID: UUID())
            }
            XCTAssertEqual(console as? DatabaseServiceError, .connectionTimedOut, "\(engine) console")
        }
    }

    /// Stopping a PostgreSQL query that is still connecting ends it at once rather than at the timeout.
    func testCancellingAPostgresConnectEndsIt() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try await silentServer(group: group)
        defer { try? server.close().wait() }
        let profile = ConnectionProfile(name: "Silent", engine: .postgresql, host: "127.0.0.1", port: try XCTUnwrap(server.localAddress?.port),
                                        username: "user", password: "", database: "app", usesTLS: false)
        let service = DatabaseService(handshakeTimeoutSeconds: 60)
        let work = Task { try await service.execute(query: "SELECT 1", profile: profile, timeoutSeconds: 60) }
        try await Task.sleep(for: .milliseconds(300))
        work.cancel()
        let ended = await outcome(within: 5) { _ = try await work.value }
        XCTAssertTrue(ended is CancellationError, "\(String(describing: ended))")
    }

    /// The PostgreSQL socket is opened by the app and handed to the driver, so its TLS rules are checked here:
    /// the certificate is verified against the name or address typed, and nothing falls back to plaintext.
    func testPostgresTLSVerifiesTheServerAndNeverDowngrades() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let port = Int(environment["PORTSQL_TEST_POSTGRES_TLS_PORT"] ?? ""),
              let ca = Data(base64Encoded: environment["PORTSQL_TEST_POSTGRES_CA_B64"] ?? "").flatMap({ String(data: $0, encoding: .utf8) }),
              let otherCA = Data(base64Encoded: environment["PORTSQL_TEST_POSTGRES_OTHER_CA_B64"] ?? "").flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw XCTSkip("Set PORTSQL_TEST_POSTGRES_TLS_PORT, _CA_B64 and _OTHER_CA_B64 to the isolated PostgreSQL TLS fixture, whose certificate names localhost only.")
        }
        func profile(host: String, mode: TransportSecurityMode, ca: String = "") -> ConnectionProfile {
            ConnectionProfile(name: "Disposable TLS fixture", engine: .postgresql, host: host, port: port, username: "test_username",
                              password: "test_password", defaultDatabase: "test_database", transportSecurityMode: mode, privateCACertificate: ca)
        }
        let service = DatabaseService()
        func usesTLS(_ profile: ConnectionProfile) async throws -> String? {
            let sql = "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
            return try await service.execute(query: sql, profile: profile, policy: .readOnly).rows.first?.cells.first?.displayValue
        }
        func issue(_ profile: ConnectionProfile) async -> ConnectionIssue.Kind? {
            do { _ = try await usesTLS(profile); return nil }
            catch { return ConnectionIssue.classify(DatabaseErrorFormatter.message(for: error)).kind }
        }

        let byName = try await usesTLS(profile(host: "localhost", mode: .privateCA, ca: ca))
        XCTAssertEqual(byName, "true")
        let plaintext = try await usesTLS(profile(host: "localhost", mode: .plaintext))
        XCTAssertEqual(plaintext, "false")

        let untrusted = await issue(profile(host: "localhost", mode: .systemCA))
        XCTAssertEqual(untrusted, .certificateUntrusted)
        let preferredUntrusted = await issue(profile(host: "localhost", mode: .preferTLS))
        XCTAssertEqual(preferredUntrusted, .certificateUntrusted, "Prefer TLS fails on a certificate it can't verify rather than falling back")
        let wrongCA = await issue(profile(host: "localhost", mode: .privateCA, ca: otherCA))
        XCTAssertEqual(wrongCA, .certificateUntrusted)
        // The same server by a name, and by an address, its certificate doesn't carry.
        let wrongName = await issue(profile(host: "portbase.localhost", mode: .privateCA, ca: ca))
        XCTAssertEqual(wrongName, .certificateHostname)
        let byAddress = await issue(profile(host: "127.0.0.1", mode: .privateCA, ca: ca))
        XCTAssertEqual(byAddress, .certificateHostname)
        let databases = try await service.listDatabases(profile: profile(host: "localhost", mode: .privateCA, ca: ca))
        XCTAssertTrue(databases.contains("test_database"))
    }

    /// A console whose connection went away while it sat unused, as after the server's idle limit or a
    /// laptop's sleep, opens another for the next statement instead of failing it.
    func testAnIdleConsoleReconnectsAfterItsConnectionIsDropped() async throws {
        var exercised = false
        for engine in [DatabaseEngine.mysql, .mariadb, .postgresql] {
            let key = engine == .mariadb ? "PORTBASE_TEST_MARIADB_PORT" : engine == .mysql ? "PORTSQL_TEST_MYSQL_PORT" : "PORTSQL_TEST_POSTGRES_PORT"
            guard let raw = ProcessInfo.processInfo.environment[key], let port = Int(raw) else { continue }
            exercised = true
            let profile = ConnectionProfile(name: "Disposable console fixture", engine: engine, host: "127.0.0.1", port: port,
                username: "test_username", password: "test_password", defaultDatabase: "test_database", transportSecurityMode: .plaintext)
            // Checked after any pause at all, and only after a long one, as the app does.
            for service in [DatabaseService(consoleIdleCheckSeconds: 0), DatabaseService(consoleIdleCheckSeconds: 3_600)] {
                let session = UUID()
                func connection(manualCommit: Bool = false) async throws -> String {
                    let result = try await service.execute(query: engine == .postgresql ? "SELECT pg_backend_pid()" : "SELECT CONNECTION_ID()",
                                                           profile: profile, sessionID: session, manualCommit: manualCommit)
                    return try XCTUnwrap(result.rows.first?.cells.first?.displayValue)
                }
                /// Ends a connection from another one, and waits for its socket to close.
                func drop(_ connection: String) async throws {
                    _ = try await service.execute(query: engine == .postgresql ? "SELECT pg_terminate_backend(\(connection))" : "KILL \(connection)",
                                                  profile: profile, policy: .userQuery(confirmed: true))
                    try await Task.sleep(for: .milliseconds(300))
                }
                do {
                    let first = try await connection()
                    let again = try await connection()
                    XCTAssertEqual(first, again, "\(engine): a live connection is kept")
                    try await drop(first)
                    let second = try await connection()
                    XCTAssertNotEqual(first, second, "\(engine)")

                    // Work in an open transaction went with the connection, and that is never papered over.
                    let inTransaction = try await connection(manualCommit: true)
                    let open = await service.consoleHasTransaction(session)
                    XCTAssertTrue(open)
                    try await drop(inTransaction)
                    let lost = await outcome(within: 5) { _ = try await connection(manualCommit: true) }
                    XCTAssertEqual(lost as? ConsoleSessionError, .connectionLost, "\(engine)")
                    let stillOpen = await service.consoleHasTransaction(session)
                    XCTAssertFalse(stillOpen)

                    // Committing what was lost fails; rolling it back has nothing left to do.
                    for commit in [true, false] {
                        let pending = try await connection(manualCommit: true)
                        try await drop(pending)
                        let finished = await outcome(within: 5) { try await service.finishConsoleTransaction(session, commit: commit) }
                        XCTAssertEqual(finished as? ConsoleSessionError, commit ? .connectionLost : nil, "\(engine) commit \(commit)")
                        let open = await service.consoleHasTransaction(session)
                        XCTAssertFalse(open)
                    }
                    await service.closeConsole(session)
                } catch { await service.closeConsole(session); throw error }
            }
        }
        if !exercised { throw XCTSkip("Local relational fixtures are not configured") }
    }

    func testLongLivedConnectionsAreProbedWhileIdle() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try await silentServer(group: group)
        defer { try? server.close().wait() }
        let channel = try await ClientBootstrap(group: group).probingIdleConnections()
            .connect(host: "127.0.0.1", port: try XCTUnwrap(server.localAddress?.port)).get()
        defer { channel.close(promise: nil) }
        let enabled = try await channel.getOption(ChannelOptions.socketOption(.so_keepalive)).get()
        XCTAssertNotEqual(enabled, 0)
        let idle = try await channel.getOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPALIVE))).get()
        XCTAssertEqual(idle, 30)
        let interval = try await channel.getOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPINTVL))).get()
        XCTAssertEqual(interval, 10)
        let count = try await channel.getOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPCNT))).get()
        XCTAssertEqual(count, 3)
    }
}
