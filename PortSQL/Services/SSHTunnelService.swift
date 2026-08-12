import Foundation
import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

struct SSHTunnelEndpoint: Sendable {
    let host: String
    let port: Int
    let serverHostname: String
}

enum SSHTunnelError: LocalizedError {
    case missingSSHHost
    case missingSSHUsername
    case missingSSHCredential
    case missingOriginatorAddress
    case missingLocalPort
    case sshConnectionClosed
    case invalidChannelType
    case invalidData
    case invalidPrivateKey
    case encryptedPrivateKeyUnsupported
    case privateKeyAuthenticationNotSupported
    case passwordAuthenticationNotSupported
    case authenticationTimedOut
    case hostKeyChanged(host: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .missingSSHHost:
            "Enter an SSH host before connecting through a tunnel."
        case .missingSSHUsername:
            "Enter an SSH username before connecting through a tunnel."
        case .missingSSHCredential:
            "Enter an SSH password or private key before connecting through a tunnel."
        case .missingOriginatorAddress:
            "The local tunnel connection did not provide an originator address."
        case .missingLocalPort:
            "The SSH tunnel did not expose a local forwarding port."
        case .sshConnectionClosed:
            "The SSH connection closed before authentication completed."
        case .invalidChannelType:
            "The SSH server did not open a direct TCP forwarding channel."
        case .invalidData:
            "The SSH tunnel received unexpected channel data."
        case .invalidPrivateKey:
            "The SSH private key could not be read. Use an unencrypted OpenSSH Ed25519 or ECDSA private key."
        case .encryptedPrivateKeyUnsupported:
            "Encrypted SSH private keys are not supported yet. Remove the key passphrase or use SSH password login."
        case .privateKeyAuthenticationNotSupported:
            "The SSH server does not support private-key authentication for this account."
        case .passwordAuthenticationNotSupported:
            "The SSH server does not support password authentication for this account."
        case .authenticationTimedOut:
            "SSH authentication timed out. Check the tunnel host, credentials, and network connection."
        case .hostKeyChanged(let host, let expected, let actual):
            "The SSH host key for \(host) changed. Expected \(expected), received \(actual)."
        }
    }
}

protocol SSHTunnelHostKeyStore: Sendable {
    func fingerprint(for hostKey: String) -> String?
    func setFingerprint(_ fingerprint: String, for hostKey: String)
}

actor SSHTunnelService {
    static let shared = SSHTunnelService()

    private var tunnels: [TunnelKey: Tunnel] = [:]
    private var openings: [TunnelKey: TunnelOpening] = [:]
    private var profileGenerations: [UUID: Int] = [:]
    private let hostKeyStore: SSHTunnelHostKeyStore

    init(hostKeyStore: SSHTunnelHostKeyStore = SSHTunnelUserDefaultsHostKeyStore()) {
        self.hostKeyStore = hostKeyStore
    }

    func endpoint(for profile: ConnectionProfile, eventLoopGroup: EventLoopGroup) async throws -> SSHTunnelEndpoint {
        guard profile.usesSSHTunnel else {
            return SSHTunnelEndpoint(host: profile.host, port: profile.port, serverHostname: profile.host)
        }

        let key = try TunnelKey(profile: profile)
        if let tunnel = tunnels[key], tunnel.isActive {
            return tunnel.endpoint
        }
        if let opening = openings[key] {
            let tunnel = try await opening.task.value
            return try await adopt(tunnel, for: key, opening: opening)
        }

        let generation = (profileGenerations[key.profileID] ?? 0) + 1
        profileGenerations[key.profileID] = generation
        let replacedKeys = tunnels.keys.filter { $0.profileID == key.profileID }
        for replacedKey in replacedKeys {
            if let staleTunnel = tunnels.removeValue(forKey: replacedKey) {
                await staleTunnel.close()
            }
        }
        let replacedOpenings = openings.keys.filter { $0.profileID == key.profileID }
        for replacedKey in replacedOpenings {
            openings.removeValue(forKey: replacedKey)?.task.cancel()
        }

        let openingID = UUID()
        let task = Task { try await self.openTunnel(for: profile, key: key, eventLoopGroup: eventLoopGroup) }
        let opening = TunnelOpening(id: openingID, generation: generation, task: task)
        openings[key] = opening
        do {
            let tunnel = try await task.value
            return try await adopt(tunnel, for: key, opening: opening)
        } catch {
            if openings[key]?.id == openingID {
                openings.removeValue(forKey: key)
            }
            throw error
        }
    }

    private func adopt(_ tunnel: Tunnel, for key: TunnelKey, opening: TunnelOpening) async throws -> SSHTunnelEndpoint {
        if openings[key]?.id == opening.id {
            openings.removeValue(forKey: key)
        }
        guard profileGenerations[key.profileID] == opening.generation else {
            await tunnel.close()
            throw CancellationError()
        }
        if let existing = tunnels[key], existing.isActive {
            if existing !== tunnel { await tunnel.close() }
            return existing.endpoint
        }
        tunnels[key] = tunnel
        return tunnel.endpoint
    }

    func close(profileID: UUID) async {
        profileGenerations[profileID, default: 0] += 1
        for key in openings.keys.filter({ $0.profileID == profileID }) {
            openings.removeValue(forKey: key)?.task.cancel()
        }
        let matchingKeys = tunnels.keys.filter { $0.profileID == profileID }
        for key in matchingKeys {
            if let tunnel = tunnels.removeValue(forKey: key) {
                await tunnel.close()
            }
        }
    }

    func closeAll() async {
        let profileIDs = Set(tunnels.keys.map(\.profileID) + openings.keys.map(\.profileID))
        for profileID in profileIDs { profileGenerations[profileID, default: 0] += 1 }
        openings.values.forEach { $0.task.cancel() }
        openings.removeAll()
        let activeTunnels = Array(tunnels.values)
        tunnels.removeAll()
        for tunnel in activeTunnels {
            await tunnel.close()
        }
    }

    private func openTunnel(
        for profile: ConnectionProfile,
        key: TunnelKey,
        eventLoopGroup: EventLoopGroup
    ) async throws -> Tunnel {
        let authDelegate = try SSHTunnelAuthDelegate(
            username: key.sshUsername,
            password: profile.sshPassword,
            privateKey: profile.sshPrivateKey
        )
        let serverAuthDelegate = SSHTunnelKnownHostKeyDelegate(
            host: key.knownHostStoreKey,
            store: hostKeyStore
        )
        let authReady = NIOLockedValueBox<EventLoopPromise<Void>?>(nil)
        let authCompleted = NIOLockedValueBox(false)
        let sshChannel = try await ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let authPromise = channel.eventLoop.makePromise(of: Void.self)
                    authReady.withLockedValue { $0 = authPromise }
                    let handler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: serverAuthDelegate
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHTunnelAuthReadyHandler(promise: authPromise, completed: authCompleted)
                    )
                    try channel.pipeline.syncOperations.addHandler(SSHTunnelErrorHandler())
                }
            }
            .connect(host: key.sshHost, port: key.sshPort)
            .get()

        do {
            try Task.checkCancellation()
            guard let authPromise = authReady.withLockedValue({ $0 }) else {
                throw SSHTunnelError.sshConnectionClosed
            }
            let authTimeout = sshChannel.eventLoop.scheduleTask(in: .seconds(15)) {
                let shouldFail = authCompleted.withLockedValue { completed in
                    guard !completed else { return false }
                    completed = true
                    return true
                }
                if shouldFail {
                    authPromise.fail(SSHTunnelError.authenticationTimedOut)
                }
                sshChannel.close(promise: nil)
            }
            defer { authTimeout.cancel() }
            try await authPromise.futureResult.get()
            try Task.checkCancellation()
            serverAuthDelegate.commitPendingFingerprint()
        } catch {
            try? await sshChannel.close().get()
            throw error
        }

        let sshHandler = try await sshChannel.pipeline.handler(type: NIOSSHHandler.self).get()
        let targetHost = key.databaseHost
        let targetPort = key.databasePort

        let serverChannel: Channel
        do {
            serverChannel = try await ServerBootstrap(group: eventLoopGroup.next(), childGroup: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { inboundChannel in
                    guard let originatorAddress = inboundChannel.remoteAddress else {
                        return inboundChannel.eventLoop.makeFailedFuture(SSHTunnelError.missingOriginatorAddress)
                    }

                    let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
                    let directTCPIP = SSHChannelType.DirectTCPIP(
                        targetHost: targetHost,
                        targetPort: targetPort,
                        originatorAddress: originatorAddress
                    )

                    sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { sshChildChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return sshChildChannel.eventLoop.makeFailedFuture(SSHTunnelError.invalidChannelType)
                        }

                        return sshChildChannel.eventLoop.makeCompletedFuture {
                            let (sshSide, localSide) = SSHTunnelGlueHandler.matchedPair()
                            try sshChildChannel.pipeline.syncOperations.addHandler(SSHTunnelSSHWrapperHandler())
                            try sshChildChannel.pipeline.syncOperations.addHandler(sshSide)
                            try inboundChannel.pipeline.syncOperations.addHandler(localSide)
                        }
                    }

                    return promise.futureResult.map { _ in }
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
        } catch {
            try? await sshChannel.close().get()
            throw error
        }

        guard let localPort = serverChannel.localAddress?.port else {
            try? await serverChannel.close().get()
            try? await sshChannel.close().get()
            throw SSHTunnelError.missingLocalPort
        }

        return Tunnel(
            endpoint: SSHTunnelEndpoint(host: "127.0.0.1", port: localPort, serverHostname: key.databaseHost),
            sshChannel: sshChannel,
            serverChannel: serverChannel
        )
    }
}

private struct TunnelOpening: @unchecked Sendable {
    let id: UUID
    let generation: Int
    let task: Task<Tunnel, Error>
}

private struct TunnelKey: Hashable {
    let profileID: UUID
    let engine: DatabaseEngine
    let databaseHost: String
    let databasePort: Int
    let sshHost: String
    let sshPort: Int
    let sshUsername: String

    init(profile: ConnectionProfile) throws {
        let sshHost = profile.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshUsername = profile.sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshPassword = profile.sshPassword
        let sshPrivateKey = profile.sshPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sshHost.isEmpty else { throw SSHTunnelError.missingSSHHost }
        guard !sshUsername.isEmpty else { throw SSHTunnelError.missingSSHUsername }
        guard !sshPassword.isEmpty || !sshPrivateKey.isEmpty else { throw SSHTunnelError.missingSSHCredential }

        self.profileID = profile.id
        self.engine = profile.engine
        self.databaseHost = profile.host
        self.databasePort = profile.port
        self.sshHost = sshHost
        self.sshPort = max(1, profile.sshPort)
        self.sshUsername = sshUsername
    }

    var knownHostStoreKey: String {
        "\(sshHost.lowercased()):\(sshPort)"
    }
}

private final class Tunnel: @unchecked Sendable {
    let endpoint: SSHTunnelEndpoint
    private let sshChannel: Channel
    private let serverChannel: Channel

    init(endpoint: SSHTunnelEndpoint, sshChannel: Channel, serverChannel: Channel) {
        self.endpoint = endpoint
        self.sshChannel = sshChannel
        self.serverChannel = serverChannel
    }

    var isActive: Bool {
        sshChannel.isActive && serverChannel.isActive
    }

    func close() async {
        try? await serverChannel.close().get()
        try? await sshChannel.close().get()
    }
}

private final class SSHTunnelKnownHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let store: SSHTunnelHostKeyStore
    private let pendingFingerprint = NIOLockedValueBox<String?>(nil)

    init(host: String, store: SSHTunnelHostKeyStore) {
        self.host = host
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHTunnelHostKeyFingerprint.sha256(for: hostKey)
        if let expected = store.fingerprint(for: host) {
            if expected == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHTunnelError.hostKeyChanged(
                    host: host,
                    expected: expected,
                    actual: fingerprint
                ))
            }
            return
        }

        pendingFingerprint.withLockedValue { $0 = fingerprint }
        validationCompletePromise.succeed(())
    }

    func commitPendingFingerprint() {
        guard let fingerprint = pendingFingerprint.withLockedValue({ value -> String? in
            defer { value = nil }
            return value
        }) else { return }
        store.setFingerprint(fingerprint, for: host)
    }
}

private final class SSHTunnelAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let username: String
    private let password: String
    private let privateKey: NIOSSHPrivateKey?
    private let attemptedKey = NIOLockedValueBox(false)
    private let attemptedPassword = NIOLockedValueBox(false)

    init(username: String, password: String, privateKey privateKeyText: String) throws {
        self.username = username
        self.password = password
        self.privateKey = try SSHTunnelPrivateKeyParser.parse(privateKeyText)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey), let privateKey, attemptOnce(attemptedKey) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            ))
            return
        }

        if !password.isEmpty, availableMethods.contains(.password), attemptOnce(attemptedPassword) {
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            ))
            return
        }

        if privateKey != nil, !availableMethods.contains(.publicKey), password.isEmpty {
            nextChallengePromise.fail(SSHTunnelError.privateKeyAuthenticationNotSupported)
            return
        }

        if !password.isEmpty, !availableMethods.contains(.password), privateKey == nil {
            nextChallengePromise.fail(SSHTunnelError.passwordAuthenticationNotSupported)
            return
        }

        nextChallengePromise.succeed(nil)
    }

    private func attemptOnce(_ attempted: NIOLockedValueBox<Bool>) -> Bool {
        attempted.withLockedValue { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
}

private struct SSHTunnelHostKeyFingerprint {
    static func sha256(for key: NIOSSHPublicKey) -> String {
        let openSSHKey = String(openSSHPublicKey: key)
        let parts = openSSHKey.split(separator: " ")
        let blob = parts.count >= 2 ? Data(base64Encoded: String(parts[1])) : nil
        let digest = SHA256.hash(data: blob ?? Data(openSSHKey.utf8))
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

final class SSHTunnelUserDefaultsHostKeyStore: SSHTunnelHostKeyStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NIOLock()

    init(defaults: UserDefaults = .standard, storageKey: String = "portsql.ssh.knownHosts.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func fingerprint(for hostKey: String) -> String? {
        lock.withLock {
            defaults.dictionary(forKey: storageKey)?[hostKey] as? String
        }
    }

    func setFingerprint(_ fingerprint: String, for hostKey: String) {
        lock.withLock {
            var hosts = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            hosts[hostKey] = fingerprint
            defaults.set(hosts, forKey: storageKey)
        }
    }
}

private enum SSHTunnelPrivateKeyParser {
    static func parse(_ text: String) throws -> NIOSSHPrivateKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKey(trimmed)
        }

        throw SSHTunnelError.invalidPrivateKey
    }

    private static func parseOpenSSHPrivateKey(_ text: String) throws -> NIOSSHPrivateKey {
        let base64 = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard let data = Data(base64Encoded: base64) else {
            throw SSHTunnelError.invalidPrivateKey
        }

        var reader = SSHBinaryReader(data: data)
        guard try reader.readCString() == "openssh-key-v1" else {
            throw SSHTunnelError.invalidPrivateKey
        }

        let cipherName = try reader.readString()
        let kdfName = try reader.readString()
        _ = try reader.readDataString()
        let keyCount = try reader.readUInt32()

        guard cipherName == "none", kdfName == "none" else {
            throw SSHTunnelError.encryptedPrivateKeyUnsupported
        }

        guard keyCount == 1 else {
            throw SSHTunnelError.invalidPrivateKey
        }

        _ = try reader.readDataString()
        var privateReader = SSHBinaryReader(data: try reader.readDataString())
        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            throw SSHTunnelError.invalidPrivateKey
        }

        let keyType = try privateReader.readString()
        switch keyType {
        case "ssh-ed25519":
            _ = try privateReader.readDataString()
            let privateAndPublic = try privateReader.readDataString()
            guard privateAndPublic.count >= 32 else {
                throw SSHTunnelError.invalidPrivateKey
            }
            return try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: privateAndPublic.prefix(32)))
        case "ecdsa-sha2-nistp256":
            try validateCurve("nistp256", reader: &privateReader)
            let scalar = try fixedWidthScalar(from: privateReader.readDataString(), size: 32)
            return try NIOSSHPrivateKey(p256Key: .init(rawRepresentation: scalar))
        case "ecdsa-sha2-nistp384":
            try validateCurve("nistp384", reader: &privateReader)
            let scalar = try fixedWidthScalar(from: privateReader.readDataString(), size: 48)
            return try NIOSSHPrivateKey(p384Key: .init(rawRepresentation: scalar))
        case "ecdsa-sha2-nistp521":
            try validateCurve("nistp521", reader: &privateReader)
            let scalar = try fixedWidthScalar(from: privateReader.readDataString(), size: 66)
            return try NIOSSHPrivateKey(p521Key: .init(rawRepresentation: scalar))
        default:
            throw SSHTunnelError.invalidPrivateKey
        }
    }

    private static func validateCurve(_ expected: String, reader: inout SSHBinaryReader) throws {
        let curve = try reader.readString()
        guard curve == expected else {
            throw SSHTunnelError.invalidPrivateKey
        }
        _ = try reader.readDataString()
    }

    private static func fixedWidthScalar(from mpint: Data, size: Int) throws -> Data {
        var bytes = Array(mpint)
        while bytes.count > size, bytes.first == 0 {
            bytes.removeFirst()
        }
        guard bytes.count <= size else {
            throw SSHTunnelError.invalidPrivateKey
        }
        if bytes.count < size {
            bytes.insert(contentsOf: repeatElement(0, count: size - bytes.count), at: 0)
        }
        return Data(bytes)
    }
}

private struct SSHBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readCString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else {
            throw SSHTunnelError.invalidPrivateKey
        }
        let bytes = data[offset..<end]
        offset = data.index(after: end)
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func readString() throws -> String {
        String(decoding: try readDataString(), as: UTF8.self)
    }

    mutating func readDataString() throws -> Data {
        let length = Int(try readUInt32())
        guard length >= 0, offset + length <= data.count else {
            throw SSHTunnelError.invalidPrivateKey
        }
        let end = offset + length
        let value = data[offset..<end]
        offset = end
        return Data(value)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHTunnelError.invalidPrivateKey
        }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }
}

private final class SSHTunnelAuthReadyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private let completed: NIOLockedValueBox<Bool>

    init(promise: EventLoopPromise<Void>, completed: NIOLockedValueBox<Bool>) {
        self.promise = promise
        self.completed = completed
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete {
                promise.succeed(())
            }
            context.pipeline.removeHandler(self, promise: nil)
            return
        }

        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete {
            promise.fail(error)
        }
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete {
            promise.fail(SSHTunnelError.sshConnectionClosed)
        }
        context.fireChannelInactive()
    }

    private func complete(_ body: () -> Void) {
        let shouldComplete = completed.withLockedValue { value in
            guard !value else { return false }
            value = true
            return true
        }
        if shouldComplete {
            body()
        }
    }
}

private final class SSHTunnelErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class SSHTunnelSSHWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHTunnelError.invalidData)
            return
        }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

private final class SSHTunnelGlueHandler {
    private var partner: SSHTunnelGlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (SSHTunnelGlueHandler, SSHTunnelGlueHandler) {
        let first = SSHTunnelGlueHandler()
        let second = SSHTunnelGlueHandler()
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

    private func partnerWriteEOF() {
        context?.close(mode: .output, promise: nil)
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

extension SSHTunnelGlueHandler: ChannelDuplexHandler {
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

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
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
