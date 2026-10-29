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

/// A file in the app's iCloud Drive folder. iCloud can evict a file to free space, leaving a placeholder
/// on the device until it's downloaded again: such a file isn't damaged, only not here yet.
enum CloudDriveFile {
    enum Contents: Equatable { case data(Data), missing, notDownloaded }

    /// True for a file whose contents are on this device, and for files outside iCloud.
    static func isDownloaded(_ url: URL) -> Bool {
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        return status == nil || status == .current
    }

    /// Reads the file through file coordination. A file that isn't on this device yet is asked for rather
    /// than waited on; read it again once `CloudDriveDownloadWatcher` reports it downloaded.
    static func read(_ url: URL, isDownloaded: (URL) -> Bool = isDownloaded) -> Contents {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            // Evicted files can also appear only as a hidden ".name.icloud" placeholder.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            guard fileManager.fileExists(atPath: placeholder.path) else { return .missing }
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .notDownloaded
        }
        guard isDownloaded(url) else {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .notDownloaded
        }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            data = try? Data(contentsOf: source)
        }
        if let data { return .data(data) }
        // A file that can't be read although it's listed as here is most likely being evicted.
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        return .notDownloaded
    }
}

/// Watches the app's iCloud Drive Documents folder for a file to finish downloading, then calls back once.
@MainActor
final class CloudDriveDownloadWatcher {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let onDownloaded: @MainActor () -> Void

    init(fileName: String, onDownloaded: @escaping @MainActor () -> Void) {
        self.onDownloaded = onDownloaded
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.check() }
            })
        }
        query.start()
    }

    func stop() {
        query.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func check() {
        guard !observers.isEmpty else { return }
        query.disableUpdates()
        let downloaded = query.results.contains { result in
            (result as? NSMetadataItem)?.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
                == NSMetadataUbiquitousItemDownloadingStatusCurrent
        }
        query.enableUpdates()
        guard downloaded else { return }
        stop()
        onDownloaded()
    }
}
