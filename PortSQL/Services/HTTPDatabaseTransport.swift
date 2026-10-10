import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

private final class HTTPDatabaseSocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [Channel] = []
    private var closed = false

    func install(_ channel: Channel) {
        lock.withLock {
            if closed { channel.close(promise: nil) }
            else { channels.append(channel) }
        }
    }

    func close() {
        let active = lock.withLock {
            closed = true
            let active = channels; channels.removeAll(); return active
        }
        active.forEach { $0.close(promise: nil) }
    }
}

private final class HTTPDatabaseResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    let promise: EventLoopPromise<HTTPDatabaseResponse>
    private var head: HTTPResponseHead?
    private var body = Data()
    private var finished = false

    init(eventLoop: EventLoop) { promise = eventLoop.makePromise(of: HTTPDatabaseResponse.self) }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .head(let response):
            if (100..<200).contains(response.status.code) {
                if response.status.code == 101 { fail(HTTPDatabaseError.invalidResponse, context: context) }
                return
            }
            guard head == nil else { fail(HTTPDatabaseError.invalidResponse, context: context); return }
            if (300..<400).contains(response.status.code) { fail(HTTPDatabaseError.redirectRefused, context: context); return }
            if let length = response.headers.first(name: "Content-Length").flatMap(Int.init), length > HTTPDatabaseTransport.maximumResponseBytes {
                fail(HTTPDatabaseError.responseTooLarge, context: context); return
            }
            if let encoding = response.headers.first(name: "Content-Encoding"), encoding.lowercased() != "identity" {
                fail(HTTPDatabaseError.invalidResponse, context: context); return
            }
            head = response
        case .body(var buffer):
            guard head != nil else { fail(HTTPDatabaseError.invalidResponse, context: context); return }
            guard body.count + buffer.readableBytes <= HTTPDatabaseTransport.maximumResponseBytes else {
                fail(HTTPDatabaseError.responseTooLarge, context: context); return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            finished = true
            var headers: [String: String] = [:]
            // Only retain protocol metadata, never cookies or authentication challenge material.
            for name in ["x-clickhouse-summary", "x-clickhouse-exception-code", "content-type"] {
                headers[name] = head.headers.first(name: name)
            }
            promise.succeed(.init(status: Int(head.status.code), headers: headers, body: body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error, context: context) }
    func channelInactive(context: ChannelHandlerContext) {
        failPending(HTTPDatabaseError.invalidResponse)
        context.fireChannelInactive()
    }
    func handlerRemoved(context: ChannelHandlerContext) { failPending(HTTPDatabaseError.invalidResponse) }

    // A connection candidate can close before becoming active, without channelInactive.
    // Its closeFuture and initializer failure must still complete its independent promise.
    func failPending(_ error: Error) {
        guard !finished else { return }
        finished = true; promise.fail(error)
    }
    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !finished else { return }
        failPending(error); context.close(promise: nil)
    }
}

enum HTTPDatabaseTransport {
    static let maximumResponseBytes = 32 * 1_024 * 1_024

    static func request(profile: ConnectionProfile, method: String, path: String,
                        queryItems: [URLQueryItem] = [], body: Data? = nil,
                        timeoutSeconds: Int = 30, eventLoopGroup: EventLoopGroup) async throws -> HTTPDatabaseResponse {
        guard profile.engine != .clickhouse || profile.httpAuthentication != .apiKey else { throw DatabaseServiceError.unsupported }
        guard ["GET", "POST", "PUT", "DELETE"].contains(method), path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\"),
              !profile.host.isEmpty, !profile.host.contains("/"), !profile.host.contains("@"),
              (1...65_535).contains(profile.port), (body?.count ?? 0) <= 1_048_576,
              [profile.host, profile.username, profile.password, path].allSatisfy({ !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
            throw HTTPDatabaseError.invalidRequest
        }
        if profile.usesTLS, profile.usesSSHTunnel, DatabaseService.isIPAddress(profile.host) {
            throw DatabaseServiceError.tlsIdentityUnavailableThroughTunnel
        }
        var components = URLComponents()
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let uri = components.string else { throw HTTPDatabaseError.invalidRequest }
        let authorization: String?
        switch profile.httpAuthentication {
        case .basic:
            guard !profile.username.contains(":") else { throw HTTPDatabaseError.invalidRequest }
            authorization = profile.username.isEmpty && profile.password.isEmpty ? nil : "Basic " + Data("\(profile.username):\(profile.password)".utf8).base64EncodedString()
        case .apiKey:
            guard !profile.password.isEmpty else { throw HTTPDatabaseError.invalidRequest }
            authorization = "ApiKey " + profile.password
        case .bearer:
            guard !profile.password.isEmpty else { throw HTTPDatabaseError.invalidRequest }
            authorization = "Bearer " + profile.password
        }
        let timeout = min(300, max(1, timeoutSeconds))
        let lifetime = HTTPDatabaseSocketLifetime()
        defer { lifetime.close() }
        return try await withQueryTimeout(seconds: timeout, closeConnection: { lifetime.close() }) {
            let endpoint = try await SSHTunnelService.shared.endpoint(for: profile, eventLoopGroup: eventLoopGroup)
            // HTTP has no authenticated TLS-unsupported negotiation: Prefer TLS remains TLS-only.
            let tls = profile.usesTLS ? try NIOSSLContext(configuration: DatabaseService.tlsConfiguration(for: profile)) : nil
            let channel = try await ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(.seconds(Int64(min(timeout, 10))))
                .channelInitializer { channel in
                    let responseHandler = HTTPDatabaseResponseHandler(eventLoop: channel.eventLoop)
                    channel.closeFuture.whenComplete { _ in responseHandler.failPending(HTTPDatabaseError.invalidResponse) }
                    lifetime.install(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        do {
                            if let tls {
                                let hostname = DatabaseService.isIPAddress(endpoint.serverHostname) ? nil : endpoint.serverHostname
                                try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: hostname))
                            }
                            try channel.pipeline.syncOperations.addHTTPClientHandlers()
                            try channel.pipeline.syncOperations.addHandler(responseHandler)
                        } catch {
                            responseHandler.failPending(error)
                            throw error
                        }
                    }
                }
                .connect(host: endpoint.host, port: endpoint.port).get()
            try Task.checkCancellation()
            let handler = try await channel.pipeline.handler(type: HTTPDatabaseResponseHandler.self).get()
            let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
            var headers = HTTPHeaders([("Host", "\(host):\(profile.port)"), ("Accept", "application/json"),
                ("Accept-Encoding", "identity"), ("Connection", "close"), ("Content-Length", String(body?.count ?? 0))])
            if let authorization { headers.add(name: "Authorization", value: authorization) }
            if body != nil { headers.add(name: "Content-Type", value: profile.engine == .clickhouse ? "text/plain; charset=utf-8" : "application/json") }
            let head = HTTPRequestHead(version: .http1_1, method: HTTPMethod(rawValue: method), uri: uri, headers: headers)
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body {
                var buffer = channel.allocator.buffer(capacity: body.count)
                buffer.writeBytes(body)
                channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
            try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
            let response = try await handler.promise.futureResult.get()
            guard (200..<300).contains(response.status) else { throw HTTPDatabaseError.status(response.status) }
            return response
        }
    }
}
