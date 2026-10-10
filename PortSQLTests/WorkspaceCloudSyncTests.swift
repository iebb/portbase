import Foundation
import XCTest
@testable import PortSQL

final class WorkspaceCloudSyncTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func query(_ title: String) -> SavedQuerySnippet { SavedQuerySnippet(title: title, sql: "SELECT 1", createdAt: base) }

    func testIndependentOfflineAdditionsConverge() {
        let a = query("A"), b = query("B")
        var left = WorkspaceSyncCollection<SavedQuerySnippet>(), right = left
        left.set(a, at: base); right.set(b, at: base)
        let initial = left
        left.merge(right); right.merge(initial)
        XCTAssertEqual(left, right)
        XCTAssertEqual(Set(left.values.map(\.id)), [a.id, b.id])
    }

    func testNewerEditSurvivesStaleNotification() {
        let original = query("Original")
        var edited = original; edited.title = "Edited"
        var state = WorkspaceSyncCollection<SavedQuerySnippet>(), stale = state
        stale.set(original, at: base); state.set(edited, at: base.addingTimeInterval(5))
        state.merge(stale); state.merge(stale)
        XCTAssertEqual(state.values, [edited])
    }

    func testDeletionCannotBeResurrectedByOfflineReplica() {
        let value = query("Deleted")
        var state = WorkspaceSyncCollection<SavedQuerySnippet>(), remote = state
        remote.set(value, at: base)
        state.remove(value.id, at: base.addingTimeInterval(1)); state.merge(remote)
        XCTAssertTrue(state.values.isEmpty)
        XCTAssertNil(state.records.first?.value)
    }

    func testEqualRevisionDeletionWinsAndExplicitNewerRestoreWorks() {
        let value = query("Restored")
        var state = WorkspaceSyncCollection<SavedQuerySnippet>(), remote = state
        state.set(value, at: base); remote.remove(value.id, at: base); state.merge(remote)
        XCTAssertTrue(state.values.isEmpty)
        state.set(value, at: base.addingTimeInterval(1)); state.merge(remote)
        XCTAssertEqual(state.values, [value])
    }

    func testConcurrentEditsHaveDeterministicTieBreak() {
        let a = query("A"); var b = a; b.title = "B"
        var left = WorkspaceSyncCollection<SavedQuerySnippet>(), right = left
        left.set(a, at: base); right.set(b, at: base)
        let initial = left
        left.merge(right); right.merge(initial)
        XCTAssertEqual(left, right)
    }

    func testConnectionEnvelopeKeepsEveryCredentialRedacted() throws {
        var value = ConnectionProfile(name: "Fixture", engine: .postgresql, host: "example.invalid", port: 5432,
                                      username: "reader", password: "database-secret", defaultDatabase: "fixture")
        value.sshPassword = "ssh-secret"; value.sshPrivateKey = "private-key-secret"
        value.sshPassphrase = "passphrase-secret"; value.privateCACertificate = "private-ca-secret"
        var state = WorkspaceSyncCollection<ConnectionProfile>(); state.set(value, at: base)
        state.legacySnapshot = [value]
        let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        for secret in [value.password, value.sshPassword, value.sshPrivateKey, value.sshPassphrase, value.privateCACertificate] {
            XCTAssertFalse(encoded.contains(secret))
        }
        XCTAssertTrue(encoded.contains("<keychain>"))
    }

    @MainActor func testCorruptSyncStatePreservesOriginalFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.json"), data = Data("malformed".utf8)
        try data.write(to: url)
        let collection = WorkspaceCloudCollection<SavedQuerySnippet>(key: "portsql.test.corrupt", url: url,
            initial: [], initialDate: { $0.createdAt }, cloud: MemoryCloud())
        collection.save([query("Local")])
        XCTAssertNil(collection.mergeCloud())
        XCTAssertNotNil(collection.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor func testLegacyEditSyncsWithoutResurrectingDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = query("Original"), cloud = MemoryCloud()
        let collection = WorkspaceCloudCollection<SavedQuerySnippet>(key: "fixture", url: directory.appendingPathComponent("sync.json"),
            initial: [original], initialDate: { $0.createdAt }, cloud: cloud)
        _ = collection.ingestLegacy([original], initialDate: { $0.createdAt })
        var edited = original; edited.title = "Older app edit"
        XCTAssertEqual(collection.ingestLegacy([edited], initialDate: { $0.createdAt }), [edited])
        collection.save([])
        XCTAssertTrue(collection.ingestLegacy([edited], initialDate: { $0.createdAt }).isEmpty)
    }

    @MainActor func testQuotaFailureKeepsSavedQueriesOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = MemoryCloud(); cloud.values["other"] = Data(repeating: 0, count: 900_000)
        let url = directory.appendingPathComponent("sync.json"), value = query("Saved locally")
        let collection = WorkspaceCloudCollection<SavedQuerySnippet>(key: "fixture", url: url,
            initial: [], initialDate: { $0.createdAt }, cloud: cloud)
        collection.save([value])
        XCTAssertNotNil(collection.errorMessage)
        XCTAssertNil(cloud.values["fixture"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        XCTAssertEqual(try decoder.decode(WorkspaceSyncCollection<SavedQuerySnippet>.self, from: Data(contentsOf: url)).values, [value])
    }
}

@MainActor private final class MemoryCloud: WorkspaceCloudStorage {
    var values: [String: Any] = [:]
    var dictionaryRepresentation: [String: Any] { values }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func setData(_ data: Data, forKey key: String) { values[key] = data }
    func synchronize() {}
}
