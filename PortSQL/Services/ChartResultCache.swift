import Foundation

/// A saved chart's last query result and when it was fetched.
struct CachedChartResult: Codable, Sendable {
    var result: QueryResultTable
    var fetchedAt: Date
    /// The page filter values the query ran with, to tell when they have since changed.
    var parameterValues: [String: String]?
}

/// Keeps each saved chart's last result on disk, one file per chart, so charts open instantly with
/// their previous data and only query the database when asked. Reads and writes happen off the main
/// thread; the in-memory copy answers repeat lookups without touching the disk.
@MainActor final class ChartResultCache {
    static let shared = ChartResultCache()

    private let directory: URL
    private var memory: [UUID: CachedChartResult] = [:]
    private var missing: Set<UUID> = []
    private let io = DispatchQueue(label: "Portbase.ChartResultCache", qos: .utility)

    init(directory override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = override ?? support.appendingPathComponent("PortSQL/ChartCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cached result if it is already in memory, without waiting on the disk.
    func peek(_ id: UUID) -> CachedChartResult? { memory[id] }

    func entry(for id: UUID) async -> CachedChartResult? {
        if let cached = memory[id] { return cached }
        if missing.contains(id) { return nil }
        let url = fileURL(id)
        let loaded: CachedChartResult? = await withCheckedContinuation { continuation in
            io.async {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let value = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(CachedChartResult.self, from: $0) }
                continuation.resume(returning: value)
            }
        }
        // A store made while the read was in flight is newer than what the disk held.
        if let current = memory[id] { return current }
        if let loaded { memory[id] = loaded } else { missing.insert(id) }
        return loaded
    }

    @discardableResult
    func store(_ result: QueryResultTable, for id: UUID, parameterValues: [String: String]? = nil, fetchedAt: Date = .now) -> CachedChartResult {
        let entry = CachedChartResult(result: result, fetchedAt: fetchedAt, parameterValues: parameterValues)
        memory[id] = entry
        missing.remove(id)
        let url = fileURL(id)
        io.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(entry) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return entry
    }

    func remove(_ id: UUID) {
        memory[id] = nil
        missing.insert(id)
        let url = fileURL(id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    func removeAll() {
        memory = [:]
        missing = []
        let directory = directory
        io.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Removes results for charts that no longer exist.
    func prune(keeping ids: Set<UUID>) {
        memory = memory.filter { ids.contains($0.key) }
        let directory = directory
        io.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    var storageSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Splits the single cache file earlier versions kept into per-chart files, then removes it.
    func migrateLegacyCache(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let directory = directory
        io.async {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? Data(contentsOf: url), let legacy = try? decoder.decode([UUID: QueryResultTable].self, from: data) {
                let fetchedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
                for (id, result) in legacy {
                    let target = directory.appendingPathComponent(id.uuidString + ".json")
                    guard !FileManager.default.fileExists(atPath: target.path),
                          let encoded = try? encoder.encode(CachedChartResult(result: result, fetchedAt: fetchedAt, parameterValues: nil)) else { continue }
                    try? encoded.write(to: target, options: .atomic)
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
