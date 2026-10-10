import Foundation

enum ScriptFileService {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumBytes else { throw failure() }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes, var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw failure() }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    static func export(_ text: String, engine: DatabaseEngine?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Portbase-Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = engine?.usesJSONEditor == true ? "json" : engine == .redis ? "redis" : "sql"
        let url = directory.appendingPathComponent(UUID().uuidString + "." + suffix)
        try Data(text.utf8).write(to: url, options: WorkspaceFileStore.writingOptions)
        return url
    }

    private static func failure() -> NSError {
        NSError(domain: "Portbase.Script", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("Choose a UTF-8 text file smaller than 2 MB.")])
    }
}
