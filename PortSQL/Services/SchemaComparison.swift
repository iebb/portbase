import Foundation

/// The differences between two databases' tables and columns, as schema compare in DataGrip and Navicat
/// shows them: tables only on one side, and for tables on both, columns added, removed, or changed.
struct SchemaComparison: Equatable {
    struct ColumnChange: Equatable, Identifiable {
        enum Kind: Equatable { case onlyInSource, onlyInTarget, changed }
        let kind: Kind
        let column: String
        /// What differs for a changed column, such as "integer → bigint" or "NOT NULL → NULL".
        let details: [String]
        var id: String { column + "|" + String(describing: kind) }
    }

    struct TableChange: Equatable, Identifiable {
        enum Kind: Equatable { case onlyInSource, onlyInTarget, changed }
        let kind: Kind
        let name: String
        let columns: [ColumnChange]
        var id: String { name }
    }

    let tables: [TableChange]
    let identicalTables: Int

    var onlyInSource: [TableChange] { tables.filter { $0.kind == .onlyInSource } }
    var onlyInTarget: [TableChange] { tables.filter { $0.kind == .onlyInTarget } }
    var changed: [TableChange] { tables.filter { $0.kind == .changed } }
    var isIdentical: Bool { tables.isEmpty }

    static func compare(source: [SchemaTableDescriptor], target: [SchemaTableDescriptor]) -> SchemaComparison {
        // Staging and production databases usually differ in name, so with one schema a side, tables
        // match by name alone; with several, the schema is part of the name.
        let qualify = Set(source.map(\.schemaName)).count > 1 || Set(target.map(\.schemaName)).count > 1
        func key(_ table: SchemaTableDescriptor) -> String { (qualify ? table.schemaName + "." : "") + table.name.lowercased() }
        func label(_ table: SchemaTableDescriptor) -> String { qualify ? table.schemaName + "." + table.name : table.name }
        let left = Dictionary(source.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let right = Dictionary(target.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [TableChange] = []
        var identical = 0
        for name in Set(left.keys).union(right.keys).sorted() {
            switch (left[name], right[name]) {
            case let (a?, nil): changes.append(TableChange(kind: .onlyInSource, name: label(a), columns: []))
            case let (nil, b?): changes.append(TableChange(kind: .onlyInTarget, name: label(b), columns: []))
            case let (a?, b?):
                let columns = compareColumns(a, b)
                if columns.isEmpty { identical += 1 } else { changes.append(TableChange(kind: .changed, name: label(a), columns: columns)) }
            default: break
            }
        }
        return SchemaComparison(tables: changes, identicalTables: identical)
    }

    private static func compareColumns(_ a: SchemaTableDescriptor, _ b: SchemaTableDescriptor) -> [ColumnChange] {
        let left = Dictionary(a.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let right = Dictionary(b.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        // Keep the source table's column order, then the target's extra columns in theirs.
        let order = a.columns.map { $0.name.lowercased() } + b.columns.map { $0.name.lowercased() }.filter { left[$0] == nil }
        return order.compactMap { name in
            switch (left[name], right[name]) {
            case let (x?, nil): return ColumnChange(kind: .onlyInSource, column: x.name, details: [x.type])
            case let (nil, y?): return ColumnChange(kind: .onlyInTarget, column: y.name, details: [y.type])
            case let (x?, y?):
                var details: [String] = []
                if normalized(x.type) != normalized(y.type) { details.append(x.type + " → " + y.type) }
                if x.isNullable != y.isNullable { details.append((x.isNullable ? "NULL" : "NOT NULL") + " → " + (y.isNullable ? "NULL" : "NOT NULL")) }
                if x.isPrimaryKey != y.isPrimaryKey { details.append(x.isPrimaryKey ? L10n.text("Primary key removed") : L10n.text("Primary key added")) }
                return details.isEmpty ? nil : ColumnChange(kind: .changed, column: x.name, details: details)
            default: return nil
            }
        }
    }

    /// Types compare without case or spacing differences, so INT(11) and int(11) match.
    private static func normalized(_ type: String) -> String {
        type.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// A plain-text report, for pasting into a ticket or review.
    func report(source: String, target: String) -> String {
        var lines = [L10n.format("Schema comparison: %1$@ → %2$@", source, target), ""]
        for table in tables {
            switch table.kind {
            case .onlyInSource: lines.append("- " + table.name + "  (" + L10n.format("only in %@", source) + ")")
            case .onlyInTarget: lines.append("+ " + table.name + "  (" + L10n.format("only in %@", target) + ")")
            case .changed:
                lines.append("~ " + table.name)
                for column in table.columns {
                    let mark = column.kind == .onlyInSource ? "-" : column.kind == .onlyInTarget ? "+" : "~"
                    lines.append("    " + mark + " " + column.column + "  " + column.details.joined(separator: ", "))
                }
            }
        }
        if tables.isEmpty { lines.append(L10n.text("No differences")) }
        return lines.joined(separator: "\n")
    }
}
