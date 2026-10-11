import Foundation

/// A query plan as a tree of operations, parsed from EXPLAIN output.
struct QueryPlan: Equatable {
    struct Node: Identifiable, Equatable {
        let id: Int
        let depth: Int
        let title: String
        var details: [String]
        let startupCost: Double?
        let totalCost: Double?
        let estimatedRows: Double?
        var warning: Warning?
    }

    enum Warning: Equatable {
        case fullScan, temporarySort, temporaryTable

        var title: String {
            switch self {
            case .fullScan: L10n.text("Full table scan")
            case .temporarySort: L10n.text("Sort without an index")
            case .temporaryTable: L10n.text("Temporary table")
            }
        }
    }

    let nodes: [Node]

    var maximumCost: Double { nodes.compactMap(\.totalCost).max() ?? 0 }
    var warningCount: Int { nodes.filter { $0.warning != nil }.count }
}

enum QueryPlanService {
    static func isExplainResult(_ result: QueryResultTable) -> Bool {
        let statement = (result.sourceQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return statement.hasPrefix("EXPLAIN") && !result.rows.isEmpty
    }

    static func plan(from result: QueryResultTable, engine: DatabaseEngine) -> QueryPlan? {
        let names = result.columns.map { $0.name.lowercased() }
        func column(_ name: String) -> Int? { names.firstIndex(of: name) }
        func value(_ row: QueryRow, _ index: Int?) -> String? {
            guard let index, row.cells.indices.contains(index), !row.cells[index].isNull else { return nil }
            return row.cells[index].displayValue
        }

        if engine == .sqlite, let id = column("id"), let parent = column("parent"), let detail = column("detail") {
            return sqlitePlan(result.rows.map { (Int(value($0, id) ?? "") ?? 0, Int(value($0, parent) ?? "") ?? 0, value($0, detail) ?? "") })
        }
        if engine.isMySQLFamily, column("select_type") != nil, let table = column("table") {
            return mysqlPlan(result, tableIndex: table, column: column, value: value)
        }
        // PostgreSQL ("QUERY PLAN") and ClickHouse ("explain") return one indented line per row.
        if result.columns.count == 1 {
            return indentedPlan(result.rows.compactMap { value($0, 0) })
        }
        return nil
    }

    // MARK: PostgreSQL and ClickHouse text plans

    static func indentedPlan(_ lines: [String]) -> QueryPlan? {
        var nodes: [QueryPlan.Node] = []
        var depthByIndent: [(indent: Int, depth: Int)] = []
        for (offset, raw) in lines.enumerated() {
            let indent = raw.prefix(while: { $0 == " " }).count
            var text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let isNode = offset == 0 || text.hasPrefix("->")
            if text.hasPrefix("->") { text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            guard isNode || nodes.isEmpty else {
                nodes[nodes.count - 1].details.append(text)
                continue
            }
            while let last = depthByIndent.last, last.indent >= indent { depthByIndent.removeLast() }
            let depth = (depthByIndent.last?.depth ?? -1) + 1
            depthByIndent.append((indent, depth))
            let (title, startup, total, rows) = splitCost(text)
            nodes.append(QueryPlan.Node(id: nodes.count, depth: depth, title: title, details: [], startupCost: startup,
                                        totalCost: total, estimatedRows: rows, warning: warning(for: title)))
        }
        return nodes.isEmpty ? nil : QueryPlan(nodes: nodes)
    }

    /// Splits "Seq Scan on t  (cost=0.00..1.12 rows=12 width=48)" into its title, costs, and row estimate.
    static func splitCost(_ text: String) -> (String, Double?, Double?, Double?) {
        guard let open = text.range(of: "(cost="), let close = text[open.upperBound...].firstIndex(of: ")") else {
            return (text, nil, nil, nil)
        }
        let body = text[open.upperBound..<close]
        let parts = body.split(separator: " ")
        let costs = parts.first?.components(separatedBy: "..") ?? []
        let rows = parts.first { $0.hasPrefix("rows=") }.flatMap { Double($0.dropFirst(5)) }
        let title = text[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return (title, costs.first.flatMap(Double.init), costs.count > 1 ? Double(costs[1]) : nil, rows)
    }

    // MARK: SQLite

    private static func sqlitePlan(_ rows: [(id: Int, parent: Int, detail: String)]) -> QueryPlan? {
        var depths: [Int: Int] = [0: -1]
        var nodes: [QueryPlan.Node] = []
        for row in rows {
            let depth = (depths[row.parent] ?? -1) + 1
            depths[row.id] = depth
            nodes.append(QueryPlan.Node(id: nodes.count, depth: depth, title: row.detail, details: [], startupCost: nil,
                                        totalCost: nil, estimatedRows: nil, warning: warning(for: row.detail)))
        }
        return nodes.isEmpty ? nil : QueryPlan(nodes: nodes)
    }

    // MARK: MySQL and MariaDB

    private static func mysqlPlan(_ result: QueryResultTable, tableIndex: Int, column: (String) -> Int?,
                                  value: (QueryRow, Int?) -> String?) -> QueryPlan? {
        let nodes = result.rows.enumerated().map { offset, row -> QueryPlan.Node in
            let access = value(row, column("type")) ?? ""
            let table = value(row, tableIndex) ?? ""
            let key = value(row, column("key"))
            let extra = value(row, column("extra")) ?? ""
            var details: [String] = []
            if let key { details.append(L10n.format("Index: %@", key)) }
            if let possible = value(row, column("possible_keys")) { details.append(L10n.format("Possible indexes: %@", possible)) }
            if !extra.isEmpty { details.append(extra) }
            let title = [value(row, column("select_type")), access.isEmpty ? nil : access.uppercased(), table].compactMap { $0 }.joined(separator: " · ")
            var warning: QueryPlan.Warning?
            if access.uppercased() == "ALL" { warning = .fullScan }
            else if extra.localizedCaseInsensitiveContains("filesort") { warning = .temporarySort }
            else if extra.localizedCaseInsensitiveContains("temporary") { warning = .temporaryTable }
            return QueryPlan.Node(id: offset, depth: 0, title: title, details: details, startupCost: nil, totalCost: nil,
                                  estimatedRows: value(row, column("rows")).flatMap(Double.init), warning: warning)
        }
        return nodes.isEmpty ? nil : QueryPlan(nodes: nodes)
    }

    // MARK: Warnings

    static func warning(for title: String) -> QueryPlan.Warning? {
        let text = title.lowercased()
        if text.hasPrefix("seq scan") || text.hasPrefix("parallel seq scan") || text.hasPrefix("scan ") || text == "scan"
            || text.contains("full scan") || text.hasPrefix("readfrommergetree") && text.contains("full") {
            return .fullScan
        }
        if text.contains("temp b-tree") || (text.hasPrefix("sort") && !text.contains("index")) { return .temporarySort }
        if text.contains("temporary") { return .temporaryTable }
        return nil
    }
}
