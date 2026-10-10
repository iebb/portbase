import Foundation
import Darwin
import SQLite3

/// Files outlive bookmarks. Only explicit file deletion removes a local database.
final class SQLiteFileStore: @unchecked Sendable {
    static let shared = SQLiteFileStore()
    let directory: URL
    private let lock = NSLock()
    private var leases: [String: Int] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PortSQL/SQLiteDatabases", isDirectory: true)
    }

    func files() throws -> [SQLiteManagedFile] {
        try lock.withLock {
            try prepareDirectory()
            return try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
                .compactMap { url -> SQLiteManagedFile? in
                    guard Self.isValid(fileName: url.lastPathComponent), let safe = try? resolvedURL(fileName: url.lastPathComponent) else { return nil }
                    let values = try safe.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    return SQLiteManagedFile(fileName: safe.lastPathComponent, displayName: Self.displayName(fileName: safe.lastPathComponent),
                        byteCount: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
                }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    func acquire(fileName: String) throws -> SQLiteFileLease {
        try lock.withLock {
            let url = try resolvedURL(fileName: fileName)
            leases[Self.leaseKey(fileName), default: 0] += 1
            return SQLiteFileLease(url: url) { [weak self] in self?.release(fileName: fileName) }
        }
    }

    private func release(fileName: String) {
        lock.withLock {
            let key = Self.leaseKey(fileName)
            let remaining = (leases[key] ?? 1) - 1
            if remaining > 0 { leases[key] = remaining } else { leases.removeValue(forKey: key) }
        }
    }

    func remove(fileName: String) throws {
        try lock.withLock {
            guard leases[Self.leaseKey(fileName), default: 0] == 0 else { throw SQLiteClientError.fileInUse }
            let url = try resolvedURL(fileName: fileName)
            try FileManager.default.removeItem(at: url)
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = URL(fileURLWithPath: url.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
            }
        }
    }

    func create(name: String) async throws -> SQLiteManagedFile {
        try await SQLiteOperation.run(timeoutSeconds: 30) { operation in
            var url = try self.makeDestination(name: name)
            var success = false
            defer { if !success { self.discard(url) } }
            let handle = try Self.open(url: url, writable: true, operation: operation)
            var open = true
            defer { if open { operation.close(handle) } }
            let code = sqlite3_exec(handle, "VACUUM", nil, nil, nil)
            guard code == SQLITE_OK else { throw Self.error(handle, code: code, operation: operation) }
            try operation.check()
            operation.close(handle); open = false
            url = try self.publish(url)
            try self.protect(url)
            let file = try self.descriptor(url)
            success = true
            return file
        }
    }

    func importDatabase(from sourceURL: URL, timeoutSeconds: Int = 30) async throws -> SQLiteManagedFile {
        try await SQLiteOperation.run(timeoutSeconds: timeoutSeconds) { operation in
            let access = sourceURL.startAccessingSecurityScopedResource()
            defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
            let properties = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw SQLiteClientError.invalidDatabase }
            let source = try Self.open(url: sourceURL, writable: false, operation: operation)
            defer { operation.close(source) }
            var url = try self.makeDestination(name: sourceURL.deletingPathExtension().lastPathComponent)
            var success = false
            defer { if !success { self.discard(url) } }
            let destination = try Self.open(url: url, writable: true, operation: operation)
            var open = true
            defer { if open { operation.close(destination) } }
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
                throw Self.error(destination, code: sqlite3_errcode(destination), operation: operation)
            }
            var finished = false
            defer { if !finished { sqlite3_backup_finish(backup) } }
            while true {
                try operation.check()
                let code = sqlite3_backup_step(backup, 128)
                if code == SQLITE_DONE { break }
                if code == SQLITE_BUSY || code == SQLITE_LOCKED { sqlite3_sleep(20); continue }
                guard code == SQLITE_OK else { throw Self.error(destination, code: code, operation: operation) }
            }
            let finishCode = sqlite3_backup_finish(backup)
            finished = true
            guard finishCode == SQLITE_OK else { throw Self.error(destination, code: finishCode, operation: operation) }
            try Self.validateDatabase(destination, operation: operation)
            let journal = sqlite3_exec(destination, "PRAGMA journal_mode = DELETE", nil, nil, nil)
            guard journal == SQLITE_OK else { throw Self.error(destination, code: journal, operation: operation) }
            try operation.check()
            operation.close(destination); open = false
            url = try self.publish(url)
            try self.protect(url)
            let file = try self.descriptor(url)
            success = true
            return file
        }
    }

    static func displayName(fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.replacingOccurrences(of: #"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            with: "", options: .regularExpression)
    }

    static func isValid(fileName: String) -> Bool {
        fileName.utf8.count <= 240 && fileName.range(of: #"^[\p{L}\p{N}_-]+\.sqlite\z"#, options: .regularExpression) != nil
    }

    private static func leaseKey(_ fileName: String) -> String { fileName.precomposedStringWithCanonicalMapping.lowercased() }

    private static var directoryAttributes: [FileAttributeKey: Any] {
#if os(macOS)
        [.posixPermissions: 0o700]
#else
        protectionAttributes
#endif
    }

    private static var protectionAttributes: [FileAttributeKey: Any] {
#if os(macOS)
        [.posixPermissions: 0o600]
#else
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
#endif
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: Self.directoryAttributes)
        try protect(directory)
    }

    private func resolvedURL(fileName: String) throws -> URL {
        guard Self.isValid(fileName: fileName) else { throw SQLiteClientError.invalidFileName }
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SQLiteClientError.missingFile }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
            throw SQLiteClientError.invalidFileName
        }
        return url
    }

    private func makeDestination(name: String) throws -> URL {
        try lock.withLock {
            try prepareDirectory()
            let cleaned = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? Character(String($0)) : "_" }.prefix(48))
            let fileName = (cleaned.isEmpty ? "database" : cleaned) + "-" + UUID().uuidString + ".sqlite"
            let url = directory.appendingPathComponent("." + fileName)
            guard FileManager.default.createFile(atPath: url.path, contents: Data(),
                attributes: Self.protectionAttributes) else { throw CocoaError(.fileWriteUnknown) }
            try protect(url)
            return url
        }
    }

    private func publish(_ stagingURL: URL) throws -> URL {
        try lock.withLock {
            let url = directory.appendingPathComponent(String(stagingURL.lastPathComponent.dropFirst()))
            try FileManager.default.moveItem(at: stagingURL, to: url)
            return url
        }
    }

    private func protect(_ url: URL) throws {
#if os(macOS)
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
#else
        try FileManager.default.setAttributes(Self.protectionAttributes, ofItemAtPath: url.path)
#endif
        var excluded = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    private func descriptor(_ url: URL) throws -> SQLiteManagedFile {
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return SQLiteManagedFile(fileName: url.lastPathComponent, displayName: Self.displayName(fileName: url.lastPathComponent),
            byteCount: Int64(properties.fileSize ?? 0), modifiedAt: properties.contentModificationDate ?? .now)
    }

    private func discard(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// Foundation can retain /var in a resolved URL on macOS. SQLite's
    /// NOFOLLOW checks every component, so resolve the parent with realpath
    /// and keep the leaf untouched to reject symbolic database files.
    static func canonicalPath(for url: URL) throws -> String {
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw SQLiteClientError.invalidDatabase }
        defer { free(parent) }
        return String(cString: parent) + "/" + url.lastPathComponent
    }

    private static func open(url: URL, writable: Bool, operation: SQLiteOperation) throws -> OpaquePointer {
        try operation.check()
        var handle: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(try canonicalPath(for: url), &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteClientError.invalidDatabase
        }
        do { try operation.attach(handle) } catch { sqlite3_close_v2(handle); throw error }
        let configuration = PortSQLConfigureSQLite(handle)
        guard configuration == SQLITE_OK else { operation.close(handle); throw SQLiteClientError.invalidDatabase }
        let context = Unmanaged.passUnretained(operation).toOpaque()
        sqlite3_progress_handler(handle, 1_000, { raw in
            guard let raw else { return 1 }
            return Unmanaged<SQLiteOperation>.fromOpaque(raw).takeUnretainedValue().shouldStop ? 1 : 0
        }, context)
        sqlite3_busy_handler(handle, { raw, attempts in
            guard let raw, attempts < 500 else { return 0 }
            let operation = Unmanaged<SQLiteOperation>.fromOpaque(raw).takeUnretainedValue()
            guard !operation.shouldStop else { return 0 }
            sqlite3_sleep(10)
            return operation.shouldStop ? 0 : 1
        }, context)
        let setup = sqlite3_exec(handle, "PRAGMA trusted_schema = OFF", nil, nil, nil)
        guard setup == SQLITE_OK else { operation.close(handle); throw SQLiteClientError.invalidDatabase }
        return handle
    }

    private static func validateDatabase(_ handle: OpaquePointer, operation: SQLiteOperation) throws {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, "PRAGMA quick_check(1)", -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(handle, code: code, operation: operation) }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        try operation.check()
        guard step == SQLITE_ROW, let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok" else {
            throw SQLiteClientError.invalidDatabase
        }
    }

    private static func error(_ handle: OpaquePointer, code: Int32, operation: SQLiteOperation) -> Error {
        do { try operation.check() } catch { return error }
        return SQLiteClientError.database(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

final class SQLiteFileLease {
    let url: URL
    private var onRelease: (() -> Void)?
    init(url: URL, onRelease: @escaping () -> Void) { self.url = url; self.onRelease = onRelease }
    func release() { onRelease?(); onRelease = nil }
    deinit { release() }
}
