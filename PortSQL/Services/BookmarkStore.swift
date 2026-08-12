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

    func upsert(_ profile: ConnectionProfile) {
        let secured = secure(profile, persistPrivateCAInput: true)
        if let index = bookmarks.firstIndex(where: { $0.id == secured.id }) {
            Task { await SSHTunnelService.shared.close(profileID: secured.id) }
            bookmarks[index] = secured
        } else {
            bookmarks.insert(secured, at: 0)
        }
        persist()
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
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([ConnectionProfile].self, from: data) {
            bookmarks = normalized(decoded).map { secure($0) }
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
        let ordered = normalized(bookmarks + remote).map { secure($0) }
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

    private func secure(_ profile: ConnectionProfile, persistPrivateCAInput: Bool = false) -> ConnectionProfile {
        var secured = profile

        if !secured.password.isEmpty {
            KeychainService.setPassword(secured.password, for: secured.id)
        }
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
