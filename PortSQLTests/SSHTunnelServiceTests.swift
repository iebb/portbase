import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
@testable import PortSQL
import XCTest

final class SSHTunnelServiceTests: XCTestCase {
    func testPasswordTunnelForwardsBytes() async throws {
        let service = SSHTunnelService(hostKeyStore: SSHTunnelMemoryHostKeyStore())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let echoServer = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteEchoHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? echoServer.close().wait() }

        let echoPort = try XCTUnwrap(echoServer.localAddress?.port)
        let sshServer = try await makeSSHServer(group: group, authDelegate: TestPasswordDelegate()).get()
        defer { try? sshServer.close().wait() }

        let sshPort = try XCTUnwrap(sshServer.localAddress?.port)
        let profile = ConnectionProfile(
            name: "Tunnel test",
            engine: .mysql,
            host: "127.0.0.1",
            port: echoPort,
            username: "database",
            password: "",
            database: "",
            usesTLS: false,
            usesSSHTunnel: true,
            sshHost: "127.0.0.1",
            sshPort: sshPort,
            sshUsername: "nio",
            sshPassword: "gottagofast"
        )

        let endpoint: SSHTunnelEndpoint
        do {
            endpoint = try await service.endpoint(for: profile, eventLoopGroup: group)
        } catch {
            XCTFail("Opening SSH tunnel endpoint failed: \(error)")
            return
        }

        let response: String
        do {
            response = try await send("portsql-tunnel", toHost: endpoint.host, port: endpoint.port, group: group)
        } catch {
            XCTFail("Sending bytes through SSH tunnel failed: \(error)")
            return
        }

        XCTAssertEqual(response, "portsql-tunnel")
        XCTAssertEqual(endpoint.serverHostname, "127.0.0.1")
    }

    func testPrivateKeyTunnelForwardsBytes() async throws {
        let service = SSHTunnelService(hostKeyStore: SSHTunnelMemoryHostKeyStore())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let echoServer = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteEchoHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? echoServer.close().wait() }

        let clientKey = Curve25519.Signing.PrivateKey()
        let sshPrivateKey = makeOpenSSHEd25519PrivateKey(clientKey)
        let sshServer = try await makeSSHServer(
            group: group,
            authDelegate: TestPublicKeyDelegate(NIOSSHPrivateKey(ed25519Key: clientKey).publicKey)
        ).get()
        defer { try? sshServer.close().wait() }

        let profile = ConnectionProfile(
            name: "Private key tunnel test",
            engine: .postgresql,
            host: "127.0.0.1",
            port: try XCTUnwrap(echoServer.localAddress?.port),
            username: "database",
            password: "",
            database: "",
            usesTLS: false,
            usesSSHTunnel: true,
            sshHost: "127.0.0.1",
            sshPort: try XCTUnwrap(sshServer.localAddress?.port),
            sshUsername: "nio",
            sshPrivateKey: sshPrivateKey
        )

        let endpoint = try await service.endpoint(for: profile, eventLoopGroup: group)
        let response = try await send("portsql-private-key", toHost: endpoint.host, port: endpoint.port, group: group)

        XCTAssertEqual(response, "portsql-private-key")
        XCTAssertEqual(endpoint.serverHostname, "127.0.0.1")
    }

    func testKnownHostMismatchFailsTunnelOpen() async throws {
        let hostKeyStore = SSHTunnelMemoryHostKeyStore()
        let service = SSHTunnelService(hostKeyStore: hostKeyStore)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let echoServer = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ByteEchoHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { try? echoServer.close().wait() }

        let sshServer = try await makeSSHServer(group: group, authDelegate: TestPasswordDelegate()).get()
        defer { try? sshServer.close().wait() }

        let sshPort = try XCTUnwrap(sshServer.localAddress?.port)
        hostKeyStore.setFingerprint("SHA256:not-the-server-key", for: "127.0.0.1:\(sshPort)")

        let profile = ConnectionProfile(
            name: "Known host mismatch test",
            engine: .mysql,
            host: "127.0.0.1",
            port: try XCTUnwrap(echoServer.localAddress?.port),
            username: "database",
            password: "",
            database: "",
            usesTLS: false,
            usesSSHTunnel: true,
            sshHost: "127.0.0.1",
            sshPort: sshPort,
            sshUsername: "nio",
            sshPassword: "gottagofast"
        )

        do {
            _ = try await service.endpoint(for: profile, eventLoopGroup: group)
            XCTFail("Opening a tunnel with a changed SSH host key should fail.")
        } catch SSHTunnelError.hostKeyChanged {
            // Expected.
        } catch {
            XCTFail("Expected hostKeyChanged, got \(error).")
        }
    }

    private func makeSSHServer(
        group: EventLoopGroup,
        authDelegate: NIOSSHServerUserAuthenticationDelegate
    ) -> EventLoopFuture<Channel> {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        return ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(
                            role: .server(.init(
                                hostKeys: [hostKey],
                                userAuthDelegate: authDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: TestSSHForwarder.handle(channel:channelType:)
                        ),
                        TestErrorHandler(),
                    ])
                }
            }
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
    }

    private func send(_ message: String, toHost host: String, port: Int, group: EventLoopGroup) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(TunnelRoundTripHandler(message: message, promise: promise))
            }
            .connect(host: host, port: port)
            .get()

        let response = try await promise.futureResult.get()
        try? await channel.close().get()
        return response
    }
}

private final class SSHTunnelMemoryHostKeyStore: SSHTunnelHostKeyStore, @unchecked Sendable {
    private let lock = NIOLock()
    private var fingerprints: [String: String] = [:]

    func fingerprint(for hostKey: String) -> String? {
        lock.withLock {
            fingerprints[hostKey]
        }
    }

    func setFingerprint(_ fingerprint: String, for hostKey: String) {
        lock.withLock {
            fingerprints[hostKey] = fingerprint
        }
    }
}

private final class TestPasswordDelegate: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "nio", case .password(let passwordRequest) = request.request else {
            responsePromise.succeed(.failure)
            return
        }

        responsePromise.succeed(passwordRequest.password == "gottagofast" ? .success : .failure)
    }
}

private final class TestPublicKeyDelegate: NIOSSHServerUserAuthenticationDelegate {
    private let publicKey: NIOSSHPublicKey

    init(_ publicKey: NIOSSHPublicKey) {
        self.publicKey = publicKey
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "nio", case .publicKey(let keyRequest) = request.request else {
            responsePromise.succeed(.failure)
            return
        }

        responsePromise.succeed(keyRequest.publicKey == publicKey ? .success : .failure)
    }
}

private func makeOpenSSHEd25519PrivateKey(_ key: Curve25519.Signing.PrivateKey) -> String {
    let publicKey = key.publicKey.rawRepresentation
    var publicBlob = Data()
    publicBlob.appendSSHString("ssh-ed25519")
    publicBlob.appendSSHString(publicKey)

    var privateBlock = Data()
    privateBlock.appendUInt32(0x7073_716c)
    privateBlock.appendUInt32(0x7073_716c)
    privateBlock.appendSSHString("ssh-ed25519")
    privateBlock.appendSSHString(publicKey)
    privateBlock.appendSSHString(key.rawRepresentation + publicKey)
    privateBlock.appendSSHString("portsql-test")

    var padding: UInt8 = 1
    while !privateBlock.count.isMultiple(of: 8) {
        privateBlock.append(padding)
        padding += 1
    }

    var payload = Data("openssh-key-v1\0".utf8)
    payload.appendSSHString("none")
    payload.appendSSHString("none")
    payload.appendSSHString(Data())
    payload.appendUInt32(1)
    payload.appendSSHString(publicBlob)
    payload.appendSSHString(privateBlock)

    let base64 = payload.base64EncodedString()
    let wrapped = stride(from: 0, to: base64.count, by: 70).map { offset -> String in
        let start = base64.index(base64.startIndex, offsetBy: offset)
        let end = base64.index(start, offsetBy: min(70, base64.distance(from: start, to: base64.endIndex)))
        return String(base64[start..<end])
    }.joined(separator: "\n")

    return """
    -----BEGIN OPENSSH PRIVATE KEY-----
    \(wrapped)
    -----END OPENSSH PRIVATE KEY-----
    """
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendSSHString(_ value: String) {
        appendSSHString(Data(value.utf8))
    }

    mutating func appendSSHString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }
}

private enum TestSSHForwarder {
    static func handle(channel: Channel, channelType: SSHChannelType) -> EventLoopFuture<Void> {
        switch channelType {
        case .directTCPIP(let target):
            let (sshSide, targetSide) = TestGlueHandler.matchedPair()
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(TestSSHDataCodec())
                try channel.pipeline.syncOperations.addHandler(sshSide)
            }.flatMap {
                ClientBootstrap(group: channel.eventLoop)
                    .connect(host: target.targetHost, port: target.targetPort)
            }.flatMap { targetChannel in
                targetChannel.pipeline.addHandler(targetSide)
            }
        case .forwardedTCPIP, .session:
            return channel.eventLoop.makeFailedFuture(TestTunnelError.invalidChannelType)
        }
    }
}

private final class TestSSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(TestTunnelError.invalidData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

private final class ByteEchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

private final class TunnelRoundTripHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let message: String
    private let promise: EventLoopPromise<String>

    init(message: String, promise: EventLoopPromise<String>) {
        self.message = message
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: message.utf8.count)
        buffer.writeString(message)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        promise.succeed(buffer.readString(length: buffer.readableBytes) ?? "")
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private final class TestErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class TestGlueHandler {
    private var partner: TestGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (TestGlueHandler, TestGlueHandler) {
        let first = TestGlueHandler()
        let second = TestGlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool {
        context?.channel.isWritable ?? false
    }
}

extension TestGlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

private enum TestTunnelError: Error {
    case invalidChannelType
    case invalidData
}
