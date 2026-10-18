import XCTest
@testable import PortSQL

/// Each test runs as two devices would see one connection's secrets: this device's copy and the
/// iCloud Keychain copy another device can change.
final class ConnectionSecretSyncTests: XCTestCase {
    private let profileID = UUID()
    private var savedSetting: Any?

    override func setUp() {
        super.setUp()
        savedSetting = UserDefaults.standard.object(forKey: KeychainService.syncsConnectionSecretsKey)
    }

    override func tearDown() {
        KeychainService.deleteAllSecrets(for: profileID)
        UserDefaults.standard.set(savedSetting, forKey: KeychainService.syncsConnectionSecretsKey)
        super.tearDown()
    }

    private func setSyncing(_ on: Bool) { UserDefaults.standard.set(on, forKey: KeychainService.syncsConnectionSecretsKey) }

    func testSyncingIsOnUnlessTurnedOff() {
        UserDefaults.standard.removeObject(forKey: KeychainService.syncsConnectionSecretsKey)
        XCTAssertTrue(KeychainService.syncsConnectionSecrets)
    }

    func testASecretSavedWhileSyncingIsKeptInBothPlaces() {
        setSyncing(true)
        KeychainService.setPassword("hunter2", for: profileID)
        setSyncing(false)
        XCTAssertEqual(KeychainService.password(for: profileID), "hunter2", "This device keeps its own copy")
        KeychainService.setSyncsConnectionSecrets(false, removingFromICloud: true)
        XCTAssertEqual(KeychainService.password(for: profileID), "hunter2", "Removing from iCloud keeps this device's copy")
    }

    func testAChangeFromAnotherDeviceWinsAndUpdatesThisDevicesCopy() {
        setSyncing(false)
        KeychainService.setPassword("old", for: profileID)
        setSyncing(true)
        KeychainService.setPassword("new", for: profileID)  // as another device would write iCloud's copy
        setSyncing(false)
        XCTAssertEqual(KeychainService.password(for: profileID), "new")
    }

    func testWhileOffThisDeviceNeitherReadsNorWritesICloud() {
        setSyncing(true)
        KeychainService.setPassword("synced", for: profileID)
        setSyncing(false)
        KeychainService.setPassword("local", for: profileID)
        XCTAssertEqual(KeychainService.password(for: profileID), "local")
        setSyncing(true)
        XCTAssertEqual(KeychainService.password(for: profileID), "synced", "iCloud's copy wasn't touched while off")
    }

    func testAClearedSecretStaysClearedOnDevicesThatKeptACopy() {
        setSyncing(true)
        KeychainService.setPassword("secret", for: profileID)
        XCTAssertEqual(KeychainService.storedSecret(.databasePassword, for: profileID), "secret")
        KeychainService.setPassword("", for: profileID)
        XCTAssertEqual(KeychainService.storedSecret(.databasePassword, for: profileID), "", "Cleared, not missing")
        KeychainService.uploadMissingConnectionSecrets()
        XCTAssertEqual(KeychainService.password(for: profileID), "")
    }

    func testTurningSyncingOnUploadsOnlyWhatICloudLacks() {
        let other = UUID()
        defer { KeychainService.deleteAllSecrets(for: other) }
        setSyncing(true)
        KeychainService.setSecret("cloud-key", kind: .sshPrivateKey, for: profileID)
        setSyncing(false)
        KeychainService.setSecret("stale-key", kind: .sshPrivateKey, for: profileID)
        KeychainService.setSecret("device-only", kind: .sshPassword, for: other)

        KeychainService.setSyncsConnectionSecrets(true)
        XCTAssertEqual(KeychainService.secret(.sshPrivateKey, for: profileID), "cloud-key", "iCloud's copy isn't overwritten")
        KeychainService.deleteLocalSecrets(for: other)
        XCTAssertEqual(KeychainService.secret(.sshPassword, for: other), "device-only", "The missing secret was uploaded")
    }

    func testDeletingAConnectionRemovesItsSecretsEverywhere() {
        setSyncing(true)
        KeychainService.setPassword("secret", for: profileID)
        KeychainService.deleteAllSecrets(for: profileID)
        XCTAssertNil(KeychainService.storedSecret(.databasePassword, for: profileID))
        setSyncing(false)
        XCTAssertNil(KeychainService.storedSecret(.databasePassword, for: profileID))
    }

    func testOnlyConnectionAccountsAreSyncedOrRemoved() {
        XCTAssertTrue(KeychainService.isConnectionAccount(UUID().uuidString + ".databasePassword"))
        XCTAssertFalse(KeychainService.isConnectionAccount("app.synced.cloud-data-key"))
        XCTAssertFalse(KeychainService.isConnectionAccount(UUID().uuidString + ".unknown"))
    }
}
