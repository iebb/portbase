import Foundation
import Observation

@MainActor
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [ConnectionProfile] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var cloudSyncError: String?
    /// Connections with a password, key, or trusted host key that changed on more than one device at once.
    @Published private(set) var syncConflicts: Set<UUID> = []

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
            // Secrets changed here or on other devices since the last launch come into agreement.
            KeychainService.reconcileConnectionSecrets()
        }
        removeLegacySampleConnections()
        refreshSyncConflicts()
        NotificationCenter.default.addObserver(
            forName: .syncConflictsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSyncConflicts() }
        }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mergeFromCloud()
                self?.removeLegacySampleConnections()
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
        let secured = secure(profile, fromEditor: true)
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

    /// Whether a connection is one of the sample connections older builds created on first launch.
    /// The match is exact (name, engine, and the samples' own port, database, or file), so a connection the
    /// user made is never mistaken for one.
    static func isLegacySampleConnection(_ profile: ConnectionProfile) -> Bool {
        switch (profile.name, profile.engine) {
        case ("Sample Redis", .redis):
            return profile.host == "127.0.0.1" && profile.port == 26379
        case ("Sample MongoDB", .mongodb):
            return profile.host == "127.0.0.1" && profile.port == 27019 && profile.defaultDatabase == "portbase_demo"
        case ("Sample Database", .sqlite):
            return profile.sqliteFileName?.hasPrefix("Portbase_Sample-") == true
        default:
            return false
        }
    }

    /// Removes leftover sample connections, including any that sync back from an older device. The sample
    /// SQLite file stays in place: local database files are only deleted explicitly.
    func removeLegacySampleConnections() {
        let offsets = IndexSet(bookmarks.indices.filter { Self.isLegacySampleConnection(bookmarks[$0]) })
        guard !offsets.isEmpty else { return }
        delete(at: offsets)
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
        KeychainService.reconcileConnectionSecrets()
        refreshSecrets()
    }

    private func mergeFromCloud() {
        guard cloudSyncEnabled else { return }
        if let profileCloudCollection {
            guard profileCloudCollection.mergeCloud() != nil else { cloudSyncError = profileCloudCollection.errorMessage; return }
            let legacy = keyValueStore.data(forKey: syncKey).flatMap { try? decoder.decode([ConnectionProfile].self, from: $0) }
            let values = legacy.map { profileCloudCollection.ingestLegacy(normalized($0).map { secure($0) }, initialDate: { $0.createdAt }) }
                ?? profileCloudCollection.state.values
            let merged = normalized(values).map { secure($0) }
            // A connection deleted on another device takes this device's copies of its secrets with it.
            let mergedIDs = Set(merged.map(\.id))
            bookmarks.filter { !mergedIDs.contains($0.id) }.forEach { KeychainService.deleteLocalSecrets(for: $0.id) }
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

    /// Saves a profile's secrets to Keychain and fills it with what Keychain holds. Secrets typed in the
    /// editor are saved as given. Ones that come from storage, such as plaintext in old bookmark data or a
    /// profile already filled in memory, only fill an empty Keychain slot: syncing devices may have
    /// changed or cleared the secret since, and an old copy must not overwrite that.
    private func secure(_ profile: ConnectionProfile, fromEditor: Bool = false) -> ConnectionProfile {
        var secured = profile
        if profile.host.hasPrefix("mongodb://") || profile.host.hasPrefix("mongodb+srv://"),
           let parsed = try? MongoConnectionURI.parse(profile.host) {
            secured = parsed.applying(to: profile)
        }

        func save(_ value: String, _ kind: KeychainService.SecretKind, clears: Bool = false) -> String {
            let given = value == "<keychain>" ? "" : value
            if fromEditor {
                if !given.isEmpty || clears { KeychainService.setSecret(given, kind: kind, for: secured.id) }
            } else if !given.isEmpty, KeychainService.storedSecret(kind, for: secured.id) == nil {
                KeychainService.setSecret(given, kind: kind, for: secured.id)
            }
            return KeychainService.secret(kind, for: secured.id)
        }

        secured.password = save(secured.password, .databasePassword, clears: secured.passwordWasExplicitlySet)
        secured.passwordWasExplicitlySet = false
        secured.sshPassword = save(secured.sshPassword, .sshPassword)
        secured.sshPrivateKey = save(secured.sshPrivateKey, .sshPrivateKey)
        secured.sshPassphrase = save(secured.sshPassphrase, .sshPassphrase)
        // The editor clears the certificate by emptying it; "<keychain>" keeps the saved one.
        secured.privateCACertificate = save(secured.privateCACertificate, .privateCACertificate,
                                            clears: secured.privateCACertificate.isEmpty)
        return secured
    }

    /// Fills the profiles again from Keychain, after syncing is turned on or off, or when secrets
    /// may have arrived from iCloud Keychain.
    func refreshSecrets() {
        let refreshed = bookmarks.map { secure($0) }
        if refreshed != bookmarks { bookmarks = refreshed }
        refreshSyncConflicts()
    }

    func refreshSyncConflicts() {
        let secrets = KeychainService.conflictedProfileIDs()
        let hostKeys = bookmarks.filter { profile in
            profile.usesSSHTunnel && SSHTunnelSyncingHostKeyStore.shared.conflict(
                for: SSHTunnelSyncingHostKeyStore.storeKey(host: profile.sshHost, port: profile.sshPort)) != nil
        }.map(\.id)
        let conflicts = secrets.union(hostKeys).intersection(bookmarks.map(\.id))
        if conflicts != syncConflicts { syncConflicts = conflicts }
    }
}
