import Foundation

/// Which result columns can be edited, the table each one belongs to, and where that table's key is in
/// the result. A row of a table can be updated only when every column of its primary or unique key is in
/// the result, so the update can name exactly that row.
struct ResultEditPlan: Equatable {
    struct Target: Equatable {
        let table: SchemaTableDescriptor
        /// The key's columns and where each is in the result.
        let keyColumns: [KeyColumn]
    }

    struct KeyColumn: Equatable {
        let column: SchemaColumnDescriptor
        let resultIndex: Int
    }

    struct MappedColumn: Equatable {
        let target: Int
        let column: SchemaColumnDescriptor
        /// False for the key, which names the row, and for generated columns.
        let isEditable: Bool
    }

    let targets: [Target]
    /// Result column index to the table column it shows, for every column of an editable table.
    let columns: [Int: MappedColumn]

    /// The table column a result column updates, or nil when it can't be edited.
    func editableColumn(at index: Int) -> MappedColumn? { columns[index].flatMap { $0.isEditable ? $0 : nil } }

    /// The result columns that belong to one table, in result order.
    func columns(of target: Int) -> [(index: Int, column: MappedColumn)] {
        columns.filter { $0.value.target == target }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

enum ResultEditPlanner {
    /// An Explorer browse of one table, whose result columns are the table's own, by name: the rules row
    /// editing has always followed.
    static func explorerPlan(table: SchemaTableDescriptor, columns: [QueryColumn]) -> ResultEditPlan? {
        let names = columns.map { $0.name.lowercased() }
        guard Set(names).count == names.count else { return nil }
        let identifiers = table.editingIdentifierColumns
        var keys: [ResultEditPlan.KeyColumn] = []
        for identifier in identifiers {
            guard let index = names.firstIndex(of: identifier.name.lowercased()) else { return nil }
            keys.append(.init(column: identifier, resultIndex: index))
        }
        guard !keys.isEmpty else { return nil }
        var mapped: [Int: ResultEditPlan.MappedColumn] = [:]
        for (index, name) in names.enumerated() {
            guard let column = table.column(named: name) else { continue }
            mapped[index] = .init(target: 0, column: column, isEditable: editableColumn(column, keys: keys))
        }
        return ResultEditPlan(targets: [.init(table: table, keyColumns: keys)], columns: mapped)
    }

    /// A console query's results, mapped through the column origins the database reported. A table is
    /// editable only when its key columns are all in the result and none of its columns appears twice, as
    /// in a self-join; computed columns, views, and set operations like UNION stay read-only.
    static func originPlan(columns: [QueryColumn], statement: String, catalog: [SchemaTableDescriptor], engine: DatabaseEngine) -> ResultEditPlan? {
        let words = Set(SQLEditingService.codeWords(statement, engine: engine))
        guard words.isDisjoint(with: ["UNION", "INTERSECT", "EXCEPT", "MINUS"]) else { return nil }
        // Result columns grouped by the table the database says they came from.
        var groups: [String: [(index: Int, column: String, schema: String?, table: String)]] = [:]
        for (index, column) in columns.enumerated() {
            guard let origin = column.origin, origin.isResolved, let table = origin.table, let name = origin.column else { continue }
            let key = (origin.schema?.lowercased() ?? "") + "." + table.lowercased()
            groups[key, default: []].append((index, name, origin.schema, table))
        }
        var targets: [ResultEditPlan.Target] = []
        var mapped: [Int: ResultEditPlan.MappedColumn] = [:]
        for key in groups.keys.sorted() {
            let members = groups[key]!
            guard let first = members.first, let table = catalogTable(schema: first.schema, name: first.table, in: catalog),
                  table.objectKind == nil || table.objectKind == .table else { continue }
            // A column read twice could be two different rows, as in a self-join, so the table is left alone.
            let names = members.map { $0.column.lowercased() }
            guard Set(names).count == names.count else { continue }
            var keys: [ResultEditPlan.KeyColumn] = []
            for identifier in table.editingIdentifierColumns {
                guard let member = members.first(where: { $0.column.lowercased() == identifier.name.lowercased() }) else { keys = []; break }
                keys.append(.init(column: identifier, resultIndex: member.index))
            }
            guard !keys.isEmpty else { continue }
            let target = targets.count
            targets.append(.init(table: table, keyColumns: keys))
            for member in members {
                guard let column = table.column(named: member.column) else { continue }
                mapped[member.index] = .init(target: target, column: column, isEditable: editableColumn(column, keys: keys))
            }
        }
        return targets.isEmpty ? nil : ResultEditPlan(targets: targets, columns: mapped)
    }

    /// Keys identify the row, so they aren't edited in place; generated columns are the database's.
    private static func editableColumn(_ column: SchemaColumnDescriptor, keys: [ResultEditPlan.KeyColumn]) -> Bool {
        column.isGenerated != true && !keys.contains { $0.column.name.lowercased() == column.name.lowercased() }
    }

    /// The catalog's table for an origin, by schema when the database named one, else by a unique name.
    private static func catalogTable(schema: String?, name: String, in catalog: [SchemaTableDescriptor]) -> SchemaTableDescriptor? {
        let lower = name.lowercased()
        let named = catalog.filter { $0.name.lowercased() == lower }
        // A schema the database names must match: a same-named table in another schema is a different table.
        if let schema, !schema.isEmpty { return named.first { $0.schemaName.lowercased() == schema.lowercased() } }
        return named.count == 1 ? named.first : nil
    }
}
