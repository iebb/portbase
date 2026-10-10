import Foundation

enum SchemaObjectKind: String, Codable, CaseIterable {
    case table, view, materializedView, function, procedure
    var title: String {
        switch self {
        case .table: L10n.text("Tables")
        case .view: L10n.text("Views")
        case .materializedView: L10n.text("Materialized Views")
        case .function: L10n.text("Functions")
        case .procedure: L10n.text("Procedures")
        }
    }
    var symbol: String {
        switch self { case .table: "tablecells"; case .view, .materializedView: "eye"; case .function, .procedure: "function" }
    }
}

struct SchemaObject: Identifiable, Hashable {
    let id: String
    let schema: String
    let name: String
    let kind: SchemaObjectKind
    var signature = ""
    var displayName: String { schema + "." + name + (signature.isEmpty ? "" : "(" + signature + ")") }
}

struct SchemaForeignKey: Identifiable, Hashable {
    let id: String
    let name: String
    let columns: [String]
    let referencedSchema: String
    let referencedTable: String
    let referencedColumns: [String]
    var summary: String { columns.joined(separator: ", ") + " → " + referencedSchema + "." + referencedTable + " (" + referencedColumns.joined(separator: ", ") + ")" }
}

struct SchemaObjectDetails {
    var definition = ""
    var indexes: [String] = []
    var constraints: [String] = []
    var foreignKeys: [SchemaForeignKey] = []
}

extension QueryResultTable {
    func records() -> [[String: QueryCell]] {
        rows.map { row in
            var values: [String: QueryCell] = [:]
            for index in columns.indices where row.cells.indices.contains(index) { values[columns[index].name] = row.cells[index] }
            return values
        }
    }
}
