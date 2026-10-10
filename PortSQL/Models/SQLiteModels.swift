import Foundation

struct SQLiteManagedFile: Identifiable, Hashable, Sendable {
    var id: String { fileName }
    let fileName: String
    let displayName: String
    let byteCount: Int64
    let modifiedAt: Date
}

enum SQLiteClientError: LocalizedError {
    case missingFile, invalidFileName, invalidDatabase, fileInUse, singleStatementRequired, invalidParameter
    case unsafeOperation, transactionControlsUnavailable, temporaryObjectsUnavailable
    case database(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .missingFile: L10n.text("The SQLite file is unavailable on this device. Import it or choose another local file.")
        case .invalidFileName: L10n.text("The SQLite file name is invalid.")
        case .invalidDatabase: L10n.text("Choose an unencrypted SQLite database file.")
        case .fileInUse: L10n.text("This SQLite file is in use. Finish or cancel its queries before deleting it.")
        case .singleStatementRequired: L10n.text("Run SQLite statements individually or use Run All.")
        case .invalidParameter: L10n.text("The SQLite parameter count or value is invalid.")
        case .unsafeOperation: L10n.text("SQLite file attachment, extension loading, and unsafe configuration commands are disabled.")
        case .transactionControlsUnavailable: L10n.text("SQLite commands commit individually. Manual transaction commands are unavailable.")
        case .temporaryObjectsUnavailable: L10n.text("Temporary SQLite objects are unavailable because each command uses a new connection.")
        case .database(let code, let message): L10n.format("SQLite error %d: %@", code, message)
        }
    }
}
