import Foundation

@MainActor protocol WorkspaceCloudStorage {
    var dictionaryRepresentation: [String: Any] { get }
    func data(forKey key: String) -> Data?
    func setData(_ data: Data, forKey key: String)
    func synchronize()
}

@MainActor struct SystemWorkspaceCloudStorage: WorkspaceCloudStorage {
    private let store = NSUbiquitousKeyValueStore.default
    var dictionaryRepresentation: [String: Any] { store.dictionaryRepresentation }
    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func setData(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() { store.synchronize() }
}

/// A saved item and its deletion share the same identity and revision. A late
/// notification cannot bring a deleted item back or overwrite a newer edit.
struct WorkspaceSyncCollection<Value: Codable & Identifiable & Equatable>: Codable, Equatable where Value.ID == UUID {
    struct Record: Codable, Equatable {
        let id: UUID
        let updatedAt: Date
        let value: Value?
    }
    private(set) var records: [Record] = []
    var legacySnapshot: [Value]?
    var values: [Value] { records.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }.compactMap(\.value) }

    mutating func set(_ value: Value, at date: Date = .now) {
        records.removeAll { $0.id == value.id }
        records.append(Record(id: value.id, updatedAt: date, value: value))
        normalize()
    }
    mutating func remove(_ id: UUID, at date: Date = .now) {
        records.removeAll { $0.id == id }
        records.append(Record(id: id, updatedAt: date, value: nil))
        normalize()
    }
    mutating func merge(_ remote: Self) {
        var map = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for record in remote.records {
            if let existing = map[record.id] {
                if record.updatedAt > existing.updatedAt || (record.updatedAt == existing.updatedAt && winsTie(record, over: existing)) { map[record.id] = record }
            } else { map[record.id] = record }
        }
        records = Array(map.values); normalize()
    }
    private func winsTie(_ lhs: Record, over rhs: Record) -> Bool {
        if lhs.value == nil { return true }
        if rhs.value == nil { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs.value).lexicographicallyPrecedes(encoder.encode(rhs.value))) ?? false
    }
    private mutating func normalize() { records.sort { $0.id.uuidString < $1.id.uuidString } }
}

@MainActor final class WorkspaceCloudCollection<Value: Codable & Identifiable & Equatable> where Value.ID == UUID {
    private(set) var state = WorkspaceSyncCollection<Value>()
    private(set) var errorMessage: String?
    private let key: String
    private let url: URL
    private let cloud: any WorkspaceCloudStorage
    private var writable = true
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let quotaMessage: String

    init(key: String, url: URL, initial: [Value], initialDate: (Value) -> Date, cloud: any WorkspaceCloudStorage = SystemWorkspaceCloudStorage(), quotaMessage: String = L10n.text("Saved queries are on this device. The library exceeds the iCloud sync limit.")) {
        self.key = key; self.url = url; self.cloud = cloud
        self.quotaMessage = quotaMessage
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = .sortedKeys
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            if let stored = try WorkspaceFileStore.read(WorkspaceSyncCollection<Value>.self, from: url, decoder: decoder) {
                guard Set(stored.records.map(\.id)).count == stored.records.count,
                      stored.records.allSatisfy({ $0.value == nil || $0.id == $0.value?.id }) else { throw CocoaError(.fileReadCorruptFile) }
                state = stored
            }
        } catch {
            writable = false
            errorMessage = L10n.text("Saved work could not be loaded. The original files have been preserved.")
        }
        for value in initial {
            let revision = initialDate(value)
            if let existing = state.records.first(where: { $0.id == value.id }) {
                if existing.value != nil && revision > existing.updatedAt { state.set(value, at: revision) }
            } else { state.set(value, at: revision) }
        }
    }

    func save(_ values: [Value]) {
        guard writable else { return }
        let ids = Set(values.map(\.id))
        for record in state.records where record.value != nil && !ids.contains(record.id) { state.remove(record.id) }
        for value in values {
            if let previous = state.records.first(where: { $0.id == value.id })?.value {
                if !equalContent(previous, value) { state.set(value) }
            } else { state.set(value) }
        }
        persist(push: true)
    }

    /// Keep the existing bookmark key readable by older iOS releases. Only a
    /// changed legacy item creates a revision; an unchanged echo does not.
    func ingestLegacy(_ values: [Value], initialDate: (Value) -> Date, usesIntrinsicRevision: Bool = false) -> [Value] {
        guard writable else { return values }
        let previous = state.legacySnapshot ?? []
        for value in values {
            if let record = state.records.first(where: { $0.id == value.id }) {
                guard let current = record.value else { continue }
                if !equalContent(current, value) {
                    if usesIntrinsicRevision {
                        if initialDate(value) > record.updatedAt { state.set(value, at: initialDate(value)) }
                    } else if let old = previous.first(where: { $0.id == value.id }), !equalContent(old, value) {
                        state.set(value)
                    }
                }
            } else { state.set(value, at: initialDate(value)) }
        }
        state.legacySnapshot = values
        persist(push: true)
        return state.values
    }

    func seedDeletions(_ deletions: [UUID: Date]) {
        guard writable else { return }
        for (id, date) in deletions {
            if let previous = state.records.first(where: { $0.id == id }) {
                if previous.updatedAt < date { state.remove(id, at: date) }
            } else { state.remove(id, at: date) }
        }
        persist(push: false)
    }

    func noteLegacySnapshot(_ values: [Value]) {
        guard writable else { return }
        state.legacySnapshot = values
        persist(push: false)
    }

    private func equalContent(_ lhs: Value, _ rhs: Value) -> Bool {
        (try? encoder.encode(lhs) == encoder.encode(rhs)) == true
    }

    func mergeCloud() -> [Value]? {
        guard writable else { return nil }
        if let data = cloud.data(forKey: key) {
            do {
                let remote = try decoder.decode(WorkspaceSyncCollection<Value>.self, from: data)
                guard Set(remote.records.map(\.id)).count == remote.records.count,
                      remote.records.allSatisfy({ $0.value == nil || $0.id == $0.value?.id }) else { throw CocoaError(.fileReadCorruptFile) }
                state.merge(remote)
            } catch {
                // Preserve the remote payload for recovery instead of replacing it.
                writable = false
                errorMessage = L10n.text("Saved work could not be loaded. The original files have been preserved.")
                return nil
            }
        }
        persist(push: true)
        return state.values
    }

    private func persist(push: Bool) {
        guard writable else { return }
        do {
            let local = try encoder.encode(state)
            if (try? Data(contentsOf: url)) != local { try WorkspaceFileStore.write(local, to: url) }
            guard push else { return }
            var remote = state
            remote.legacySnapshot = nil
            let data = try encoder.encode(remote)
            guard cloud.data(forKey: key) != data else { errorMessage = nil; return }
            guard WorkspaceCloudQuota.canStore(data, forKey: key, values: cloud.dictionaryRepresentation) else {
                errorMessage = quotaMessage
                return
            }
            cloud.setData(data, forKey: key)
            cloud.synchronize()
            errorMessage = nil
        } catch {
            errorMessage = L10n.text("Saved work could not be written. Free some device storage and try again.")
        }
    }
}

@MainActor enum WorkspaceCloudQuota {
    static func canStore(_ value: Any, forKey key: String, in store: NSUbiquitousKeyValueStore) -> Bool {
        canStore(value, forKey: key, values: store.dictionaryRepresentation)
    }
    static func canStore(_ value: Any, forKey key: String, values original: [String: Any]) -> Bool {
        var values = original
        values[key] = value
        guard values.count <= 1024,
              let bytes = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return false }
        return bytes.count < 900_000
    }
}
