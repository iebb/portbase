import Foundation

/// Creates an empty local SQLite database and a connection for it.
@MainActor enum LocalSQLiteDatabase {
    static func create(named name: String, bookmarks: BookmarkStore, workspace: WorkspaceViewModel) async throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = try await SQLiteFileStore.shared.create(name: title)
        var profile = ConnectionProfile(name: title, engine: .sqlite, host: "", port: 0,
                                        username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        guard bookmarks.upsert(profile) else {
            try? SQLiteFileStore.shared.remove(fileName: file.fileName)
            throw SQLiteClientError.missingFile
        }
        workspace.selectBookmark(profile.id)
    }
}
