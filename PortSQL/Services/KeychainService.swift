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

    static func password(for profileID: UUID) -> String {
        secret(.databasePassword, for: profileID)
    }

    static func secret(_ kind: SecretKind, for profileID: UUID) -> String {
        var query = baseQuery(account: account(profileID, kind: kind))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
#if DEBUG
            return fallbackStore.value(for: account(profileID, kind: kind))
#else
            return ""
#endif
        }
        return password
    }

    static func setPassword(_ password: String, for profileID: UUID) {
        setSecret(password, kind: .databasePassword, for: profileID)
    }

    static func setSecret(_ secret: String, kind: SecretKind, for profileID: UUID) {
        let account = account(profileID, kind: kind)
        guard !secret.isEmpty else {
            deleteSecret(kind, for: profileID)
            return
        }

        let data = Data(secret.utf8)
        var query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        var writeStatus = status
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            writeStatus = SecItemAdd(query as CFDictionary, nil)
        }
#if DEBUG
        if writeStatus != errSecSuccess {
            fallbackStore.set(secret, for: account)
        }
#endif
    }

    static func deletePassword(for profileID: UUID) {
        deleteSecret(.databasePassword, for: profileID)
    }

    static func deleteAllSecrets(for profileID: UUID) {
        SecretKind.allCases.forEach { deleteSecret($0, for: profileID) }
    }

    static func deleteSecret(_ kind: SecretKind, for profileID: UUID) {
        let account = account(profileID, kind: kind)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
#if DEBUG
        fallbackStore.removeValue(for: account)
#endif
    }

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
        lock.lock()
        defer { lock.unlock() }
        return values[account] ?? ""
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
