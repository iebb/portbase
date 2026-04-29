import Foundation

struct CachedSchemaCatalog: Codable, Hashable {
    let databases: [String]
    let selectedDatabase: String?
    let catalog: [SchemaTableDescriptor]
    let cachedAt: Date

    func isFresh(duration: TimeInterval, now: Date = .now) -> Bool {
        now.timeIntervalSince(cachedAt) <= duration
    }
}

final class SchemaCacheStore: @unchecked Sendable {
    static let shared = SchemaCacheStore()

    private let directoryURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = support
            .appendingPathComponent("PortSQL", isDirectory: true)
            .appendingPathComponent("SchemaCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func cachedCatalog(for profile: ConnectionProfile, requestedDatabase: String) -> CachedSchemaCatalog? {
        lock.lock()
        defer { lock.unlock() }
        let url = cacheURL(for: profile, requestedDatabase: requestedDatabase)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CachedSchemaCatalog.self, from: data)
    }

    func store(
        databases: [String],
        selectedDatabase: String?,
        catalog: [SchemaTableDescriptor],
        for profile: ConnectionProfile,
        requestedDatabase: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        let cache = CachedSchemaCatalog(
            databases: databases,
            selectedDatabase: selectedDatabase,
            catalog: catalog,
            cachedAt: .now
        )
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL(for: profile, requestedDatabase: requestedDatabase), options: [.atomic])
    }

    func removeCatalog(for profile: ConnectionProfile, requestedDatabase: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: cacheURL(for: profile, requestedDatabase: requestedDatabase))
    }

    private func cacheURL(for profile: ConnectionProfile, requestedDatabase: String) -> URL {
        directoryURL.appendingPathComponent(cacheKey(for: profile, requestedDatabase: requestedDatabase) + ".json")
    }

    private func cacheKey(for profile: ConnectionProfile, requestedDatabase: String) -> String {
        let raw = [
            profile.id.uuidString,
            profile.engine.rawValue,
            profile.host,
            String(profile.port),
            profile.username,
            requestedDatabase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ].joined(separator: "|")
        return raw.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? profile.id.uuidString
    }
}
