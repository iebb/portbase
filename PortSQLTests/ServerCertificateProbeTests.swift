import NIOCore
import NIOPosix
import NIOSSL
import XCTest
@testable import PortSQL

/// Test-only certificates: a throwaway "project CA" and a server certificate it signed for
/// localhost, 127.0.0.1, and *.db.example.test. The key below belongs to that test certificate and
/// is used only by the local fake servers in these tests.
private enum TestPKI {
    static let caPEM = """
-----BEGIN CERTIFICATE-----
MIIBrDCCAVGgAwIBAgIUFSuw44Phx3PgWxthKiWAdVGe+V0wCgYIKoZIzj0EAwIw
IzEhMB8GA1UEAwwYUG9ydGJhc2UgVGVzdCBQcm9qZWN0IENBMB4XDTI2MTAxNzAy
NDA1NloXDTQ2MTAxMjAyNDA1NlowIzEhMB8GA1UEAwwYUG9ydGJhc2UgVGVzdCBQ
cm9qZWN0IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE+DHxI85XQ4gtg6rd
3oB2vz3mr7x3gDgtGax03Rd5HWZ06FsZ9XlRfnrYuXEfiJG4nc9u0+bPTpJ6MyoN
31Db8KNjMGEwHQYDVR0OBBYEFHct/P1oeMjNMEfKsvp7HlVOXVZTMB8GA1UdIwQY
MBaAFHct/P1oeMjNMEfKsvp7HlVOXVZTMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P
AQH/BAQDAgEGMAoGCCqGSM49BAMCA0kAMEYCIQDOk8B9DATsSb6O0V5AS3tpxgee
bgH91gYxTmcHJhLG8AIhALEsC5n0XJb7RLmylGYP12lCgP30hs6NvlAJKAfKvCpr
-----END CERTIFICATE-----
"""
    static let leafPEM = """
-----BEGIN CERTIFICATE-----
MIIB0zCCAXmgAwIBAgIUFitaw3fl46123XGafnOUWTuj/ewwCgYIKoZIzj0EAwIw
IzEhMB8GA1UEAwwYUG9ydGJhc2UgVGVzdCBQcm9qZWN0IENBMB4XDTI2MTAxNzAy
NDA1NloXDTQ1MTIxNjAyNDA1NlowGzEZMBcGA1UEAwwQcG9ydGJhc2UtdGVzdC1k
YjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABHFPeEQB4bykJrtFNy63gpZ5icZF
zqwsob5ydHDTLnjvTCVRx0f1+atz5cZwB6RY/Pq4UFbRzBYpaHusPh89tnCjgZIw
gY8wLQYDVR0RBCYwJIIJbG9jYWxob3N0ghEqLmRiLmV4YW1wbGUudGVzdIcEfwAA
ATAJBgNVHRMEAjAAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1UdDgQWBBQVmIK/
2IYQ32mKruAt7tC3UQiFtjAfBgNVHSMEGDAWgBR3Lfz9aHjIzTBHyrL6ex5VTl1W
UzAKBggqhkjOPQQDAgNIADBFAiEA835h49sbjmna4A91uBhoajhdVD2K1gMJ0sp/
+f0rpzUCIBYwDCzwh7a5ACZ9/K5BNJTADWbtzysfIbQLZsNnIXmr
-----END CERTIFICATE-----
"""
    static let leafKeyPEM = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgY8tk04BAmDEWJ0Xe
kRQzkBnzLj24wGTEbyg0iOUb28ihRANCAARxT3hEAeG8pCa7RTcut4KWeYnGRc6s
LKG+cnRw0y5470wlUcdH9fmrc+XGcAekWPz6uFBW0cwWKWh7rD4fPbZw
-----END PRIVATE KEY-----
"""
    static let caFingerprint = "6C:34:0E:39:98:99:2F:1C:B2:25:C1:7C:5A:BF:D9:16:F3:88:9B:61:8A:AD:4C:AB:EC:B5:92:1E:77:90:8F:10"
}

final class ServerCertificateProbeTests: XCTestCase {
    private func chain() throws -> [NIOSSLCertificate] {
        [try NIOSSLCertificate(bytes: Array(TestPKI.leafPEM.utf8), format: .pem),
         try NIOSSLCertificate(bytes: Array(TestPKI.caPEM.utf8), format: .pem)]
    }

    func testAuthorityIsTheSelfIssuedCAWithItsFingerprintAndHostCoverage() throws {
        let authority = try ServerCertificateProbe.authority(from: chain(), hostname: "localhost")
        XCTAssertEqual(authority.commonName, "Portbase Test Project CA")
        XCTAssertEqual(authority.sha256Fingerprint, TestPKI.caFingerprint)
        XCTAssertTrue(authority.coversHostname)
        XCTAssertTrue(TransportSecurityEditorState.isValidPrivateCACertificate(authority.pem), "The saved PEM is a valid private CA")
        let roundTrip = try NIOSSLCertificate.fromPEMBytes(Array(authority.pem.utf8))
        XCTAssertEqual(try roundTrip.first?.toDERBytes(), try chain().last?.toDERBytes())

        let leaf = try chain()[0]
        for host in ["localhost", "127.0.0.1", "eu.db.example.test", "EU.DB.EXAMPLE.TEST"] {
            XCTAssertTrue(ServerCertificateProbe.names(leaf, host), host)
        }
        for host in ["db.example.test", "a.b.db.example.test", "example.com", "127.0.0.2"] {
            XCTAssertFalse(ServerCertificateProbe.names(leaf, host), "A wildcard covers one label only: \(host)")
        }
        XCTAssertFalse(try ServerCertificateProbe.authority(from: chain(), hostname: "example.com").coversHostname)
    }

    func testIncompleteAndExpiredChainsAreNotOffered() throws {
        XCTAssertThrowsError(try ServerCertificateProbe.authority(from: [chain()[0]], hostname: "localhost")) { error in
            XCTAssertEqual(error as? ServerCertificateProbeError, .incompleteChain, "A chain that stops below its CA can't be trusted")
        }
        let future = Date(timeIntervalSince1970: 4_102_444_800) // 2100
        XCTAssertThrowsError(try ServerCertificateProbe.authority(from: chain(), hostname: "localhost", now: future)) { error in
            guard case .outsideValidity = error as? ServerCertificateProbeError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ServerCertificateProbe.authority(from: [], hostname: "localhost"))
    }

    @MainActor
    func testTrustIsOfferedOnlyForUntrustedCertificatesOnTLSConnections() {
        var profile = ConnectionProfile(name: "Managed", engine: .mysql, host: "db.example.test", port: 25060,
                                        username: "app", password: "", defaultDatabase: "")
        let untrusted = "NIOSSLError.handshakeFailed(BoringSSLError.sslError([error:1000007d:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED]))"
        XCTAssertTrue(WorkspaceViewModel.offersCertificateTrust(for: untrusted, profile: profile))
        XCTAssertFalse(WorkspaceViewModel.offersCertificateTrust(for: "Certificate hostname mismatch", profile: profile))
        XCTAssertFalse(WorkspaceViewModel.offersCertificateTrust(for: "Access denied for user 'app'", profile: profile))
        profile.transportSecurityMode = .privateCA
        XCTAssertTrue(WorkspaceViewModel.offersCertificateTrust(for: DatabaseServiceError.privateCACertificateMissing.localizedDescription, profile: profile),
                      "A private CA that didn't sync to this device can be trusted again")
        profile.transportSecurityMode = .plaintext
        XCTAssertFalse(WorkspaceViewModel.offersCertificateTrust(for: untrusted, profile: profile))
        profile.transportSecurityMode = .systemCA
        profile.engine = .sqlite
        XCTAssertFalse(WorkspaceViewModel.offersCertificateTrust(for: untrusted, profile: profile))
    }

    func testProbeReadsTheChainThroughEachTLSUpgrade() async throws {
        for mode in [FakeServer.Mode.direct, .postgres, .mysql] {
            let server = try await FakeServer.start(mode: mode)
            do {
                let preamble: ServerCertificateProbe.Preamble = mode == .postgres ? .postgres : mode == .mysql ? .mysql : .none
                let presented = try await ServerCertificateProbe.presentedChain(host: "127.0.0.1", port: server.port, serverHostname: "localhost",
                                                                                preamble: preamble, group: MultiThreadedEventLoopGroup.singleton,
                                                                                timeout: .seconds(5))
                XCTAssertEqual(presented.count, 2, "\(mode)")
                XCTAssertEqual(try ServerCertificateProbe.authority(from: presented, hostname: "localhost").sha256Fingerprint, TestPKI.caFingerprint)
                XCTAssertFalse(server.receivedApplicationData, "No credentials or queries are sent: \(mode)")
            } catch {
                XCTFail("\(mode): \(error)")
            }
            try await server.stop()
        }
    }

    func testServersWithoutTLSAreReported() async throws {
        for mode in [FakeServer.Mode.postgresWithoutTLS, .mysqlWithoutTLS] {
            let server = try await FakeServer.start(mode: mode)
            let preamble: ServerCertificateProbe.Preamble = mode == .postgresWithoutTLS ? .postgres : .mysql
            do {
                _ = try await ServerCertificateProbe.presentedChain(host: "127.0.0.1", port: server.port, serverHostname: "localhost",
                                                                    preamble: preamble, group: MultiThreadedEventLoopGroup.singleton,
                                                                    timeout: .seconds(5))
                XCTFail("\(mode) has no certificate")
            } catch {
                XCTAssertEqual(error as? ServerCertificateProbeError, .tlsUnavailable, "\(mode)")
            }
            try await server.stop()
        }
    }
}

/// A loopback server that answers the PostgreSQL or MySQL TLS upgrade, or speaks TLS directly.
private final class FakeServer: @unchecked Sendable {
    enum Mode: Sendable { case direct, postgres, mysql, postgresWithoutTLS, mysqlWithoutTLS }

    let channel: Channel
    let port: Int
    private let state: NIOLockedValueBoxFlag

    private init(channel: Channel, state: NIOLockedValueBoxFlag) {
        self.channel = channel
        self.port = channel.localAddress?.port ?? 0
        self.state = state
    }

    var receivedApplicationData: Bool { state.value }

    static func start(mode: Mode) async throws -> FakeServer {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(TestPKI.leafPEM.utf8), format: .pem)),
                               .certificate(try NIOSSLCertificate(bytes: Array(TestPKI.caPEM.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(TestPKI.leafKeyPEM.utf8), format: .pem)))
        configuration.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: configuration)
        let state = NIOLockedValueBoxFlag()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    if mode == .direct {
                        try child.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                        try child.pipeline.syncOperations.addHandler(ApplicationDataWatcher(state: state))
                    } else {
                        try child.pipeline.syncOperations.addHandler(UpgradeResponder(mode: mode, context: context, state: state))
                    }
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return FakeServer(channel: channel, state: state)
    }

    func stop() async throws { try await channel.close() }
}

private final class NIOLockedValueBoxFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class ApplicationDataWatcher: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let state: NIOLockedValueBoxFlag
    init(state: NIOLockedValueBoxFlag) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { state.set() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class UpgradeResponder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let mode: FakeServer.Mode
    let context: NIOSSLContext
    let state: NIOLockedValueBoxFlag
    private var buffer = ByteBuffer()

    init(mode: FakeServer.Mode, context: NIOSSLContext, state: NIOLockedValueBoxFlag) {
        self.mode = mode
        self.context = context
        self.state = state
    }

    func channelActive(context: ChannelHandlerContext) {
        guard mode == .mysql || mode == .mysqlWithoutTLS else { return }
        // Protocol 10, a version string, connection id, salt, filler, and capability flags.
        let capabilities: UInt16 = mode == .mysql ? 0xFFFF : 0xFFFF & ~0x0800
        var payload: [UInt8] = [10] + Array("8.0.36-test".utf8) + [0] + [1, 0, 0, 0] + Array(repeating: 0x61, count: 8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8(capabilities >> 8), 45, 2, 0, 0xFF, 0xC7, 21] + Array(repeating: 0, count: 10)
        payload += Array(repeating: 0x62, count: 12) + [0] + Array("caching_sha2_password".utf8) + [0]
        var packet = context.channel.allocator.buffer(capacity: payload.count + 4)
        packet.writeBytes([UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF), 0, 0])
        packet.writeBytes(payload)
        context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        switch mode {
        case .postgres, .postgresWithoutTLS:
            guard buffer.readableBytes >= 8 else { return }
            var reply = context.channel.allocator.buffer(capacity: 1)
            reply.writeInteger(UInt8(ascii: mode == .postgres ? "S" : "N"))
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            if mode == .postgres { startTLS(context: context) }
        case .mysql:
            guard buffer.readableBytes >= 36 else { return }
            let sequence = buffer.getInteger(at: buffer.readerIndex + 3, as: UInt8.self)
            let flags = buffer.getInteger(at: buffer.readerIndex + 4, endianness: .little, as: UInt32.self) ?? 0
            guard sequence == 1, flags & 0x0800 != 0 else { context.close(promise: nil); return }
            startTLS(context: context)
        default:
            break
        }
    }

    private func startTLS(context: ChannelHandlerContext) {
        let pipeline = context.pipeline
        let tls = NIOSSLServerHandler(context: self.context)
        let watcher = ApplicationDataWatcher(state: state)
        try? pipeline.syncOperations.addHandler(tls, position: .first)
        try? pipeline.syncOperations.addHandler(watcher)
        pipeline.removeHandler(self, promise: nil)
    }
}
