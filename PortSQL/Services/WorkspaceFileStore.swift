import Foundation

/// Local drafts and results use device data protection; connection secrets remain in Keychain.
enum WorkspaceFileStore {
    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    static var directory: URL {
        let base = isTestHost ? FileManager.default.temporaryDirectory.appendingPathComponent("PortbaseTests-" + String(ProcessInfo.processInfo.processIdentifier))
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base
            .appendingPathComponent("PortSQL", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var writingOptions: Data.WritingOptions {
#if os(macOS)
        .atomic
#else
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#endif
    }

    static var fileAttributes: [FileAttributeKey: Any] {
#if os(macOS)
        [.posixPermissions: 0o600]
#else
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
#endif
    }

    static func write(_ data: Data, to url: URL) throws {
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            try previous.write(to: backup, options: writingOptions)
        }
        try data.write(to: url, options: writingOptions)
#if os(macOS)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
#endif
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let backup = url.appendingPathExtension("backup")
            guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
            return try decoder.decode(type, from: Data(contentsOf: backup))
        }
        do { return try decoder.decode(type, from: Data(contentsOf: url)) }
        catch {
            guard let recovered = try? decoder.decode(type, from: Data(contentsOf: url.appendingPathExtension("backup"))) else { throw error }
            // Keep the damaged file for explicit inspection; the next save must not overwrite the good backup with it.
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("damaged-" + UUID().uuidString))
            return recovered
        }
    }
}

struct DeletedLibraryItem: Identifiable, Codable {
    enum Content: Codable { case snippet(SavedQuerySnippet), chart(SavedVisualizationPreset) }
    var id = UUID()
    var deletedAt = Date.now
    var content: Content
    var title: String {
        switch content { case .snippet(let value): value.title; case .chart(let value): value.title }
    }
}
