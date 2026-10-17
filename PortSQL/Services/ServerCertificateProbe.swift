import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Security

/// The certificate authority a server presented, offered for trust on first use.
///
/// Managed databases (DigitalOcean, Amazon RDS, Azure, Aiven, and others) sign server certificates
/// with their own CA. Instead of failing until a CA file is imported by hand, Portbase shows this
/// authority's identity and, only after explicit confirmation, stores it as the connection's
/// private CA. Every later connection still verifies the full chain and the hostname against it,
/// and a different CA fails again rather than being accepted silently.
struct ServerCertificateAuthority: Equatable, Identifiable, Sendable {
    var id: String { sha256Fingerprint }
    /// The CA certificate in PEM form, as stored in the Keychain on confirmation.
    let pem: String
    let commonName: String
    /// Colon-separated uppercase SHA-256 of the CA certificate's DER bytes.
    let sha256Fingerprint: String
    let notValidAfter: Date
    /// The hostname the server was reached as, which its certificate must name.
    let hostname: String
    /// Whether the server certificate names `hostname`; trusting the CA can't fix a name mismatch.
    let coversHostname: Bool
}

enum ServerCertificateProbeError: LocalizedError, Equatable {
    case tlsUnavailable
    case noCertificate
    case incompleteChain
    case outsideValidity(Date)
    case unsupportedEngine
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .tlsUnavailable:
            L10n.text("The server doesn’t offer TLS, so there’s no certificate to review.")
        case .noCertificate:
            L10n.text("The server didn’t present a certificate.")
        case .incompleteChain:
            L10n.text("The server didn’t send its certificate authority. Import the CA certificate from your database provider instead.")
        case .outsideValidity(let date):
            L10n.format("The server’s certificate isn’t valid now (it expires or expired on %@). Renew it on the server, or check this device’s date and time.",
                        date.formatted(date: .abbreviated, time: .omitted))
        case .unsupportedEngine:
            L10n.text("This connection type doesn’t use server certificates.")
        case .timedOut:
            L10n.text("The server didn’t complete the TLS handshake in time.")
        case .server(let message):
            message
        }
    }
}

enum ServerCertificateProbe {
    /// How a connection reaches TLS: directly, or after the protocol's plaintext upgrade request.
    enum Preamble: Equatable, Sendable {
        case none, postgres, mysql
    }

    static func preamble(for engine: DatabaseEngine) -> Preamble? {
        switch engine {
        case .postgresql: .postgres
        case .mysql, .mariadb: .mysql
        case .clickhouse, .elasticsearch, .mongodb, .redis: Preamble.none
        case .sqlite: nil
        }
    }

    /// Fetches the authority behind `profile`'s server certificate through the same endpoint, including
    /// an SSH tunnel, that a real connection uses. The handshake is aborted before any credentials are sent.
    static func authority(for profile: ConnectionProfile, now: Date = .now) async throws -> ServerCertificateAuthority {
        guard let preamble = preamble(for: profile.engine), profile.usesTLS else { throw ServerCertificateProbeError.unsupportedEngine }
        let group = MultiThreadedEventLoopGroup.singleton
        let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: group)
        let hostname = endpoint.serverHostname
        let chain = try await presentedChain(host: endpoint.host, port: endpoint.port,
                                             serverHostname: DatabaseService.isIPAddress(hostname) ? nil : hostname,
                                             preamble: preamble, group: group)
        return try authority(from: chain, hostname: hostname, now: now)
    }

    /// Picks the trust anchor from a presented chain (leaf first) and describes it.
    static func authority(from chain: [NIOSSLCertificate], hostname: String, now: Date = .now) throws -> ServerCertificateAuthority {
        guard let leaf = chain.first, let anchor = chain.last else { throw ServerCertificateProbeError.noCertificate }
        let anchorDER = Data(try anchor.toDERBytes())
        guard let anchorCertificate = SecCertificateCreateWithData(nil, anchorDER as CFData) else {
            throw ServerCertificateProbeError.noCertificate
        }
        // Only a self-issued certificate can be a trust anchor; a chain that stops at an intermediate
        // can't be completed from what the server sent.
        guard isSelfIssued(anchorCertificate) else { throw ServerCertificateProbeError.incompleteChain }
        for certificate in chain {
            let notBefore = Date(timeIntervalSince1970: TimeInterval(certificate.notValidBefore))
            let notAfter = Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter))
            guard notBefore <= now, now <= notAfter else { throw ServerCertificateProbeError.outsideValidity(notAfter) }
        }
        let digest = SHA256.hash(data: anchorDER)
        return ServerCertificateAuthority(
            pem: pem(fromDER: anchorDER),
            commonName: (SecCertificateCopySubjectSummary(anchorCertificate) as String?) ?? L10n.text("Unnamed authority"),
            sha256Fingerprint: digest.map { String(format: "%02X", $0) }.joined(separator: ":"),
            notValidAfter: Date(timeIntervalSince1970: TimeInterval(anchor.notValidAfter)),
            hostname: hostname,
            coversHostname: names(leaf, hostname)
        )
    }

    static func pem(fromDER der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
    }

    private static func isSelfIssued(_ certificate: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?,
              let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data? else { return false }
        return issuer == subject
    }

    /// Whether the leaf's subject alternative names cover `hostname`, with single-label wildcards.
    /// A certificate without alternative names is left for the real connection to judge.
    static func names(_ leaf: NIOSSLCertificate, _ hostname: String) -> Bool {
        let host = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        var sawName = false
        for name in leaf._subjectAlternativeNames() {
            switch name.nameType {
            case .dnsName:
                sawName = true
                let pattern = String(decoding: name.contents, as: UTF8.self).lowercased()
                if pattern == host { return true }
                if pattern.hasPrefix("*."), let dot = host.firstIndex(of: "."),
                   host[host.index(after: dot)...] == pattern.dropFirst(2), !host[..<dot].isEmpty {
                    return true
                }
            case .ipAddress:
                sawName = true
                if let address = ipAddressString(Array(name.contents)), address == host { return true }
            default:
                continue
            }
        }
        return !sawName
    }

    private static func ipAddressString(_ bytes: [UInt8]) -> String? {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer).lowercased()
    }

    /// Connects, performs the protocol's TLS upgrade if any, and records the certificates the server
    /// presents. Verification is always failed in the callback, so the handshake never completes.
    static func presentedChain(host: String, port: Int, serverHostname: String?, preamble: Preamble,
                               group: EventLoopGroup, timeout: TimeAmount = .seconds(15)) async throws -> [NIOSSLCertificate] {
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        let captured = NIOLockedValueBox<[NIOSSLCertificate]>([])
        let readyFuture = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)
        // The upgrade handler is installed before the connection opens, so a server that speaks first
        // (MySQL's greeting) can't send bytes before anything is listening.
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                // Deadlines are left to fire even after success: completing a promise twice is a no-op,
                // and this guarantees every promise is completed on every path.
                let ready = channel.eventLoop.makePromise(of: Void.self)
                channel.eventLoop.scheduleTask(in: timeout) { ready.fail(ServerCertificateProbeError.timedOut) }
                readyFuture.withLockedValue { $0 = ready.futureResult }
                guard preamble != .none else {
                    ready.succeed(())
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TLSUpgradeRequestHandler(preamble: preamble, ready: ready),
                                                                   name: TLSUpgradeRequestHandler.name)
                }
            }
            .connect(host: host, port: port)
            .get()
        defer { channel.close(promise: nil) }
        let loop = channel.eventLoop
        guard let ready = readyFuture.withLockedValue({ $0 }) else { throw ServerCertificateProbeError.noCertificate }
        try await ready.get()

        let finished = loop.makePromise(of: Void.self)
        loop.scheduleTask(in: timeout) { finished.fail(ServerCertificateProbeError.timedOut) }
        try await loop.submit {
            if preamble != .none {
                _ = channel.pipeline.removeHandler(name: TLSUpgradeRequestHandler.name)
            }
            let tls = try NIOSSLClientHandler(context: context, serverHostname: serverHostname) {
                (certificates: [NIOSSLCertificate], verification: EventLoopPromise<NIOSSLVerificationResult>) in
                captured.withLockedValue { $0 = certificates }
                verification.succeed(NIOSSLVerificationResult.failed)
            }
            try channel.pipeline.syncOperations.addHandler(tls, position: .first)
            try channel.pipeline.syncOperations.addHandler(HandshakeEndHandler(finished: finished))
        }.get()
        do {
            try await finished.futureResult.get()
        } catch ServerCertificateProbeError.timedOut {
            if captured.withLockedValue({ $0.isEmpty }) { throw ServerCertificateProbeError.timedOut }
        } catch {
            // The deliberate verification failure ends the handshake with an error; the chain is what matters.
        }
        let chain = captured.withLockedValue { $0 }
        guard !chain.isEmpty else { throw ServerCertificateProbeError.noCertificate }
        return chain
    }
}

/// Sends PostgreSQL's SSLRequest, or answers MySQL's greeting with an SSL request packet, then
/// reports that the server is ready for a TLS handshake.
private final class TLSUpgradeRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    static let name = "Portbase.TLSUpgradeRequest"

    private let preamble: ServerCertificateProbe.Preamble
    private let ready: EventLoopPromise<Void>
    private var buffer = ByteBuffer()
    private var done = false

    init(preamble: ServerCertificateProbe.Preamble, ready: EventLoopPromise<Void>) {
        self.preamble = preamble
        self.ready = ready
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard preamble == .postgres, context.channel.isActive else { return }
        sendPostgresRequest(context: context)
    }

    func channelActive(context: ChannelHandlerContext) {
        if preamble == .postgres { sendPostgresRequest(context: context) }
        context.fireChannelActive()
    }

    private var sentPostgresRequest = false
    private func sendPostgresRequest(context: ChannelHandlerContext) {
        guard !sentPostgresRequest else { return }
        sentPostgresRequest = true
        var request = context.channel.allocator.buffer(capacity: 8)
        request.writeInteger(Int32(8))
        request.writeInteger(Int32(80_877_103))
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        switch preamble {
        case .postgres:
            guard let reply = buffer.readInteger(as: UInt8.self) else { return }
            finish(reply == UInt8(ascii: "S") ? nil : .tlsUnavailable)
        case .mysql:
            handleMySQLGreeting(context: context)
        case .none:
            finish(nil)
        }
    }

    private func handleMySQLGreeting(context: ChannelHandlerContext) {
        guard buffer.readableBytes >= 4, let header = buffer.getBytes(at: buffer.readerIndex, length: 4) else { return }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
        guard buffer.readableBytes >= 4 + length, let payload = buffer.getBytes(at: buffer.readerIndex + 4, length: length) else { return }
        if payload.first == 0xFF {
            // An error packet: code (2 bytes), optional SQL state marker and state, then the message.
            let start = payload.count > 3 && payload[3] == UInt8(ascii: "#") ? 9 : 3
            let message = payload.count > start ? String(decoding: payload[start...], as: UTF8.self) : ""
            finish(.server(message.isEmpty ? L10n.text("The server refused the connection.") : message))
            return
        }
        // Protocol version, null-terminated server version, connection id, 8 bytes of salt, a filler,
        // then the lower two bytes of the capability flags.
        guard let versionEnd = payload.dropFirst().firstIndex(of: 0) else { finish(.tlsUnavailable); return }
        let capabilityIndex = versionEnd + 1 + 4 + 8 + 1
        guard payload.count >= capabilityIndex + 2 else { finish(.tlsUnavailable); return }
        let capabilities = UInt16(payload[capabilityIndex]) | UInt16(payload[capabilityIndex + 1]) << 8
        guard capabilities & 0x0800 != 0 else { finish(.tlsUnavailable); return }

        // SSLRequest: capabilities, max packet size, charset, and 23 reserved bytes, as sequence 1.
        let flags: UInt32 = 0x0000_0001 | 0x0000_0004 | 0x0000_0200 | 0x0000_0800 | 0x0000_2000 | 0x0000_8000 | 0x0008_0000
        var request = context.channel.allocator.buffer(capacity: 36)
        request.writeBytes([32, 0, 0, 1])
        request.writeInteger(flags, endianness: .little)
        request.writeInteger(UInt32(16_777_216), endianness: .little)
        request.writeInteger(UInt8(45))
        request.writeRepeatingByte(0, count: 23)
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
        finish(nil)
    }

    private func finish(_ error: ServerCertificateProbeError?) {
        guard !done else { return }
        done = true
        if let error { ready.fail(error) } else { ready.succeed(()) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; ready.fail(error) }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { finish(.tlsUnavailable) }
        context.fireChannelInactive()
    }
}

/// Completes when the handshake ends. Verification always fails, so it ends with an error or a close.
private final class HandshakeEndHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let finished: EventLoopPromise<Void>

    init(finished: EventLoopPromise<Void>) { self.finished = finished }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finished.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finished.succeed(())
        context.fireChannelInactive()
    }
}
