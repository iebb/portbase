import Foundation
import Security

enum KeychainService {
    private static let service = "ad.neko.portsql.connection-secret"
#if DEBUG
    private static let fallbackStore = KeychainFallbackStore()
#endif

    enum SecretKind: String {
        case databasePassword
        case sshPassword
        case sshPrivateKey
        case sshPassphrase
        case privateCACertificate
    }

    // MARK: Connection secrets

    /// Connection secrets always keep a copy on this device. While syncing is on, each one also lives in
    /// iCloud Keychain, which syncs it end-to-end encrypted to the user's other devices. The two copies
    /// are reconciled as `SyncedSlot` describes: a change on one side is taken over, and when both sides
    /// changed, the later change wins and the other value is kept as a conflict to review.
    static let syncsConnectionSecretsKey = "Portbase.syncConnectionSecrets"

    /// Whether this device syncs connection secrets through iCloud Keychain. On unless turned off.
    static var syncsConnectionSecrets: Bool {
        UserDefaults.standard.object(forKey: syncsConnectionSecretsKey) as? Bool ?? true
    }

    /// Turning syncing on reconciles every secret with iCloud Keychain. Turning it off stops using iCloud
    /// Keychain here; the copies there stay for other devices unless removed.
    static func setSyncsConnectionSecrets(_ enabled: Bool, removingFromICloud: Bool = false) {
        UserDefaults.standard.set(enabled, forKey: syncsConnectionSecretsKey)
        if enabled {
            reconcileConnectionSecrets()
        } else if removingFromICloud {
            removeConnectionSecretsFromICloud()
        }
    }

    /// Brings every connection secret on this device and in iCloud Keychain into agreement: this device's
    /// changes go up, other devices' come down, and secrets changed on both are resolved.
    static func reconcileConnectionSecrets() {
        guard syncsConnectionSecrets else { return }
        let local = accounts(synced: false).filter(isConnectionAccount)
        let remote = accounts(synced: true).compactMap(SyncedSlot.baseAccount).filter(isConnectionAccount)
        for account in Set(local).union(remote) { _ = slot(account).reconcile() }
    }

    /// Deletes every connection secret from iCloud Keychain, and so from other devices' iCloud copies.
    /// Each device keeps its own copy.
    static func removeConnectionSecretsFromICloud() {
        for account in accounts(synced: true) {
            guard let base = SyncedSlot.baseAccount(account), isConnectionAccount(base) else { continue }
            slot(base).removeRemote()
        }
    }

    static func password(for profileID: UUID) -> String {
        secret(.databasePassword, for: profileID)
    }

    static func secret(_ kind: SecretKind, for profileID: UUID) -> String {
        storedSecret(kind, for: profileID) ?? ""
    }

    /// The secret, an empty string when it was cleared, or nil when none was ever saved.
    static func storedSecret(_ kind: SecretKind, for profileID: UUID) -> String? {
        let slot = slot(account(profileID, kind: kind))
        return syncsConnectionSecrets ? slot.reconcile() : slot.localValue()
    }

    static func setPassword(_ password: String, for profileID: UUID) {
        setSecret(password, kind: .databasePassword, for: profileID)
    }

    /// Saves a secret, or clears it when empty. While syncing, the change goes to iCloud Keychain as the
    /// newest version; a cleared secret is a version too, so other devices clear theirs rather than send
    /// back the copy they kept. Saving settles any conflict the secret had.
    static func setSecret(_ secret: String, kind: SecretKind, for profileID: UUID) {
        slot(account(profileID, kind: kind)).write(secret.isEmpty ? nil : secret, syncing: syncsConnectionSecrets)
    }

    static func deletePassword(for profileID: UUID) {
        deleteSecret(.databasePassword, for: profileID)
    }

    /// Removes a deleted connection's secrets from this device and from iCloud Keychain.
    static func deleteAllSecrets(for profileID: UUID) {
        SecretKind.allCases.forEach { slot(account(profileID, kind: $0)).removeEverywhere() }
    }

    /// Removes this device's copies of a connection's secrets, for a connection deleted on another device.
    static func deleteLocalSecrets(for profileID: UUID) {
        SecretKind.allCases.forEach { slot(account(profileID, kind: $0)).removeLocal() }
    }

    static func deleteSecret(_ kind: SecretKind, for profileID: UUID) {
        setSecret("", kind: kind, for: profileID)
    }

    /// The values another device saved for a connection's secrets that lost to a later change here, or
    /// that a later change elsewhere replaced here.
    static func conflicts(for profileID: UUID) -> [SecretKind: SyncedVersion] {
        var conflicts: [SecretKind: SyncedVersion] = [:]
        for kind in SecretKind.allCases {
            if let conflict = slot(account(profileID, kind: kind)).conflict() { conflicts[kind] = conflict }
        }
        return conflicts
    }

    /// The connections with a secret conflict to review.
    static func conflictedProfileIDs() -> Set<UUID> {
        Set(accounts(synced: false).compactMap { account -> UUID? in
            guard account.hasSuffix(SyncedSlot.conflictSuffix) else { return nil }
            let base = String(account.dropLast(SyncedSlot.conflictSuffix.count))
            return isConnectionAccount(base) ? UUID(uuidString: String(base.prefix(36))) : nil
        })
    }

    /// Settles a conflict by keeping the current secret, or by using the other value as a new change.
    static func resolveConflict(_ kind: SecretKind, for profileID: UUID, usingOther: Bool) {
        let slot = slot(account(profileID, kind: kind))
        guard let conflict = slot.conflict() else { return }
        if usingOther {
            slot.write(conflict.value, syncing: syncsConnectionSecrets)
        } else {
            slot.dismissConflict()
        }
    }

    private static func slot(_ account: String) -> SyncedSlot {
        SyncedSlot(account: account, policy: .laterChangeWins,
                   readLocal: { record(account, synced: false) },
                   writeLocal: { value in
                       if let value { setItem(value, account: account, synced: false) } else { deleteItem(account, synced: false) }
                   })
    }

    // MARK: Items

    /// An item's value and when Keychain last saw it change.
    static func record(_ account: String, synced: Bool) -> (value: String, modified: Date?)? {
        var query = synced ? syncedQuery(account: account) : baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
#if DEBUG
            return fallbackStore.optionalValue(for: fallbackKey(account, synced: synced)).map { ($0, nil) }
#else
            return nil
#endif
        }
        return (value, attributes[kSecAttrModificationDate as String] as? Date)
    }

    @discardableResult
    static func setItem(_ value: String, account: String, synced: Bool) -> Bool {
        let data = Data(value.utf8)
        var query = synced ? syncedQuery(account: account) : baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            // iCloud Keychain only syncs items every device can unlock, so not "this device only".
            query[kSecAttrAccessible as String] = synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
#if DEBUG
        if status != errSecSuccess { fallbackStore.set(value, for: fallbackKey(account, synced: synced)); return true }
#endif
        return status == errSecSuccess
    }

    static func deleteItem(_ account: String, synced: Bool) {
        SecItemDelete((synced ? syncedQuery(account: account) : baseQuery(account: account)) as CFDictionary)
#if DEBUG
        fallbackStore.removeValue(for: fallbackKey(account, synced: synced))
#endif
    }

    /// Every account saved under this app's service, on this device or in iCloud Keychain.
    static func accounts(synced: Bool) -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synced ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        var result: AnyObject?
        var accounts = [String]()
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] {
            accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        }
#if DEBUG
        let prefix = synced ? "synced:" : "local:"
        accounts += fallbackStore.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
#endif
        return Array(Set(accounts)).sorted()
    }

    /// A connection secret's account: a connection ID and a kind.
    static func isConnectionAccount(_ account: String) -> Bool {
        let parts = account.split(separator: ".", maxSplits: 1).map(String.init)
        return parts.count == 2 && UUID(uuidString: parts[0]) != nil && SecretKind(rawValue: parts[1]) != nil
    }

#if DEBUG
    private static func fallbackKey(_ account: String, synced: Bool) -> String { (synced ? "synced:" : "local:") + account }
#endif

    /// A secret that belongs to the app rather than a connection, such as the AI provider's API key.
    static func appSecret(_ name: String) -> String {
        var query = baseQuery(account: "app." + name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
#if DEBUG
            return fallbackStore.value(for: "app." + name)
#else
            return ""
#endif
        }
        return value
    }

    static func setAppSecret(_ secret: String, for name: String) {
        let account = "app." + name
        guard !secret.isEmpty else {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
#if DEBUG
            fallbackStore.removeValue(for: account)
#endif
            return
        }
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
#if DEBUG
        if status != errSecSuccess { fallbackStore.set(secret, for: account) }
#endif
    }

    /// An app secret kept in iCloud Keychain, which syncs it end-to-end encrypted to the user's other
    /// devices, such as AI provider keys and the key for encrypted iCloud Drive files.
    static func syncedAppSecret(_ name: String) -> String {
        var query = syncedQuery(account: "app.synced." + name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
#if DEBUG
            return fallbackStore.value(for: "app.synced." + name)
#else
            return ""
#endif
        }
        return value
    }

    /// Saves or, when empty, removes a synced app secret. Returns whether the Keychain took it.
    @discardableResult
    static func setSyncedAppSecret(_ secret: String, for name: String) -> Bool {
        let account = "app.synced." + name
        guard !secret.isEmpty else {
            SecItemDelete(syncedQuery(account: account) as CFDictionary)
#if DEBUG
            fallbackStore.removeValue(for: account)
#endif
            return true
        }
        let data = Data(secret.utf8)
        var query = syncedQuery(account: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            // Not "this device only": iCloud Keychain only syncs items every device can unlock.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
#if DEBUG
        if status != errSecSuccess { fallbackStore.set(secret, for: account); return true }
#endif
        return status == errSecSuccess
    }

    private static func syncedQuery(account: String) -> [String: Any] {
        var query = baseQuery(account: account)
        query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        return query
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
#if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    private static func account(_ profileID: UUID, kind: SecretKind) -> String {
        "\(profileID.uuidString).\(kind.rawValue)"
    }
}

extension KeychainService.SecretKind: CaseIterable {}

#if DEBUG
private final class KeychainFallbackStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for account: String) -> String {
        optionalValue(for: account) ?? ""
    }

    func optionalValue(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.keys)
    }

    func set(_ value: String, for account: String) {
        lock.lock()
        values[account] = value
        lock.unlock()
    }

    func removeValue(for account: String) {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}
#endif
