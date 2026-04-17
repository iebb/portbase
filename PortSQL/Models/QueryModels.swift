import Foundation

struct QueryColumn: Identifiable, Codable, Hashable {
    let id = UUID()
    let name: String
    let type: String

    private enum CodingKeys: String, CodingKey {
        case name
        case type
    }
}

struct QueryRow: Identifiable, Codable, Hashable {
    let id = UUID()
    var values: [String]

    private enum CodingKeys: String, CodingKey {
        case values
    }
}

enum DataEditorMode: String, Hashable {
    case view
    case insert
    case update

    var title: String {
        switch self {
        case .view:
            "View Row"
        case .insert:
            "Insert Row"
        case .update:
            "Edit Row"
        }
    }
}

struct DataEditorField: Identifiable, Hashable {
    var id: UUID { column.id }
    let column: SchemaColumnDescriptor
    var value: String
    let originalValue: String?
    let isEditable: Bool
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

struct SchemaColumnDescriptor: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let isUnique: Bool
}

struct SchemaTableDescriptor: Identifiable, Hashable {
    let id = UUID()
    let schemaName: String
    let name: String
    let columns: [SchemaColumnDescriptor]
    let rowCountEstimate: Int?

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
            return "Add Column"
        case .edit:
            return "Edit Column"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .add:
            return "Add"
        case .edit:
            return "Save"
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

struct QueryHistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var sql: String
    var connectionName: String
    var summary: String
    var executedAt: Date = .now
}

struct SavedQuerySnippet: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var sql: String
    var note: String = ""
    var createdAt: Date = .now
}

struct QueryResultTable: Codable, Hashable {
    var columns: [QueryColumn]
    var rows: [QueryRow]
    var executionSummary: String
    var generatedMutation: String?
    var profiles: [QueryColumnProfile]
    var sourceTableReference: String?
    var sourceQuery: String?

    static let empty = QueryResultTable(
        columns: [],
        rows: [],
        executionSummary: "Connect to a database and run a query to inspect live rows.",
        generatedMutation: nil,
        profiles: [],
        sourceTableReference: nil,
        sourceQuery: nil
    )
}
