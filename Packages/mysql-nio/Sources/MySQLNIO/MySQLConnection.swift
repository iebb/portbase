import NIOCore
import Logging
import NIOSSL
import NIOPosix

public final class MySQLConnection: MySQLDatabase, Sendable {
    public static func connect(
        to socketAddress: SocketAddress,
        username: String,
        database: String,
        password: String? = nil,
        tlsConfiguration: TLSConfiguration? = .makeClientConfiguration(),
        allowPlaintextFallback: Bool = false,
        serverHostname: String? = nil,
        handshakeTimeout: TimeAmount = .seconds(15),
        logger: Logger = .init(label: "codes.vapor.mysql"),
        on eventLoop: any EventLoop
    ) -> EventLoopFuture<MySQLConnection> {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            // A connection quiet for half a minute is probed, and closed after three probes go unanswered, so
            // one left open learns its server is gone instead of finding out at its next query.
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), Self.keepAliveIdleOption), value: 30)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 10)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
        
        logger.debug("Opening new connection to \(socketAddress)")
        
        return bootstrap.connect(to: socketAddress).flatMap { channel in
            let sequence = MySQLPacketSequence()
            let done = channel.eventLoop.makePromise(of: Void.self)
            done.futureResult.whenFailure { _ in
                channel.close(mode: .all, promise: nil)
            }
            // The server speaks first. One that takes the connection and never greets, as a dead tunnel or
            // another kind of server does, would otherwise be waited on forever.
            let timeout = channel.eventLoop.scheduleTask(in: handshakeTimeout) {
                done.fail(MySQLError.handshakeTimedOut)
            }
            done.futureResult.whenComplete { _ in timeout.cancel() }
            do {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(MySQLPacketDecoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MessageToByteHandler(MySQLPacketEncoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MySQLConnectionHandler(logger: logger, state: .handshake(.init(
                        username: username,
                        database: database,
                        password: password,
                        tlsConfiguration: tlsConfiguration,
                        allowPlaintextFallback: allowPlaintextFallback,
                        serverHostname: serverHostname,
                        done: done
                    )), sequence: sequence),
                    ErrorHandler()
                ], position: .last)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return done.futureResult.map { MySQLConnection(channel: channel, logger: logger) }
        }
    }
    
    #if canImport(Darwin)
    private static let keepAliveIdleOption = TCP_KEEPALIVE
    #else
    private static let keepAliveIdleOption = TCP_KEEPIDLE
    #endif

    public let channel: any Channel
    
    public var eventLoop: any EventLoop {
        self.channel.eventLoop
    }
    
    public let logger: Logger
    
    public var isClosed: Bool {
        !self.channel.isActive
    }
    
    internal init(channel: any Channel, logger: Logger) {
        self.channel = channel
        self.logger = logger
    }
    
    public func close() -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
        return self.channel.close(mode: .all)
    }
    
    public func send(_ command: any MySQLCommand, logger: Logger) -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeFailedFuture(MySQLError.closed)
        }

        let promise = self.eventLoop.makePromise(of: Void.self)
        
        let c = MySQLCommandContext(
            handler: command,
            promise: promise
        )
        return self.channel.write(c)
            .flatMap { promise.futureResult }
    }
    
    public func withConnection<T>(_ closure: @escaping (MySQLConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    
    deinit {
        assert(!self.channel.isActive, "MySQLConnection not closed before deinit.")
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    init() { }
    
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        assertionFailure("uncaught error: \(error)")
    }
}
