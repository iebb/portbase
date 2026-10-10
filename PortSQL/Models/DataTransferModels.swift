import Foundation

enum DataImportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum DataImportValueType: String, CaseIterable, Identifiable, Sendable {
    case automatic, text, integer, decimal, boolean, json
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L10n.text("Automatic")
        case .text: L10n.text("Text")
        case .integer: L10n.text("Integer")
        case .decimal: L10n.text("Decimal")
        case .boolean: L10n.text("Boolean")
        case .json: "JSON"
        }
    }
}

struct DataImportColumnMapping: Identifiable, Hashable, Sendable {
    var id: String { sourceName }
    let sourceName: String
    var targetName: String
    var valueType: DataImportValueType = .automatic
}

struct DataImportRecord: Sendable {
    let fields: [String: QueryCell]
    let documentJSON: String?
}

struct DataImportSource: Sendable {
    let url: URL
    let format: DataImportFormat
    let hasHeader: Bool
    let nullToken: String
    let columnNames: [String]
    let rowCount: Int
    let preview: [DataImportRecord]
}

struct DataImportPlan: Sendable {
    let source: DataImportSource
    let schemaName: String
    let tableName: String
    let mappings: [DataImportColumnMapping]

    func statement(engine: DatabaseEngine) throws -> String {
        let included = mappings.filter { !$0.targetName.isEmpty }
        guard !tableName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (!included.isEmpty || (engine == .mongodb && source.columnNames.isEmpty)),
              Set(included.map(\.targetName)).count == included.count,
              !included.contains(where: { $0.targetName.contains("\0") }), !tableName.contains("\0"), !schemaName.contains("\0") else {
            throw DataTransferError.invalidMapping
        }
        if engine == .mongodb {
            return "{\"insert\": " + DataTransferCodec.jsonString(tableName) + ", \"documents\": […], \"ordered\": true}"
        }
        let columns = included.map { DataTransferCodec.identifier($0.targetName, engine: engine) }.joined(separator: ", ")
        let placeholders = included.indices.map { engine == .postgresql ? "$\($0 + 1)" : "?" }.joined(separator: ", ")
        return "INSERT INTO \(DataTransferCodec.qualifiedTable(schema: schemaName, table: tableName, engine: engine)) (\(columns)) VALUES (\(placeholders))"
    }
}

struct DataTransferProgress: Sendable {
    enum Phase: Sendable { case reading, importing, exporting, finishing }
    let phase: Phase
    let completed: Int
    let total: Int?

    var label: String {
        switch phase {
        case .reading: L10n.format("Reading: %@", L10n.plural("row_count", count: completed))
        case .importing: L10n.format("Importing: %@", L10n.plural("row_count", count: completed))
        case .exporting: L10n.format("Exporting: %@", L10n.plural("row_count", count: completed))
        case .finishing: L10n.text("Finishing…")
        }
    }
}

struct DataTransferResult: Sendable {
    let rowCount: Int
    let fileURL: URL?
}

enum DataTransferError: LocalizedError {
    case invalidCSV, invalidCSVHeader, invalidJSON, invalidUTF8, emptyFile, inconsistentColumns, tooManyColumns
    case recordTooLarge, invalidMapping, invalidValue(column: String, row: Int), missingField(column: String, row: Int)
    case binaryImportUnsupported, singleQueryRequired, nonTransactionalTable, commitUncertain
    case mongoPartialImport(completed: Int, underlying: String)

    var errorDescription: String? {
        switch self {
        case .invalidCSV: L10n.text("The CSV contains an unterminated quote or an invalid field separator.")
        case .invalidCSVHeader: L10n.text("CSV column names must be unique and nonempty.")
        case .invalidJSON: L10n.text("Use a JSON array of objects or one JSON object per line.")
        case .invalidUTF8: L10n.text("The file must use UTF-8 text encoding.")
        case .emptyFile: L10n.text("The file contains no records.")
        case .inconsistentColumns: L10n.text("Every CSV record must have the same number of fields as its header.")
        case .tooManyColumns: L10n.text("CSV supports up to 4,096 columns in this operation. Export as JSON to preserve additional fields.")
        case .recordTooLarge: L10n.text("An import record is too large. Each record must fit within 1 MiB.")
        case .invalidMapping: L10n.text("Select a destination and map each included field to a different column.")
        case .invalidValue(let column, let row): L10n.format("Invalid value for %@ at record %d.", column, row)
        case .missingField(let column, let row): L10n.format("Missing field %@ at record %d. Map another field or omit this column.", column, row)
        case .binaryImportUnsupported: L10n.text("Binary SQL columns are omitted from inserts. Import their values with a database-specific tool.")
        case .singleQueryRequired: L10n.text("Export one read-only query at a time.")
        case .nonTransactionalTable: L10n.text("SQL import requires a transactional table so a failed import can roll back. Select an InnoDB table.")
        case .commitUncertain: L10n.text("The connection ended while committing the import. Its outcome is unknown. Check the destination before retrying.")
        case .mongoPartialImport(let completed, let underlying):
            L10n.format("MongoDB import stopped after %d confirmed records. The current batch may also contain saved documents. %@", completed, underlying)
        }
    }
}
