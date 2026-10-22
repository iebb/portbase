import Foundation

struct QueryColumn: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    /// The table column this result column came from, as the database reports it, or nil for a computed
    /// value. Editing a query's results relies on this, never on reading the SQL text.
    var origin: QueryColumnOrigin? = nil

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case origin
    }
}

/// Where a result column came from, from the database's own result metadata: MySQL's original table and
/// column, SQLite's column origin, or PostgreSQL's table OID and attribute number until they're resolved
/// to names.
struct QueryColumnOrigin: Codable, Hashable, Sendable {
    var schema: String?
    var table: String?
    var column: String?
    var postgresTableOID: UInt32?
    var postgresAttributeNumber: Int?

    /// Whether the table and column are known by name.
    var isResolved: Bool { table?.isEmpty == false && column?.isEmpty == false }
}

enum QueryCell: Codable, Hashable, Sendable {
    case null
    case text(String)
    case integer(String)
    case decimal(String)
    case boolean(Bool)
    case dateTime(String)
    case json(String)
    case binary(Data)

    var displayValue: String {
        switch self {
        case .null:
            return ""
        case .text(let value), .integer(let value), .decimal(let value),
             .dateTime(let value), .json(let value):
            return value
        case .boolean(let value):
            return value ? "true" : "false"
        case .binary(let value):
            return "0x" + value.map { String(format: "%02x", $0) }.joined()
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var isBinary: Bool {
        if case .binary = self { return true }
        return false
    }
}

struct QueryRow: Identifiable, Codable, Hashable {
    let id = UUID()
    var cells: [QueryCell]

    var values: [String] { cells.map(\.displayValue) }

    init(cells: [QueryCell]) {
        self.cells = cells
    }

    init(values: [String]) {
        self.cells = values.map(QueryCell.text)
    }

    private enum CodingKeys: String, CodingKey {
        case cells
        case values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cells = try container.decodeIfPresent([QueryCell].self, forKey: .cells) {
            self.cells = cells
        } else {
            self.cells = try container.decodeIfPresent([String].self, forKey: .values)?.map(QueryCell.text) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cells, forKey: .cells)
    }
}

enum DataEditorMode: String, Hashable {
    case view
    case insert
    case update

    var title: String {
        switch self {
        case .view:
            L10n.text("View Row")
        case .insert:
            L10n.text("Insert Row")
        case .update:
            L10n.text("Edit Row")
        }
    }
}

struct DataEditorField: Identifiable, Hashable {
    var id: UUID { column.id }
    let column: SchemaColumnDescriptor
    var value: String
    let originalValue: String?
    var isNull: Bool
    let originalIsNull: Bool?
    let isEditable: Bool

    init(
        column: SchemaColumnDescriptor,
        value: String,
        originalValue: String?,
        isNull: Bool = false,
        originalIsNull: Bool? = nil,
        isEditable: Bool
    ) {
        self.column = column
        self.value = value
        self.originalValue = originalValue
        self.isNull = isNull
        self.originalIsNull = originalIsNull
        self.isEditable = isEditable
    }
}

/// Identifies a staged cell edit: the loaded row and the column's normalized name.
struct PendingCellKey: Hashable {
    let rowID: QueryRow.ID
    let column: Int
}

/// An action that would replace loaded rows with staged edits, waiting for Discard or Keep Editing.
struct PendingDiscardRequest: Identifiable {
    let id = UUID()
    let proceed: () -> Void
    let cancel: (() -> Void)?
}

struct DataEditorDraft: Identifiable, Hashable {
    let id = UUID()
    let mode: DataEditorMode
    let table: SchemaTableDescriptor
    var fields: [DataEditorField]
    let rowID: QueryRow.ID?
}

struct NumericSeriesPoint: Identifiable, Codable, Hashable {
    let id = UUID()
    let label: String
    let value: Double

    private enum CodingKeys: String, CodingKey {
        case label
        case value
    }
}

struct QueryColumnProfile: Identifiable, Codable, Hashable {
    let id = UUID()
    let columnName: String
    let rowCount: Int
    let nullCount: Int
    let distinctCount: Int
    let numericSeries: [NumericSeriesPoint]

    private enum CodingKeys: String, CodingKey {
        case columnName
        case rowCount
        case nullCount
        case distinctCount
        case numericSeries
    }
}

struct SchemaColumnDescriptor: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let isUnique: Bool
    var isGenerated: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case isNullable
        case isPrimaryKey
        case isGenerated
        case isUnique
    }
}

struct SchemaTableDescriptor: Identifiable, Codable, Hashable {
    let id = UUID()
    let schemaName: String
    let name: String
    let columns: [SchemaColumnDescriptor]
    let rowCountEstimate: Int?
    var objectKind: SchemaObjectKind? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaName
        case name
        case columns
        case rowCountEstimate
        case objectKind
    }

    var displayName: String {
        schemaName.isEmpty ? name : "\(schemaName).\(name)"
    }

    var primaryKeyColumns: [SchemaColumnDescriptor] {
        columns.filter(\.isPrimaryKey)
    }

    var uniqueColumns: [SchemaColumnDescriptor] {
        columns.filter(\.isUnique)
    }

    var editingIdentifierColumns: [SchemaColumnDescriptor] {
        if !primaryKeyColumns.isEmpty {
            return primaryKeyColumns
        }
        return uniqueColumns
    }

    func matches(reference: String) -> Bool {
        let normalizedReference = Self.normalize(reference)
        return normalizedReference == Self.normalize(displayName)
            || normalizedReference == Self.normalize(name)
    }

    func column(named name: String) -> SchemaColumnDescriptor? {
        let normalized = Self.normalize(name)
        return columns.first { Self.normalize($0.name) == normalized }
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum SchemaColumnEditorMode: Hashable {
    case add
    case edit

    var title: String {
        switch self {
        case .add:
            return L10n.text("Add Column")
        case .edit:
            return L10n.text("Edit Column")
        }
    }

    var confirmationTitle: String {
        switch self {
        case .add:
            return L10n.text("Add")
        case .edit:
            return L10n.text("Save")
        }
    }
}

struct SchemaColumnDraft: Identifiable, Hashable {
    let id = UUID()
    let mode: SchemaColumnEditorMode
    let table: SchemaTableDescriptor
    let originalColumn: SchemaColumnDescriptor?
    var name: String
    var type: String
    var isNullable: Bool

    var originalName: String? {
        originalColumn?.name
    }

    static func add(to table: SchemaTableDescriptor) -> SchemaColumnDraft {
        SchemaColumnDraft(
            mode: .add,
            table: table,
            originalColumn: nil,
            name: "",
            type: "",
            isNullable: true
        )
    }

    static func edit(_ column: SchemaColumnDescriptor, in table: SchemaTableDescriptor) -> SchemaColumnDraft {
        SchemaColumnDraft(
            mode: .edit,
            table: table,
            originalColumn: column,
            name: column.name,
            type: column.type,
            isNullable: column.isNullable
        )
    }
}

struct SchemaColumnDeletionTarget: Identifiable, Hashable {
    let id = UUID()
    let table: SchemaTableDescriptor
    let column: SchemaColumnDescriptor
}

enum QueryHistoryOutcome: String, Codable, CaseIterable {
    case succeeded, failed, cancelled

    var title: String {
        switch self {
        case .succeeded: L10n.text("Succeeded")
        case .failed: L10n.text("Failed")
        case .cancelled: L10n.text("Cancelled")
        }
    }
}

struct QueryHistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var sql: String
    var connectionName: String
    var summary: String
    var executedAt: Date = .now
    var bookmarkID: UUID?
    var database: String?
    var engine: DatabaseEngine?
    var duration: TimeInterval?
    var outcome: QueryHistoryOutcome?
}

struct SavedQuerySnippet: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var sql: String
    var note: String = ""
    var createdAt: Date = .now
    var updatedAt: Date?
    var bookmarkID: UUID?
    var database: String?
    var engine: DatabaseEngine?
    /// The folder the query is filed in, by name; nil for none. Optional, so older copies decode and
    /// field-by-field sync keeps a folder change made on another device.
    var folder: String?
}

/// Saved queries grouped for the library: each folder in name order, then the queries in no folder.
enum SavedQueryGrouping {
    static func groups(_ snippets: [SavedQuerySnippet]) -> [(folder: String?, snippets: [SavedQuerySnippet])] {
        let grouped = Dictionary(grouping: snippets) { snippet in
            snippet.folder.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        let folders = grouped.keys.compactMap { $0 }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return folders.map { ($0, grouped[$0] ?? []) } + (grouped[nil].map { [(nil, $0)] } ?? [])
    }

    static func folders(_ snippets: [SavedQuerySnippet]) -> [String] {
        groups(snippets).compactMap(\.folder)
    }
}

struct QueryResultTable: Codable, Hashable {
    var columns: [QueryColumn]
    var rows: [QueryRow]
    var executionSummary: String
    var generatedMutation: String?
    var profiles: [QueryColumnProfile]
    var sourceTableReference: String?
    var sourceQuery: String?
    var affectedRowCount: Int?
    var isTruncated: Bool?
    var isExplorerGenerated: Bool?
    // Canonical Extended JSON preserves BSON types and missing fields in exports.
    var documents: [String]? = nil

    static let empty = QueryResultTable(
        columns: [],
        rows: [],
        executionSummary: L10n.text("Connect to a database and run a query to inspect live rows."),
        generatedMutation: nil,
        profiles: [],
        sourceTableReference: nil,
        sourceQuery: nil,
        affectedRowCount: nil,
        isTruncated: false,
        isExplorerGenerated: false
    )

    init(
        columns: [QueryColumn],
        rows: [QueryRow],
        executionSummary: String,
        generatedMutation: String?,
        profiles: [QueryColumnProfile],
        sourceTableReference: String?,
        sourceQuery: String? = nil,
        affectedRowCount: Int? = nil,
        isTruncated: Bool = false,
        isExplorerGenerated: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.executionSummary = executionSummary
        self.generatedMutation = generatedMutation
        self.profiles = profiles
        self.sourceTableReference = sourceTableReference
        self.sourceQuery = sourceQuery
        self.affectedRowCount = affectedRowCount
        self.isTruncated = isTruncated
        self.isExplorerGenerated = isExplorerGenerated
    }
}

extension QueryResultTable {
    static func disambiguatedColumnNames(_ names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return names.map { name in
            let next = (counts[name] ?? 0) + 1
            counts[name] = next
            return next == 1 ? name : "\(name)_\(next)"
        }
    }
}
