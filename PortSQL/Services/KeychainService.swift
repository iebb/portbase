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
    /// iCloud Keychain, which syncs it end-to-end encrypted to the user's other devices, and the iCloud
    /// copy wins when the two differ, since another device may have changed it.
    static let syncsConnectionSecretsKey = "Portbase.syncConnectionSecrets"

    /// Whether this device syncs connection secrets through iCloud Keychain. On unless turned off.
    static var syncsConnectionSecrets: Bool {
        UserDefaults.standard.object(forKey: syncsConnectionSecretsKey) as? Bool ?? true
    }

    /// Turning syncing on sends this device's secrets that iCloud Keychain doesn't have yet. Turning it
    /// off stops using iCloud Keychain here; the copies there stay for other devices unless removed.
    static func setSyncsConnectionSecrets(_ enabled: Bool, removingFromICloud: Bool = false) {
        UserDefaults.standard.set(enabled, forKey: syncsConnectionSecretsKey)
        if enabled {
            uploadMissingConnectionSecrets()
        } else if removingFromICloud {
            removeConnectionSecretsFromICloud()
        }
    }

    /// Sends this device's secrets that iCloud Keychain doesn't have yet, such as those saved before
    /// syncing existed or while it was off. A secret already in iCloud Keychain is newer or the same.
    static func uploadMissingConnectionSecrets() {
        guard syncsConnectionSecrets else { return }
        for account in connectionAccounts(synced: false) where item(account, synced: true) == nil {
            if let value = item(account, synced: false) { _ = setItem(value, account: account, synced: true) }
        }
    }

    /// Deletes every connection secret from iCloud Keychain, and so from other devices' iCloud copies.
    /// Each device keeps its own copy.
    static func removeConnectionSecretsFromICloud() {
        connectionAccounts(synced: true).forEach { deleteItem($0, synced: true) }
    }

    static func password(for profileID: UUID) -> String {
        secret(.databasePassword, for: profileID)
    }

    static func secret(_ kind: SecretKind, for profileID: UUID) -> String {
        storedSecret(kind, for: profileID) ?? ""
    }

    /// The secret, an empty string when it was cleared on a syncing device, or nil when none was ever saved.
    static func storedSecret(_ kind: SecretKind, for profileID: UUID) -> String? {
        let account = account(profileID, kind: kind)
        let local = item(account, synced: false)
        guard syncsConnectionSecrets, let synced = item(account, synced: true) else { return local }
        let value = synced == clearedMarker ? "" : synced
        // Keeping this device's copy current means turning syncing off, or removing secrets from iCloud, keeps them.
        if value != (local ?? "") {
            if value.isEmpty { deleteItem(account, synced: false) } else { _ = setItem(value, account: account, synced: false) }
        }
        return value
    }

    static func setPassword(_ password: String, for profileID: UUID) {
        setSecret(password, kind: .databasePassword, for: profileID)
    }

    /// Saves a secret, or clears it when empty. A cleared secret leaves a marker in iCloud Keychain, so other
    /// devices clear theirs instead of using, or sending back, the copy they kept.
    static func setSecret(_ secret: String, kind: SecretKind, for profileID: UUID) {
        let account = account(profileID, kind: kind)
        if secret.isEmpty {
            deleteItem(account, synced: false)
        } else {
            _ = setItem(secret, account: account, synced: false)
        }
        if syncsConnectionSecrets {
            _ = setItem(secret.isEmpty ? clearedMarker : secret, account: account, synced: true)
        }
    }

    static func deletePassword(for profileID: UUID) {
        deleteSecret(.databasePassword, for: profileID)
    }

    /// Removes a deleted connection's secrets from this device and from iCloud Keychain.
    static func deleteAllSecrets(for profileID: UUID) {
        for kind in SecretKind.allCases {
            let account = account(profileID, kind: kind)
            deleteItem(account, synced: false)
            deleteItem(account, synced: true)
        }
    }

    /// Removes this device's copies of a connection's secrets, for a connection deleted on another device.
    static func deleteLocalSecrets(for profileID: UUID) {
        SecretKind.allCases.forEach { deleteItem(account(profileID, kind: $0), synced: false) }
    }

    static func deleteSecret(_ kind: SecretKind, for profileID: UUID) {
        setSecret("", kind: kind, for: profileID)
    }

    /// Stands for a secret cleared on a syncing device. Not a value anyone types: it starts with a control character.
    private static let clearedMarker = "\u{1}portbase.cleared"

    private static func item(_ account: String, synced: Bool) -> String? {
        var query = synced ? syncedQuery(account: account) : baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
#if DEBUG
            return fallbackStore.optionalValue(for: fallbackKey(account, synced: synced))
#else
            return nil
#endif
        }
        return value
    }

    @discardableResult
    private static func setItem(_ value: String, account: String, synced: Bool) -> Bool {
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

    private static func deleteItem(_ account: String, synced: Bool) {
        SecItemDelete((synced ? syncedQuery(account: account) : baseQuery(account: account)) as CFDictionary)
#if DEBUG
        fallbackStore.removeValue(for: fallbackKey(account, synced: synced))
#endif
    }

    /// The accounts of connection secrets, whose names are a connection ID and a kind; app secrets are skipped.
    private static func connectionAccounts(synced: Bool) -> [String] {
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
        return Array(Set(accounts.filter(isConnectionAccount))).sorted()
    }

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
