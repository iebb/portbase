import Foundation
import Observation

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [ConnectionProfile] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var cloudSyncError: String?

    private let keyValueStore = NSUbiquitousKeyValueStore.default
    private let syncKey = "portsql.bookmarks"
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var profileCloudCollection: WorkspaceCloudCollection<ConnectionProfile>?
    private let cloudSyncEnabled: Bool

    init(directory directoryOverride: URL? = nil, cloudSyncEnabled: Bool = true) {
        self.cloudSyncEnabled = cloudSyncEnabled
        let directory = directoryOverride ?? WorkspaceFileStore.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("bookmarks.json")
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if cloudSyncEnabled { keyValueStore.synchronize() }
        load()
        if cloudSyncEnabled {
            profileCloudCollection = WorkspaceCloudCollection(key: "portsql.bookmarks.v2",
                url: directory.appendingPathComponent("bookmark-sync.json"), initial: bookmarks, initialDate: { $0.createdAt },
                quotaMessage: L10n.text("Connections are saved on this device. The library exceeds the iCloud sync limit."))
            mergeFromCloud()
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mergeFromCloud()
            }
        }
    }

    @discardableResult
    func upsert(_ profile: ConnectionProfile) -> Bool {
        if profile.engine == .redis, !profile.trimmedDefaultDatabase.isEmpty,
           Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true {
            errorMessage = RedisClientError.invalidDatabase.localizedDescription
            return false
        }
        if profile.engine.isLocal, profile.sqliteFileName == nil {
            errorMessage = L10n.text("Choose or create a SQLite database file.")
            return false
        }
        guard MongoConnectionURI.isValidProfile(profile) else {
            errorMessage = MongoConnectionError.invalidURI.localizedDescription
            return false
        }
        errorMessage = nil
        let secured = secure(profile, persistPrivateCAInput: true)
        if let index = bookmarks.firstIndex(where: { $0.id == secured.id }) {
            Task { await SSHTunnelService.shared.close(profileID: secured.id) }
            bookmarks[index] = secured
        } else {
            bookmarks.insert(secured, at: 0)
        }
        persist()
        return true
    }

    func delete(at offsets: IndexSet) {
        let deletedIDs = offsets.compactMap { bookmarks.indices.contains($0) ? bookmarks[$0].id : nil }
        deletedIDs.forEach(KeychainService.deleteAllSecrets)
        deletedIDs.forEach { id in
            Task { await SSHTunnelService.shared.close(profileID: id) }
        }
        bookmarks.remove(atOffsets: offsets)
        persist()
    }

    func bookmark(with id: UUID?) -> ConnectionProfile? {
        guard let id else { return bookmarks.first }
        return bookmarks.first(where: { $0.id == id })
    }

    private func load() {
        var importedURI = false
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([ConnectionProfile].self, from: data) {
            importedURI = decoded.contains { $0.host.hasPrefix("mongodb://") || $0.host.hasPrefix("mongodb+srv://") }
            bookmarks = normalized(decoded).map { secure($0) }
        } else {
            bookmarks = []
        }
        mergeFromCloud()
        if importedURI { persist() }
    }

    private func persist() {
        bookmarks = normalized(bookmarks)
        guard let data = try? encoder.encode(bookmarks) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        guard cloudSyncEnabled else { return }
        profileCloudCollection?.save(bookmarks)
        profileCloudCollection?.noteLegacySnapshot(bookmarks)
        if WorkspaceCloudQuota.canStore(data, forKey: syncKey, in: keyValueStore) {
            keyValueStore.set(data, forKey: syncKey)
            keyValueStore.synchronize()
            cloudSyncError = profileCloudCollection?.errorMessage
        } else { cloudSyncError = L10n.text("Connections are saved on this device. The library exceeds the iCloud sync limit.") }
        objectWillChange.send()
    }

    func synchronizeCloud() {
        guard cloudSyncEnabled else { return }
        keyValueStore.synchronize()
        mergeFromCloud()
    }

    private func mergeFromCloud() {
        guard cloudSyncEnabled else { return }
        if let profileCloudCollection {
            guard profileCloudCollection.mergeCloud() != nil else { cloudSyncError = profileCloudCollection.errorMessage; return }
            let legacy = keyValueStore.data(forKey: syncKey).flatMap { try? decoder.decode([ConnectionProfile].self, from: $0) }
            let values = legacy.map { profileCloudCollection.ingestLegacy(normalized($0).map { secure($0) }, initialDate: { $0.createdAt }) }
                ?? profileCloudCollection.state.values
            let merged = normalized(values).map { secure($0) }
            if merged != bookmarks {
                bookmarks = merged
                if let payload = try? encoder.encode(bookmarks) { try? payload.write(to: fileURL, options: [.atomic]) }
            }
            cloudSyncError = profileCloudCollection.errorMessage
            return
        }
        guard let data = keyValueStore.data(forKey: syncKey),
              let remote = try? decoder.decode([ConnectionProfile].self, from: data) else {
            return
        }
        let ordered = normalized(bookmarks + remote).map { secure($0) }
        let importedURI = remote.contains { $0.host.hasPrefix("mongodb://") || $0.host.hasPrefix("mongodb+srv://") }
        if ordered != bookmarks || importedURI {
            bookmarks = ordered
            if let payload = try? encoder.encode(bookmarks) {
                try? payload.write(to: fileURL, options: [.atomic])
                if importedURI {
                    keyValueStore.set(payload, forKey: syncKey)
                    keyValueStore.synchronize()
                }
            }
            objectWillChange.send()
        }
    }

    private func normalized(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        var mergedByID: [UUID: ConnectionProfile] = [:]
        for profile in profiles {
            mergedByID[profile.id] = profile
        }
        // Newest first; equal timestamps (imports, duplicates) fall back to name and ID so the order is stable.
        return mergedByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            let names = lhs.name.localizedStandardCompare(rhs.name)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func secure(_ profile: ConnectionProfile, persistPrivateCAInput: Bool = false) -> ConnectionProfile {
        var secured = profile
        if profile.host.hasPrefix("mongodb://") || profile.host.hasPrefix("mongodb+srv://"),
           let parsed = try? MongoConnectionURI.parse(profile.host) {
            secured = parsed.applying(to: profile)
        }

        if !secured.password.isEmpty || secured.passwordWasExplicitlySet {
            KeychainService.setPassword(secured.password, for: secured.id)
        }
        secured.passwordWasExplicitlySet = false
        secured.password = KeychainService.password(for: secured.id)

        if !secured.sshPassword.isEmpty {
            KeychainService.setSecret(secured.sshPassword, kind: .sshPassword, for: secured.id)
        }
        secured.sshPassword = KeychainService.secret(.sshPassword, for: secured.id)

        if !secured.sshPrivateKey.isEmpty, secured.sshPrivateKey != "<keychain>" {
            KeychainService.setSecret(secured.sshPrivateKey, kind: .sshPrivateKey, for: secured.id)
        }
        secured.sshPrivateKey = KeychainService.secret(.sshPrivateKey, for: secured.id)

        if !secured.sshPassphrase.isEmpty {
            KeychainService.setSecret(secured.sshPassphrase, kind: .sshPassphrase, for: secured.id)
        }
        secured.sshPassphrase = KeychainService.secret(.sshPassphrase, for: secured.id)

        if persistPrivateCAInput {
            if secured.privateCACertificate.isEmpty {
                KeychainService.deleteSecret(.privateCACertificate, for: secured.id)
            } else if secured.privateCACertificate != "<keychain>" {
                KeychainService.setSecret(secured.privateCACertificate, kind: .privateCACertificate, for: secured.id)
            }
        } else if !secured.privateCACertificate.isEmpty, secured.privateCACertificate != "<keychain>" {
            KeychainService.setSecret(secured.privateCACertificate, kind: .privateCACertificate, for: secured.id)
        }
        secured.privateCACertificate = KeychainService.secret(.privateCACertificate, for: secured.id)

        return secured
    }
}
