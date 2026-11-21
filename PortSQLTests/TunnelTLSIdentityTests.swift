import NIOCore
import NIOPosix
import NIOSSH
@testable import PortSQL
import XCTest

/// A throwaway authority and a server certificate that names `db.portbase.test` and, as certificates made
/// for testing on one machine often do, the address 127.0.0.1.
private enum TunnelPKI {
    static let caPEM = """
-----BEGIN CERTIFICATE-----
MIIBqDCCAU+gAwIBAgIUbT4wyYbkP5rFRgsF94rcMRkMsqYwCgYIKoZIzj0EAwIw
IjEgMB4GA1UEAwwXUG9ydGJhc2UgVHVubmVsIFRlc3QgQ0EwHhcNMjYxMTIxMTU1
MjUwWhcNNDYxMTE2MTU1MjUwWjAiMSAwHgYDVQQDDBdQb3J0YmFzZSBUdW5uZWwg
VGVzdCBDQTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABFbzPvq191q9nCzrzstN
sIFTOBVOtyRDWxmHxfSSCJJianiDFVfGc7ljRW8+LTKco6VCcnbz7/Vouzg06RoP
/e6jYzBhMB0GA1UdDgQWBBTce3RA3opWB3hhp7dF7jK/7hm7OzAfBgNVHSMEGDAW
gBTce3RA3opWB3hhp7dF7jK/7hm7OzAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB
/wQEAwIBBjAKBggqhkjOPQQDAgNHADBEAiAL6GtdiHoRO9XyVuPzWSJeT+IccjKH
avgXXNOETyq/sAIgJUTDaHNVWMXKea6BPHCGYOm73GJGVaO2J9DLLMaXzdo=
-----END CERTIFICATE-----
"""
    static let leafPEM = """
-----BEGIN CERTIFICATE-----
MIIByzCCAXCgAwIBAgIUOdWdIz4BvtuJrmb/XphuhYoAWgswCgYIKoZIzj0EAwIw
IjEgMB4GA1UEAwwXUG9ydGJhc2UgVHVubmVsIFRlc3QgQ0EwHhcNMjYxMTIxMTU1
MjUwWhcNNDYxMTE2MTU1MjUwWjAdMRswGQYDVQQDDBJwb3J0YmFzZS10dW5uZWwt
ZGIwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATg5TSrMK2jZBSOwU37ne2X3zj0
H1S8Bj04Idlzl/Y3hJYjPDqj3nCaHQ4SMiKmIGSom/bXhJwUtbT7d05foNAoo4GI
MIGFMCEGA1UdEQQaMBiCEGRiLnBvcnRiYXNlLnRlc3SHBH8AAAEwCwYDVR0PBAQD
AgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1UdDgQWBBR0yOvXP/rdqIu4FFyF
+EHIFXyF9TAfBgNVHSMEGDAWgBTce3RA3opWB3hhp7dF7jK/7hm7OzAKBggqhkjO
PQQDAgNJADBGAiEA6STVgnIVr9tCV7HyqFL/9zFSXJphOQQcxdLQsina2LQCIQCY
znexXY3trqNzLmZKzodoppHmnN8emEqn6ASvVO3J/Q==
-----END CERTIFICATE-----
"""
    static let leafKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgY3KWaFaKu1I1BYnf
SmIpdncPxHZvC6JhM9uJuIq1pXmhRANCAATg5TSrMK2jZBSOwU37ne2X3zj0H1S8
Bj04Idlzl/Y3hJYjPDqj3nCaHQ4SMiKmIGSom/bXhJwUtbT7d05foNAo
-----END PRIVATE KEY-----
"""
}

/// Through an SSH tunnel every database is reached at 127.0.0.1, so a certificate naming that address says
/// nothing about which server answered. Only the database's own host name may be accepted, and nothing is
/// sent to a server that doesn't carry it.
final class TunnelTLSIdentityTests: XCTestCase {
    private func sshServer(group: EventLoopGroup) async throws -> Channel {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        return try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], userAuthDelegate: TestPasswordDelegate())),
                                      allocator: channel.allocator,
                                      inboundChildChannelInitializer: TestSSHForwarder.handleOnLoopback(channel:channelType:)),
                        TestErrorHandler(),
                    ])
                }
            }
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private static let engines: [(engine: DatabaseEngine, server: FakeServer.Mode, query: String)] = [
        (.postgresql, .postgres, "SELECT 1"), (.mysql, .mysql, "SELECT 1"), (.mariadb, .mysql, "SELECT 1"), (.redis, .direct, "PING"),
        (.mongodb, .direct, #"{"ping": 1}"#), (.clickhouse, .direct, "SELECT 1"), (.elasticsearch, .direct, #"{"method": "GET", "path": "/"}"#),
    ]

    private func profile(_ engine: DatabaseEngine, host: String, port: Int, ssh: Int, mode: TransportSecurityMode = .privateCA) -> ConnectionProfile {
        ConnectionProfile(name: "Tunnelled", engine: engine, host: host, port: port, username: "user", password: "a password",
                          defaultDatabase: engine == .redis ? "0" : "app", transportSecurityMode: mode, privateCACertificate: TunnelPKI.caPEM,
                          usesSSHTunnel: true, sshHost: "127.0.0.1", sshPort: ssh, sshUsername: "nio", sshPassword: "gottagofast")
    }

    /// What kind of problem a statement ends in, or nil when it doesn't end in one.
    private func issue(_ service: DatabaseService, _ profile: ConnectionProfile, _ query: String) async -> ConnectionIssue.Kind? {
        defer { Task { await SSHTunnelService.shared.close(profileID: profile.id) } }
        do {
            _ = try await service.execute(query: query, profile: profile, timeoutSeconds: 2)
            return nil
        } catch {
            return ConnectionIssue.classify(DatabaseErrorFormatter.message(for: error)).kind
        }
    }

    func testEveryEngineChecksTheHostNameThroughATunnelBeforeSendingAnything() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let ssh = try await sshServer(group: group)
        defer { try? ssh.close().wait() }
        let sshPort = try XCTUnwrap(ssh.localAddress?.port)
        let service = DatabaseService(handshakeTimeoutSeconds: 1)

        for (engine, mode, query) in Self.engines {
            let server = try await FakeServer.start(mode: mode, leafPEM: TunnelPKI.leafPEM, keyPEM: TunnelPKI.leafKeyPEM, caPEM: TunnelPKI.caPEM)
            // Another server behind the same tunnel, holding a certificate from the same authority.
            let other = await issue(service, profile(engine, host: "other.portbase.test", port: server.port, ssh: sshPort), query)
            XCTAssertEqual(other, .certificateHostname, "\(engine)")
            XCTAssertFalse(server.receivedApplicationData, "\(engine) sent something to a server it hadn't identified")

            // The server the certificate names: the handshake is accepted and the conversation starts. This
            // server says nothing back, so it ends as a timeout.
            let named = await issue(service, profile(engine, host: "db.portbase.test", port: server.port, ssh: sshPort), query)
            XCTAssertEqual(named, .timeout, "\(engine)")
            XCTAssertTrue(server.receivedApplicationData, "\(engine)")

            try await server.stop()

            // A server of its own, as the last connection may still be saying goodbye to the first.
            let stranger = try await FakeServer.start(mode: mode, leafPEM: TunnelPKI.leafPEM, keyPEM: TunnelPKI.leafKeyPEM, caPEM: TunnelPKI.caPEM)
            let untrusted = await issue(service, profile(engine, host: "db.portbase.test", port: stranger.port, ssh: sshPort, mode: .systemCA), query)
            XCTAssertEqual(untrusted, .certificateUntrusted, "\(engine)")
            XCTAssertFalse(stranger.receivedApplicationData, "\(engine)")
            try await stranger.stop()
        }
    }

    /// A tunnelled PostgreSQL connection asks for TLS itself. Only the server's own answer that it has none
    /// lets Prefer TLS go on without it, and a required TLS never does.
    func testTunnelledPostgresFallsBackOnlyWhenTheServerHasNoTLS() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let ssh = try await sshServer(group: group)
        defer { try? ssh.close().wait() }
        let sshPort = try XCTUnwrap(ssh.localAddress?.port)
        let service = DatabaseService(handshakeTimeoutSeconds: 1)

        let plain = try await FakeServer.start(mode: .postgresWithoutTLS, leafPEM: TunnelPKI.leafPEM, keyPEM: TunnelPKI.leafKeyPEM, caPEM: TunnelPKI.caPEM)
        let required = await issue(service, profile(.postgresql, host: "db.portbase.test", port: plain.port, ssh: sshPort), "SELECT 1")
        XCTAssertEqual(required, .tlsUnavailable)
        XCTAssertFalse(plain.receivedApplicationData)
        // Going on in plaintext, this silent server is then waited on until the timeout.
        let preferred = await issue(service, profile(.postgresql, host: "db.portbase.test", port: plain.port, ssh: sshPort, mode: .preferTLS), "SELECT 1")
        XCTAssertEqual(preferred, .timeout)
        XCTAssertTrue(plain.receivedApplicationData)
        try await plain.stop()

        let secure = try await FakeServer.start(mode: .postgres, leafPEM: TunnelPKI.leafPEM, keyPEM: TunnelPKI.leafKeyPEM, caPEM: TunnelPKI.caPEM)
        let untrusted = await issue(service, profile(.postgresql, host: "db.portbase.test", port: secure.port, ssh: sshPort, mode: .preferTLS), "SELECT 1")
        XCTAssertEqual(untrusted, .certificateUntrusted, "A certificate that can't be verified is never a reason to go without TLS")
        XCTAssertFalse(secure.receivedApplicationData)
        try await secure.stop()
    }
}
