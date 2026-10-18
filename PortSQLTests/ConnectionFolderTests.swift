import XCTest
@testable import PortSQL

@MainActor
final class ConnectionFolderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("folders-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func profile(_ name: String) -> ConnectionProfile {
        ConnectionProfile(name: name, engine: .postgresql, host: name + ".example.com", port: 5432, username: "app", password: "", defaultDatabase: "app")
    }

    func testFoldersAreSortedByNameAndKeptAcrossLaunches() {
        let store = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        store.addFolder(named: "  Clients ")
        store.addFolder(named: "Analytics", color: .purple)
        XCTAssertEqual(store.folders.map(\.name), ["Analytics", "Clients"], "Names are trimmed and sorted")

        let reopened = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(reopened.folders.map(\.name), ["Analytics", "Clients"])
        XCTAssertEqual(reopened.folders.first?.colorTag, .purple)
    }

    func testConnectionsMoveIntoAndOutOfFolders() throws {
        let store = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        let connection = profile("orders")
        XCTAssertTrue(store.upsert(connection))
        let folder = store.addFolder(named: "Clients")

        store.move(connection.id, toFolder: folder.id)
        XCTAssertEqual(store.bookmark(with: connection.id)?.folderID, folder.id)
        let reopened = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(reopened.bookmark(with: connection.id)?.folderID, folder.id, "The folder is saved with the connection")

        store.move(connection.id, toFolder: nil)
        XCTAssertNil(store.bookmark(with: connection.id)?.folderID)
    }

    func testDeletingAFolderKeepsItsConnections() {
        let store = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        let connection = profile("orders")
        XCTAssertTrue(store.upsert(connection))
        let folder = store.addFolder(named: "Clients")
        store.move(connection.id, toFolder: folder.id)

        store.deleteFolder(folder.id)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(store.bookmarks.map(\.id), [connection.id])
        XCTAssertNil(store.bookmark(with: connection.id)?.folderID)
    }

    func testRenamingAndRecoloringAFolder() throws {
        let store = BookmarkStore(directory: directory, cloudSyncEnabled: false)
        var folder = store.addFolder(named: "Old")
        folder.name = "New"
        folder.colorTag = .orange
        store.updateFolder(folder)
        XCTAssertEqual(store.folders, [folder])
    }

    func testTheFolderOfAConnectionSurvivesEncoding() throws {
        var connection = profile("orders")
        connection.folderID = UUID()
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(connection))
        XCTAssertEqual(decoded.folderID, connection.folderID)
    }
}
