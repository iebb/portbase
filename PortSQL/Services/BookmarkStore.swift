import Foundation
import Observation

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [ConnectionProfile] = []

    private let keyValueStore = NSUbiquitousKeyValueStore.default
    private let syncKey = "portsql.bookmarks"
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("PortSQL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("bookmarks.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
        installDevelopmentProfileIfAvailable()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore,
            queue: .main
        ) { [weak self] _ in
            self?.mergeFromCloud()
        }
    }

    func upsert(_ profile: ConnectionProfile) {
        if let index = bookmarks.firstIndex(where: { $0.id == profile.id }) {
            bookmarks[index] = profile
        } else {
            bookmarks.insert(profile, at: 0)
        }
        persist()
    }

    func delete(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        persist()
    }

    func bookmark(with id: UUID?) -> ConnectionProfile? {
        guard let id else { return bookmarks.first }
        return bookmarks.first(where: { $0.id == id })
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([ConnectionProfile].self, from: data) {
            bookmarks = normalized(decoded)
        } else {
            bookmarks = []
        }
        mergeFromCloud()
    }

    private func persist() {
        bookmarks = normalized(bookmarks)
        guard let data = try? encoder.encode(bookmarks) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        keyValueStore.set(data, forKey: syncKey)
        keyValueStore.synchronize()
        objectWillChange.send()
    }

    private func mergeFromCloud() {
        guard let data = keyValueStore.data(forKey: syncKey),
              let remote = try? decoder.decode([ConnectionProfile].self, from: data) else {
            return
        }
        let ordered = normalized(bookmarks + remote)
        if ordered != bookmarks {
            bookmarks = ordered
            if let payload = try? encoder.encode(bookmarks) {
                try? payload.write(to: fileURL, options: [.atomic])
            }
            objectWillChange.send()
        }
    }

    private func normalized(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        var mergedByID: [UUID: ConnectionProfile] = [:]
        for profile in profiles {
            mergedByID[profile.id] = profile
        }
        return mergedByID.values.sorted(by: { $0.createdAt > $1.createdAt })
    }

    private func installDevelopmentProfileIfAvailable() {
        guard let profile = ConnectionProfile.developmentProfileFromConfiguration() else { return }

        if let index = bookmarks.firstIndex(where: { $0.id == profile.id }) {
            guard bookmarks[index] != profile else { return }
            bookmarks[index] = profile
        } else {
            bookmarks.insert(profile, at: 0)
        }

        persist()
    }
}
