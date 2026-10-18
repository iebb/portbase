import CryptoKit
import Foundation

enum CloudEncryptionError: Error, Equatable {
    case noKey
    case unrecognizedFormat
    case wrongKeyOrDamaged
}

/// Encrypts data Portbase keeps in iCloud Drive, so someone who can read the iCloud Drive folder sees
/// only ciphertext. The 256-bit key lives in iCloud Keychain, which syncs it end-to-end encrypted to
/// the user's devices and suits a secret this small; the encrypted data itself can be any size.
enum CloudEncryption {
    static let keyName = "cloud-data-key"
    /// Marks the format so a later version can change it: "PBE1" then AES-GCM's nonce, ciphertext, and tag.
    private static let magic = Data("PBE1".utf8)

    /// The key from iCloud Keychain, created on first use. Before creating one, the Keychain is checked
    /// again, so a key another device already synced is used rather than replaced.
    static func key(creatingIfMissing: Bool = true) -> SymmetricKey? {
        if let existing = storedKey() { return existing }
        guard creatingIfMissing else { return nil }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        guard KeychainService.setSyncedAppSecret(encoded, for: keyName) else { return nil }
        return storedKey() ?? key
    }

    private static func storedKey() -> SymmetricKey? {
        let stored = KeychainService.syncedAppSecret(keyName)
        guard let data = Data(base64Encoded: stored), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CloudEncryptionError.unrecognizedFormat }
        return magic + combined
    }

    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.count > magic.count, sealed.prefix(magic.count) == magic else { throw CloudEncryptionError.unrecognizedFormat }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.dropFirst(magic.count)), using: key)
        } catch {
            throw CloudEncryptionError.wrongKeyOrDamaged
        }
    }

    static func seal(_ plaintext: Data) throws -> Data {
        guard let key = key() else { throw CloudEncryptionError.noKey }
        return try seal(plaintext, key: key)
    }

    static func open(_ sealed: Data) throws -> Data {
        guard let key = key(creatingIfMissing: false) else { throw CloudEncryptionError.noKey }
        return try open(sealed, key: key)
    }
}
