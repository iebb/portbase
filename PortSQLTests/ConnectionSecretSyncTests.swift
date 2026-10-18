import XCTest
@testable import PortSQL

/// Each test plays two devices: this one, through KeychainService, and another that writes the
/// iCloud Keychain copy directly, as its own Portbase would.
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
    private var account: String { profileID.uuidString + "." + KeychainService.SecretKind.databasePassword.rawValue }

    /// Writes the iCloud copy as another device would.
    private func otherDeviceSaves(_ value: String?, at date: Date) throws {
        let version = SyncedVersion(value: value, modified: date, device: "OTHER", deviceName: "Other iPad")
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(version), encoding: .utf8))
        KeychainService.setItem(text, account: account + SyncedSlot.remoteSuffix, synced: true)
    }

    private func iCloudCopy() -> SyncedVersion? {
        KeychainService.record(account + SyncedSlot.remoteSuffix, synced: true)
            .flatMap { try? JSONDecoder().decode(SyncedVersion.self, from: Data($0.value.utf8)) }
    }

    /// Lets the clock move, so changes made one after another have different dates.
    private func tick() { Thread.sleep(forTimeInterval: 0.01) }

    func testSyncingIsOnUnlessTurnedOff() {
        UserDefaults.standard.removeObject(forKey: KeychainService.syncsConnectionSecretsKey)
        XCTAssertTrue(KeychainService.syncsConnectionSecrets)
    }

    func testASecretSavedWhileSyncingIsKeptInBothPlaces() {
        setSyncing(true)
        KeychainService.setPassword("hunter2", for: profileID)
        XCTAssertEqual(iCloudCopy()?.value, "hunter2")
        XCTAssertEqual(iCloudCopy()?.device, SyncDevice.id)
        KeychainService.setSyncsConnectionSecrets(false, removingFromICloud: true)
        XCTAssertNil(iCloudCopy())
        XCTAssertEqual(KeychainService.password(for: profileID), "hunter2", "Removing from iCloud keeps this device's copy")
    }

    func testAChangeOnlyAnotherDeviceMadeIsTakenWithoutAConflict() throws {
        setSyncing(true)
        KeychainService.setPassword("old", for: profileID)
        try otherDeviceSaves("new", at: Date().addingTimeInterval(60))
        XCTAssertEqual(KeychainService.password(for: profileID), "new")
        XCTAssertTrue(KeychainService.conflicts(for: profileID).isEmpty)
        setSyncing(false)
        XCTAssertEqual(KeychainService.password(for: profileID), "new", "This device's copy follows")
    }

    func testAChangeOnlyThisDeviceMadeGoesUpWhenSyncingResumes() {
        setSyncing(true)
        KeychainService.setPassword("synced", for: profileID)
        setSyncing(false)
        tick()
        KeychainService.setPassword("offline edit", for: profileID)
        XCTAssertEqual(iCloudCopy()?.value, "synced", "iCloud isn't touched while syncing is off")
        KeychainService.setSyncsConnectionSecrets(true)
        XCTAssertEqual(iCloudCopy()?.value, "offline edit")
        XCTAssertTrue(KeychainService.conflicts(for: profileID).isEmpty)
    }

    func testWhenBothChangedTheLaterWinsAndTheOtherIsKeptToReview() throws {
        setSyncing(true)
        KeychainService.setPassword("base", for: profileID)
        setSyncing(false)
        tick()
        KeychainService.setPassword("mine", for: profileID)
        try otherDeviceSaves("theirs", at: Date().addingTimeInterval(60))

        KeychainService.setSyncsConnectionSecrets(true)
        XCTAssertEqual(KeychainService.password(for: profileID), "theirs")
        let conflict = try XCTUnwrap(KeychainService.conflicts(for: profileID)[.databasePassword])
        XCTAssertEqual(conflict.value, "mine")
        XCTAssertEqual(conflict.device, SyncDevice.id)
        XCTAssertTrue(KeychainService.conflictedProfileIDs().contains(profileID))

        KeychainService.resolveConflict(.databasePassword, for: profileID, usingOther: true)
        XCTAssertEqual(KeychainService.password(for: profileID), "mine")
        XCTAssertEqual(iCloudCopy()?.value, "mine", "The choice is the newest change everywhere")
        XCTAssertTrue(KeychainService.conflicts(for: profileID).isEmpty)
        XCTAssertFalse(KeychainService.conflictedProfileIDs().contains(profileID))
    }

    func testWhenThisDeviceChangedLastItWinsAndTheOtherDevicesValueIsKept() throws {
        setSyncing(true)
        KeychainService.setPassword("base", for: profileID)
        try otherDeviceSaves("theirs", at: Date().addingTimeInterval(-30))
        setSyncing(false)
        tick()
        KeychainService.setPassword("mine", for: profileID)

        KeychainService.setSyncsConnectionSecrets(true)
        XCTAssertEqual(KeychainService.password(for: profileID), "mine")
        XCTAssertEqual(iCloudCopy()?.value, "mine")
        let conflict = try XCTUnwrap(KeychainService.conflicts(for: profileID)[.databasePassword])
        XCTAssertEqual(conflict.value, "theirs")
        XCTAssertEqual(conflict.deviceTitle, "Other iPad")

        KeychainService.resolveConflict(.databasePassword, for: profileID, usingOther: false)
        XCTAssertEqual(KeychainService.password(for: profileID), "mine")
        XCTAssertTrue(KeychainService.conflicts(for: profileID).isEmpty)
    }

    func testAClearOnAnotherDeviceClearsThisDevicesCopy() throws {
        setSyncing(true)
        KeychainService.setPassword("secret", for: profileID)
        try otherDeviceSaves(nil, at: Date().addingTimeInterval(60))
        XCTAssertEqual(KeychainService.storedSecret(.databasePassword, for: profileID), "", "Cleared, not missing")
        setSyncing(false)
        XCTAssertEqual(KeychainService.password(for: profileID), "")
    }

    func testAClearHereIsAVersionOtherDevicesTakeOver() {
        setSyncing(true)
        KeychainService.setPassword("secret", for: profileID)
        KeychainService.setPassword("", for: profileID)
        XCTAssertNotNil(iCloudCopy())
        XCTAssertNil(iCloudCopy()?.value)
        KeychainService.reconcileConnectionSecrets()
        XCTAssertEqual(KeychainService.storedSecret(.databasePassword, for: profileID), "")
    }

    func testAnUnversionedValueFromAnEarlierVersionIsTakenOverAndReplaced() {
        setSyncing(true)
        KeychainService.setItem("from 2.0", account: account, synced: true)
        XCTAssertEqual(KeychainService.password(for: profileID), "from 2.0")
        XCTAssertEqual(iCloudCopy()?.value, "from 2.0")
        XCTAssertNil(KeychainService.record(account, synced: true), "The unversioned item is replaced")
    }

    func testDeletingAConnectionRemovesItsSecretsEverywhere() {
        setSyncing(true)
        KeychainService.setPassword("secret", for: profileID)
        KeychainService.deleteAllSecrets(for: profileID)
        XCTAssertNil(KeychainService.storedSecret(.databasePassword, for: profileID))
        XCTAssertNil(iCloudCopy())
        setSyncing(false)
        XCTAssertNil(KeychainService.storedSecret(.databasePassword, for: profileID))
    }

    func testOnlyConnectionAccountsAreSyncedOrRemoved() {
        XCTAssertTrue(KeychainService.isConnectionAccount(UUID().uuidString + ".databasePassword"))
        XCTAssertFalse(KeychainService.isConnectionAccount("app.synced.cloud-data-key"))
        XCTAssertFalse(KeychainService.isConnectionAccount(UUID().uuidString + ".unknown"))
        XCTAssertFalse(KeychainService.isConnectionAccount(UUID().uuidString + ".databasePassword.conflict"))
    }
}

final class SyncResolutionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func version(_ value: String?, _ offset: TimeInterval, _ device: String = "A") -> SyncedVersion {
        SyncedVersion(value: value, modified: t0.addingTimeInterval(offset), device: device)
    }

    func testResolution() {
        XCTAssertEqual(SyncResolution.resolve(local: nil, remote: nil, base: nil), .inSync)
        XCTAssertEqual(SyncResolution.resolve(local: version("a", 0), remote: nil, base: nil), .upload)
        XCTAssertEqual(SyncResolution.resolve(local: nil, remote: version("a", 0), base: nil), .adopt)
        XCTAssertEqual(SyncResolution.resolve(local: version("a", 0), remote: version("a", 5), base: nil), .inSync)
        // Only the other device changed.
        XCTAssertEqual(SyncResolution.resolve(local: version("a", 0), remote: version("b", 5), base: t0), .adopt)
        // Only this device changed.
        XCTAssertEqual(SyncResolution.resolve(local: version("b", 5), remote: version("a", 0), base: t0), .upload)
        // Both changed since they agreed, or they never agreed.
        XCTAssertEqual(SyncResolution.resolve(local: version("b", 5), remote: version("c", 6), base: t0), .conflict)
        XCTAssertEqual(SyncResolution.resolve(local: version("b", 5), remote: version("c", 6), base: nil), .conflict)
    }

    func testTheLaterChangeWinsAndTiesAgreeOnEveryDevice() {
        XCTAssertEqual(SyncResolution.winner(version("a", 1), version("b", 2)).value, "b")
        let tieA = version("a", 1, "A"), tieB = version("b", 1, "B")
        XCTAssertEqual(SyncResolution.winner(tieA, tieB), SyncResolution.winner(tieB, tieA))
    }
}

final class FieldMergeTests: XCTestCase {
    private struct Item: Codable, Identifiable, Equatable {
        var id: UUID
        var name: String
        var color: String
        var tags: [Tag] = []
    }
    private struct Tag: Codable, Equatable { var id: String; var label: String }

    func testEditsToDifferentFieldsOfOneItemBothSurvive() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var device1 = WorkspaceSyncCollection<Item>()
        device1.set(Item(id: id, name: "Prod", color: "blue"), at: base)
        var device2 = device1

        device1.set(Item(id: id, name: "Production", color: "blue"), at: base.addingTimeInterval(10))
        device2.set(Item(id: id, name: "Prod", color: "red"), at: base.addingTimeInterval(20))

        var merged1 = device1; merged1.merge(device2)
        var merged2 = device2; merged2.merge(device1)
        XCTAssertEqual(merged1.values, [Item(id: id, name: "Production", color: "red")])
        XCTAssertEqual(merged1.values, merged2.values, "Every device ends up with the same item")
    }

    func testTheLaterEditOfTheSameFieldWins() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var device1 = WorkspaceSyncCollection<Item>()
        device1.set(Item(id: id, name: "A", color: "blue"), at: base)
        var device2 = device1
        device1.set(Item(id: id, name: "B", color: "blue"), at: base.addingTimeInterval(20))
        device2.set(Item(id: id, name: "C", color: "blue"), at: base.addingTimeInterval(10))
        device2.merge(device1)
        XCTAssertEqual(device2.values.first?.name, "B")
    }

    func testADeletionNewerThanAnEditStillWins() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var device1 = WorkspaceSyncCollection<Item>()
        device1.set(Item(id: id, name: "A", color: "blue"), at: base)
        var device2 = device1
        device1.set(Item(id: id, name: "B", color: "blue"), at: base.addingTimeInterval(10))
        device2.remove(id, at: base.addingTimeInterval(20))
        device1.merge(device2)
        XCTAssertTrue(device1.values.isEmpty)
    }

    func testListsOfIdentifiedEntriesMergeEntryByEntry() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        let shared = Tag(id: "1", label: "shared")
        var device1 = WorkspaceSyncCollection<Item>()
        device1.set(Item(id: id, name: "A", color: "blue", tags: [shared]), at: base)
        var device2 = device1
        device1.set(Item(id: id, name: "A", color: "blue", tags: [shared, Tag(id: "2", label: "mac")]), at: base.addingTimeInterval(10))
        device2.set(Item(id: id, name: "A", color: "blue", tags: [Tag(id: "3", label: "ipad")]), at: base.addingTimeInterval(20))

        var merged1 = device1; merged1.merge(device2)
        var merged2 = device2; merged2.merge(device1)
        XCTAssertEqual(merged1.values.first?.tags.map(\.id), ["3", "2"], "The removal on one device and the addition on the other both apply")
        XCTAssertEqual(merged1.values, merged2.values)
    }

    func testRecordsFromEarlierVersionsWithoutFieldDatesStillMerge() throws {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        var device1 = WorkspaceSyncCollection<Item>()
        device1.set(Item(id: id, name: "A", color: "blue"), at: base)
        device1.set(Item(id: id, name: "B", color: "blue"), at: base.addingTimeInterval(10))
        // An earlier version writes whole items with no field dates.
        let legacy = try JSONDecoder().decode(WorkspaceSyncCollection<Item>.self, from: JSONSerialization.data(withJSONObject: [
            "records": [["id": id.uuidString, "updatedAt": base.addingTimeInterval(20).timeIntervalSinceReferenceDate,
                         "value": ["id": id.uuidString, "name": "A", "color": "green", "tags": []]]]
        ]))
        device1.merge(legacy)
        XCTAssertEqual(device1.values.first?.color, "green")
        XCTAssertEqual(device1.values.first?.name, "A", "Without field dates, every field of the newer item counts as newer")
    }

    func testAssistantSettingsKeepProvidersAddedOnEachDevice() throws {
        let suite1 = try XCTUnwrap(UserDefaults(suiteName: "merge-test-1-" + UUID().uuidString))
        let suite2 = try XCTUnwrap(UserDefaults(suiteName: "merge-test-2-" + UUID().uuidString))
        var base = AssistantSettings()
        base.updatedAt = Date(timeIntervalSince1970: 1_000)
        let encoded = try JSONEncoder().encode(base)
        suite1.set(encoded, forKey: AssistantSettings.storageKey)
        suite2.set(encoded, forKey: AssistantSettings.storageKey)

        var mac = AssistantSettings.load(from: suite1)
        mac.providers.append(AssistantProviderConfig(id: UUID(), name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", model: "llama"))
        mac.instructions = "Use snake_case."
        mac.save(to: suite1, syncing: false)
        Thread.sleep(forTimeInterval: 0.01)
        var ipad = AssistantSettings.load(from: suite2)
        ipad.providers.append(AssistantProviderConfig(id: UUID(), name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "x"))
        ipad.approvalMode = .suggestOnly
        ipad.save(to: suite2, syncing: false)

        let onMac = try XCTUnwrap(AssistantSettingsSync.merged(local: .load(from: suite1), cloud: .load(from: suite2)))
        let onIPad = try XCTUnwrap(AssistantSettingsSync.merged(local: .load(from: suite2), cloud: .load(from: suite1)))
        XCTAssertEqual(Set(onMac.providers.map(\.name)), [base.providers[0].name, "Ollama", "OpenRouter"])
        XCTAssertEqual(onMac.instructions, "Use snake_case.")
        XCTAssertEqual(onMac.approvalMode, .suggestOnly)
        XCTAssertEqual(onMac.providers, onIPad.providers)
        XCTAssertEqual(onMac.instructions, onIPad.instructions)
    }
}

final class SSHHostKeySyncTests: XCTestCase {
    private let host = "bastion-\(UUID().uuidString.prefix(8)).example.com:22"
    private var defaults: UserDefaults!
    private var store: SSHTunnelSyncingHostKeyStore!
    private var savedSetting: Any?

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "hostkeys-" + UUID().uuidString)
        store = SSHTunnelSyncingHostKeyStore(local: SSHTunnelUserDefaultsHostKeyStore(defaults: defaults))
        savedSetting = UserDefaults.standard.object(forKey: SSHTunnelSyncingHostKeyStore.syncsKey)
    }

    override func tearDown() {
        store.forget(host)
        KeychainService.deleteItem("hostkey." + host + SyncedSlot.remoteSuffix, synced: true)
        KeychainService.deleteItem("hostkey." + host + SyncedSlot.conflictSuffix, synced: false)
        UserDefaults.standard.set(savedSetting, forKey: SSHTunnelSyncingHostKeyStore.syncsKey)
        super.tearDown()
    }

    private func otherDeviceTrusts(_ fingerprint: String?, at date: Date) throws {
        let version = SyncedVersion(value: fingerprint, modified: date, device: "OTHER", deviceName: "Other Mac")
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(version), encoding: .utf8))
        KeychainService.setItem(text, account: "hostkey." + host + SyncedSlot.remoteSuffix, synced: true)
    }

    func testSyncingIsOffUnlessTurnedOn() throws {
        UserDefaults.standard.removeObject(forKey: SSHTunnelSyncingHostKeyStore.syncsKey)
        try otherDeviceTrusts("SHA256:other", at: .now)
        XCTAssertNil(store.fingerprint(for: host), "Without syncing, another device's trust isn't used")
    }

    func testAKeyTrustedOnAnotherDeviceIsTrustedHere() throws {
        store.setSyncing(true)
        try otherDeviceTrusts("SHA256:abc", at: .now)
        XCTAssertEqual(store.fingerprint(for: host), "SHA256:abc")
    }

    func testAKeyTrustedHereGoesToOtherDevices() {
        store.setSyncing(true)
        store.setFingerprint("SHA256:mine", for: host)
        let remote = KeychainService.record("hostkey." + host + SyncedSlot.remoteSuffix, synced: true)
            .flatMap { try? JSONDecoder().decode(SyncedVersion.self, from: Data($0.value.utf8)) }
        XCTAssertEqual(remote?.value, "SHA256:mine")
    }

    func testDifferentKeysOnTwoDevicesAreNeverMergedAndWaitForTheUser() throws {
        store.setFingerprint("SHA256:mine", for: host)
        try otherDeviceTrusts("SHA256:theirs", at: Date().addingTimeInterval(60))
        store.setSyncing(true)

        XCTAssertEqual(store.fingerprint(for: host), "SHA256:mine", "This device keeps its own key, even though the other is newer")
        XCTAssertEqual(store.conflict(for: host)?.value, "SHA256:theirs")

        store.useOther(for: host)
        XCTAssertEqual(store.fingerprint(for: host), "SHA256:theirs")
        XCTAssertNil(store.conflict(for: host))
    }

    func testForgettingAKeyForgetsItOnOtherDevicesToo() throws {
        store.setSyncing(true)
        store.setFingerprint("SHA256:mine", for: host)
        store.forget(host)
        XCTAssertNil(store.fingerprint(for: host))
        let remote = KeychainService.record("hostkey." + host + SyncedSlot.remoteSuffix, synced: true)
            .flatMap { try? JSONDecoder().decode(SyncedVersion.self, from: Data($0.value.utf8)) }
        XCTAssertNotNil(remote)
        XCTAssertNil(remote?.value)
    }
}
