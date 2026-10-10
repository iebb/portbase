import Foundation
@preconcurrency import SwiftBSON

/// One row is written at a time. The lock also protects MySQL's event-loop callbacks.
final class DataExportWriter: @unchecked Sendable {
    let url: URL
    private let format: QueryResultExportFormat
    private let handle: FileHandle
    private let lock = NSLock()
    private var names: [String] = []
    private var started = false
    private var count = 0
    private var storedError: Error?
    private var closed = false
    private let progress: @Sendable (DataTransferProgress) -> Void

    init(format: QueryResultExportFormat, progress: @escaping @Sendable (DataTransferProgress) -> Void) throws {
        self.format = format
        self.progress = progress
        url = try Self.temporaryURL(extension: format.fileExtension)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: WorkspaceFileStore.fileAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    static func temporaryURL(extension suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortSQLTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("portsql-\(UUID().uuidString).\(suffix)")
    }

    func setColumns(_ columns: [QueryColumn]) {
        lock.withLock {
            guard !started, storedError == nil else { return }
            do { try start(names: columns.map(\.name)) }
            catch { storedError = error }
        }
    }

    private func start(names: [String]) throws {
        guard names.count <= DataTransferCodec.maximumColumns else { throw DataTransferError.tooManyColumns }
        self.names = QueryResultTable.disambiguatedColumnNames(names)
        if format == .csv {
            try write(self.names.map { DataTransferCodec.csvValue(.text($0)) }.joined(separator: ",") + "\r\n")
        } else { try write("[\n") }
        started = true
    }

    func append(_ row: QueryRow) throws {
        let completed = try lock.withLock {
            if let storedError { throw storedError }
            guard started else { throw DataTransferError.invalidMapping }
            if format == .csv {
                try write(names.indices.map { DataTransferCodec.csvValue(row.cells.indices.contains($0) ? row.cells[$0] : .null) }.joined(separator: ",") + "\r\n")
            } else {
                let text = "{" + names.enumerated().map { index, name in
                    DataTransferCodec.jsonString(name) + ":" + DataTransferCodec.jsonValue(row.cells.indices.contains(index) ? row.cells[index] : .null)
                }.joined(separator: ",") + "}"
                try write((count == 0 ? "" : ",\n") + text)
            }
            count += 1
            return count
        }
        if completed % 250 == 0 { progress(.init(phase: .exporting, completed: completed, total: nil)) }
    }

    func appendDocument(_ canonicalJSON: String) throws {
        let completed = try lock.withLock {
            guard format == .json else { throw DataTransferError.invalidMapping }
            if let storedError { throw storedError }
            if !started { try start(names: []) }
            try write((count == 0 ? "" : ",\n") + canonicalJSON)
            count += 1
            return count
        }
        if completed % 250 == 0 { progress(.init(phase: .exporting, completed: completed, total: nil)) }
    }

    func finish() throws -> DataTransferResult {
        try lock.withLock {
            if let storedError { throw storedError }
            if !started { try start(names: []) }
            if !closed {
                if format == .json { try write("\n]\n") }
                try handle.synchronize()
                try handle.close()
                closed = true
            }
            return DataTransferResult(rowCount: count, fileURL: url)
        }
    }

    func discard() {
        lock.withLock {
            if !closed { try? handle.close(); closed = true }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ string: String) throws { try handle.write(contentsOf: Data(string.utf8)) }
}

/// MongoDB fields vary between documents. A disk spool discovers the header without retaining the result.
final class MongoCSVExportSpool: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var names: [String] = []
    private var seen = Set<String>()
    private var count = 0
    private let progress: @Sendable (DataTransferProgress) -> Void

    init(progress: @escaping @Sendable (DataTransferProgress) -> Void) throws {
        self.progress = progress
        url = try DataExportWriter.temporaryURL(extension: "jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: WorkspaceFileStore.fileAttributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close(); try? FileManager.default.removeItem(at: url) }

    func append(_ canonicalJSON: String) throws {
        let completed = try lock.withLock {
            let document = try MongoExtendedJSON.decode(canonicalJSON, maximumBytes: 64 * 1_024 * 1_024)
            for name in document.keys where seen.insert(name).inserted {
                names.append(name)
                guard names.count <= DataTransferCodec.maximumColumns else { throw DataTransferError.tooManyColumns }
            }
            try handle.write(contentsOf: Data((canonicalJSON + "\n").utf8))
            count += 1
            return count
        }
        if completed % 250 == 0 { progress(.init(phase: .exporting, completed: completed, total: nil)) }
    }

    func finish(writer: DataExportWriter) throws -> DataTransferResult {
        try handle.synchronize()
        try handle.close()
        writer.setColumns(names.map { QueryColumn(name: $0, type: "BSON") })
        progress(.init(phase: .finishing, completed: count, total: count))
        let reader = try JSONRecordReader(url: url, maximumBytes: 64 * 1_024 * 1_024)
        while let text = try reader.next() {
            try Task.checkCancellation()
            let document = try MongoExtendedJSON.decode(text, maximumBytes: 64 * 1_024 * 1_024)
            try writer.append(QueryRow(cells: names.map { DataTransferCodec.mongoCSVCell(document[$0]) }))
        }
        return try writer.finish()
    }
}
