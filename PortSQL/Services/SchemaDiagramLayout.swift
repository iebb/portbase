import CoreGraphics
import Foundation

/// Places tables and their foreign keys for an entity-relationship diagram. Related tables are laid out
/// in columns outward from the most connected one, each column ordered to keep lines short; tables
/// with no relationships follow in a grid, or are left out.
struct SchemaDiagramLayout: Equatable {
    struct Column: Equatable {
        let name: String
        let type: String
        let isKey: Bool
        let isForeignKey: Bool
    }

    struct Node: Identifiable, Equatable {
        let id: String
        let table: SchemaTableDescriptor
        let columns: [Column]
        /// Columns not drawn, shown as "+N more".
        let hiddenColumns: Int
        var frame: CGRect
    }

    struct Edge: Identifiable, Equatable {
        let id: String
        let from: String
        let to: String
        /// The rows the line leaves and arrives at, or nil for the table's header.
        let fromRow: Int?
        let toRow: Int?
        let name: String
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var size: CGSize = .zero

    static let nodeWidth: CGFloat = 220
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 20
    static let maximumRows = 8
    static let columnGap: CGFloat = 96
    static let rowGap: CGFloat = 32
    static let margin: CGFloat = 24

    static func make(catalog: [SchemaTableDescriptor], relationships: [SchemaRelationship], includeUnrelated: Bool) -> SchemaDiagramLayout {
        func key(_ schema: String, _ table: String) -> String { schema.lowercased() + "." + table.lowercased() }
        var tables: [String: SchemaTableDescriptor] = [:]
        for table in catalog { tables[key(table.schemaName, table.name)] = table }
        // Only keys whose both ends are in the catalog; a reference to another database can't be drawn.
        let links = relationships.filter {
            tables[key($0.schema, $0.table)] != nil && tables[key($0.key.referencedSchema, $0.key.referencedTable)] != nil
        }
        var neighbors: [String: Set<String>] = [:]
        for link in links {
            let from = key(link.schema, link.table), to = key(link.key.referencedSchema, link.key.referencedTable)
            guard from != to else { neighbors[from, default: []].formUnion([]); continue }
            neighbors[from, default: []].insert(to)
            neighbors[to, default: []].insert(from)
        }
        for link in links where neighbors[key(link.schema, link.table)] == nil { neighbors[key(link.schema, link.table)] = [] }

        var foreignColumns: [String: Set<String>] = [:]
        for link in links { foreignColumns[key(link.schema, link.table), default: []].formUnion(link.key.columns) }

        func node(_ id: String, at origin: CGPoint) -> Node {
            let table = tables[id]!
            let keys = Set(table.primaryKeyColumns.map(\.name))
            let foreign = foreignColumns[id] ?? []
            // Keys first, then foreign keys, then the rest, as many as fit.
            let ordered = table.columns.filter { keys.contains($0.name) }
                + table.columns.filter { !keys.contains($0.name) && foreign.contains($0.name) }
                + table.columns.filter { !keys.contains($0.name) && !foreign.contains($0.name) }
            let shown = Array(ordered.prefix(maximumRows))
            let hidden = table.columns.count - shown.count
            let height = headerHeight + CGFloat(shown.count + (hidden > 0 ? 1 : 0)) * rowHeight + 8
            return Node(id: id, table: table,
                        columns: shown.map { Column(name: $0.name, type: $0.type, isKey: keys.contains($0.name), isForeignKey: foreign.contains($0.name)) },
                        hiddenColumns: max(0, hidden), frame: CGRect(origin: origin, size: CGSize(width: nodeWidth, height: height)))
        }

        var layout = SchemaDiagramLayout()
        var placed = Set<String>()
        var cursorY = margin
        var width: CGFloat = 0
        // Connected groups, largest first, each laid out in columns by distance from its busiest table.
        let ordered = neighbors.keys.sorted { (neighbors[$0]!.count, $1) > (neighbors[$1]!.count, $0) }
        for root in ordered where !placed.contains(root) {
            var levels: [[String]] = [[root]]
            var seen: Set<String> = [root]
            while let last = levels.last {
                let next = last.flatMap { neighbors[$0] ?? [] }.filter { !seen.contains($0) }
                let unique = Array(Set(next)).sorted()
                guard !unique.isEmpty else { break }
                seen.formUnion(unique)
                // Order by the average position of each table's neighbors in the previous column.
                let position = Dictionary(uniqueKeysWithValues: last.enumerated().map { ($1, Double($0)) })
                levels.append(unique.sorted { a, b in
                    func center(_ id: String) -> Double {
                        let values = (neighbors[id] ?? []).compactMap { position[$0] }
                        return values.isEmpty ? .greatestFiniteMagnitude : values.reduce(0, +) / Double(values.count)
                    }
                    return (center(a), a) < (center(b), b)
                })
            }
            var groupHeight: CGFloat = 0
            for (column, ids) in levels.enumerated() {
                var y = cursorY
                for id in ids {
                    let item = node(id, at: CGPoint(x: margin + CGFloat(column) * (nodeWidth + columnGap), y: y))
                    layout.nodes.append(item)
                    y += item.frame.height + rowGap
                    placed.insert(id)
                }
                groupHeight = max(groupHeight, y - cursorY)
                width = max(width, margin + CGFloat(column + 1) * (nodeWidth + columnGap) - columnGap + margin)
            }
            cursorY += groupHeight + rowGap
        }

        if includeUnrelated {
            let rest = tables.keys.filter { !placed.contains($0) }.sorted()
            let perRow = max(1, min(5, Int((max(width, 900) - margin) / (nodeWidth + columnGap / 2))))
            var rowTop = cursorY, rowHeight: CGFloat = 0
            for (index, id) in rest.enumerated() {
                if index > 0, index % perRow == 0 { rowTop += rowHeight + rowGap; rowHeight = 0 }
                let item = node(id, at: CGPoint(x: margin + CGFloat(index % perRow) * (nodeWidth + columnGap / 2), y: rowTop))
                layout.nodes.append(item)
                rowHeight = max(rowHeight, item.frame.height)
                width = max(width, item.frame.maxX + margin)
            }
            if !rest.isEmpty { cursorY = rowTop + rowHeight + rowGap }
        }

        let rows = Dictionary(uniqueKeysWithValues: layout.nodes.map { node in
            (node.id, Dictionary(node.columns.enumerated().map { ($1.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }))
        })
        layout.edges = links.map { link in
            let from = key(link.schema, link.table), to = key(link.key.referencedSchema, link.key.referencedTable)
            return Edge(id: link.key.id, from: from, to: to,
                        fromRow: link.key.columns.first.flatMap { rows[from]?[$0.lowercased()] },
                        toRow: link.key.referencedColumns.first.flatMap { rows[to]?[$0.lowercased()] },
                        name: link.key.name)
        }
        layout.size = CGSize(width: max(width, margin * 2 + nodeWidth), height: max(cursorY - rowGap + margin, margin * 2))
        return layout
    }

    /// Where a line meets a table: the middle of a column's row, or of the header.
    static func anchor(_ frame: CGRect, row: Int?, trailing: Bool) -> CGPoint {
        let y = row.map { frame.minY + headerHeight + (CGFloat($0) + 0.5) * rowHeight } ?? frame.minY + headerHeight / 2
        return CGPoint(x: trailing ? frame.maxX : frame.minX, y: y)
    }
}
