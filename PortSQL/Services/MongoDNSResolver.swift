import Foundation
import dnssd

// Use the device's resolver, including VPN/split DNS; iOS does not expose resolv.conf.
enum MongoDNSResolver {
    struct SeedList: Sendable {
        let hosts: [MongoHostAddress]
        let options: [String: String]
    }

    static func resolve(host: String, timeoutSeconds: Int) async throws -> SeedList {
        async let serviceRecords = query(name: "_mongodb._tcp." + host, type: UInt16(kDNSServiceType_SRV), timeoutSeconds: timeoutSeconds)
        async let textRecords = query(name: host, type: UInt16(kDNSServiceType_TXT), timeoutSeconds: timeoutSeconds)
        let (services, texts) = try await (serviceRecords, textRecords)
        guard !services.isEmpty, services.count <= 32, texts.count <= 1 else { throw MongoConnectionError.invalidSRVRecords }
        let labels = host.lowercased().split(separator: ".")
        let parent = labels.count > 2 ? labels.dropFirst().joined(separator: ".") : host.lowercased()
        let hosts = try services.map { record -> MongoHostAddress in
            let bytes = [UInt8](record)
            guard bytes.count > 7 else { throw MongoConnectionError.invalidSRVRecords }
            let port = Int(bytes[4]) << 8 | Int(bytes[5])
            var index = 6
            var labels: [String] = []
            while index < bytes.count, bytes[index] != 0 {
                let count = Int(bytes[index])
                index += 1
                guard count <= 63, index + count <= bytes.count,
                      let label = String(bytes: bytes[index..<(index + count)], encoding: .utf8) else {
                    throw MongoConnectionError.invalidSRVRecords
                }
                labels.append(label)
                index += count
            }
            guard index == bytes.count - 1 else { throw MongoConnectionError.invalidSRVRecords }
            let target = labels.joined(separator: ".").lowercased()
            guard target.hasSuffix("." + parent) else { throw MongoConnectionError.invalidSRVRecords }
            return try MongoHostAddress.parse(target + ":" + String(port))
        }
        var options: [String: String] = [:]
        if let record = texts.first {
            let bytes = [UInt8](record)
            var index = 0
            var parts = ""
            while index < bytes.count {
                let count = Int(bytes[index])
                index += 1
                guard index + count <= bytes.count, let part = String(bytes: bytes[index..<(index + count)], encoding: .utf8) else {
                    throw MongoConnectionError.invalidSRVRecords
                }
                parts += part
                index += count
            }
            options = try MongoConnectionURI.parseOptions(parts)
            guard Set(options.keys).isSubset(of: ["authsource", "replicaset"]), options.values.allSatisfy({ !$0.isEmpty }) else {
                throw MongoConnectionError.invalidSRVRecords
            }
        }
        return SeedList(hosts: Array(Set(hosts)).sorted { $0.displayName < $1.displayName }, options: options)
    }

    private static func query(name: String, type: UInt16, timeoutSeconds: Int) async throws -> [Data] {
        let request = MongoDNSRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(name: name, type: type, timeout: max(1, min(timeoutSeconds, 10)), continuation: continuation)
            }
        } onCancel: { request.cancel() }
    }
}

private final class MongoDNSRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ad.neko.portsql.mongo-dns")
    private var reference: DNSServiceRef?
    private var continuation: CheckedContinuation<[Data], Error>?
    private var records: [Data] = []
    private var cancelled = false

    func start(name: String, type: UInt16, timeout: Int, continuation: CheckedContinuation<[Data], Error>) {
        queue.async { [self] in
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let status = DNSServiceQueryRecord(&reference, DNSServiceFlags(kDNSServiceFlagsTimeout), 0, name, type,
                UInt16(kDNSServiceClass_IN), { _, flags, _, error, _, recordType, _, length, data, _, context in
                    guard let context else { return }
                    let request = Unmanaged<MongoDNSRequest>.fromOpaque(context).takeUnretainedValue()
                    if error != kDNSServiceErr_NoError {
                        if recordType == UInt16(kDNSServiceType_TXT) && error == kDNSServiceErr_NoSuchRecord { request.finish(.success([])) }
                        else { request.finish(.failure(MongoConnectionError.dnsLookupFailed)) }
                        return
                    }
                    if let data, length > 0, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                        request.records.append(Data(bytes: data, count: Int(length)))
                    }
                    guard request.records.count <= 32 else { request.finish(.failure(MongoConnectionError.invalidSRVRecords)); return }
                    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { request.finish(.success(request.records)) }
                }, Unmanaged.passUnretained(self).toOpaque())
            guard status == kDNSServiceErr_NoError, let reference else { finish(.failure(MongoConnectionError.dnsLookupFailed)); return }
            let scheduled = DNSServiceSetDispatchQueue(reference, queue)
            guard scheduled == kDNSServiceErr_NoError else { finish(.failure(MongoConnectionError.dnsLookupFailed)); return }
            queue.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
                self?.finish(.failure(MongoConnectionError.dnsLookupFailed))
            }
        }
    }

    func cancel() {
        queue.async { [self] in cancelled = true; finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        continuation.resume(with: result)
    }
}
