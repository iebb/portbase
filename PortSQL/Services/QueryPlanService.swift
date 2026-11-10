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
        /// From EXPLAIN ANALYZE: milliseconds per loop, rows per loop, and how many times the step ran.
        var actualTime: Double? = nil
        var actualRows: Double? = nil
        var loops: Double? = nil

        /// The node took its estimate far from what happened: ten times off, on a step with real rows.
        var isMisestimated: Bool {
            guard let estimated = estimatedRows, let actual = actualRows, (loops ?? 1) > 0 else { return false }
            let high = max(estimated, actual), low = max(min(estimated, actual), 1)
            return high >= 100 && high / low >= 10
        }
    }

    enum Warning: Equatable {
        case fullScan, temporarySort, temporaryTable, misestimate

        var title: String {
            switch self {
            case .fullScan: L10n.text("Full table scan")
            case .temporarySort: L10n.text("Sort without an index")
            case .temporaryTable: L10n.text("Temporary table")
            case .misestimate: L10n.text("Row estimate far off")
            }
        }
    }

    let nodes: [Node]
    /// From EXPLAIN ANALYZE, in milliseconds.
    var planningTime: Double? = nil
    var executionTime: Double? = nil

    var maximumCost: Double { nodes.compactMap(\.totalCost).max() ?? 0 }
    var warningCount: Int { nodes.filter { $0.warning != nil }.count }
}

enum QueryPlanService {
    static func isExplainResult(_ result: QueryResultTable) -> Bool {
        let statement = (result.sourceQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return statement.hasPrefix("EXPLAIN") && !result.rows.isEmpty
    }

    /// Whether the plan came from EXPLAIN ANALYZE, which ran the query.
    static func isAnalyzed(_ result: QueryResultTable) -> Bool {
        let statement = (result.sourceQuery ?? "").uppercased()
        return statement.hasPrefix("EXPLAIN ANALYZE") || statement.hasPrefix("EXPLAIN (ANALYZE")
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
        if result.columns.count == 1 {
            let lines = result.rows.compactMap { value($0, 0) }
            // PostgreSQL's FORMAT JSON: one cell holding the whole plan.
            if engine == .postgresql, lines.count == 1, let plan = postgresJSONPlan(lines[0]) { return plan }
            // PostgreSQL and ClickHouse text plans have one indented line per row; MySQL's
            // EXPLAIN ANALYZE puts its whole tree in one cell.
            return indentedPlan(lines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) })
        }
        return nil
    }

    // MARK: PostgreSQL JSON plans

    static func postgresJSONPlan(_ json: String) -> QueryPlan? {
        guard json.first == "[" || json.first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let root = (object as? [[String: Any]])?.first ?? (object as? [String: Any]),
              let top = root["Plan"] as? [String: Any] else { return nil }
        var nodes: [QueryPlan.Node] = []
        func visit(_ plan: [String: Any], depth: Int) {
            func number(_ key: String) -> Double? { (plan[key] as? NSNumber)?.doubleValue }
            func text(_ key: String) -> String? { (plan[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            var type = text("Node Type") ?? "?"
            if let join = text("Join Type"), join != "Inner", type.hasSuffix("Join") {
                type = String(type.dropLast(4)) + join + " Join"
            }
            if let strategy = text("Strategy"), type == "Aggregate", strategy != "Plain" { type = strategy + "Aggregate" }
            let target = text("Relation Name") ?? text("CTE Name") ?? text("Function Name")
            var title = type
            if let index = text("Index Name") { title += " using " + index }
            if let target { title += " on " + target + (text("Alias").map { $0 == target ? "" : " " + $0 } ?? "") }
            if let relationship = text("Subplan Name") { title = relationship + ": " + title }

            var details: [String] = []
            for key in ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "One-Time Filter"] {
                if let value = text(key) { details.append(key + ": " + value) }
            }
            for key in ["Sort Key", "Group Key", "Presorted Key"] {
                if let keys = plan[key] as? [String], !keys.isEmpty { details.append(key + ": " + keys.joined(separator: ", ")) }
            }
            if let method = text("Sort Method") {
                let space = [text("Sort Space Type"), number("Sort Space Used").map { "\(Int($0))kB" }].compactMap { $0 }.joined(separator: " ")
                details.append("Sort Method: " + method + (space.isEmpty ? "" : "  " + space))
            }
            for key in ["Rows Removed by Filter", "Rows Removed by Index Recheck", "Rows Removed by Join Filter"] {
                if let removed = number(key), removed > 0 { details.append(key + ": " + Int(removed).formatted()) }
            }
            let hit = number("Shared Hit Blocks") ?? 0, read = number("Shared Read Blocks") ?? 0
            if hit + read > 0 { details.append("Buffers: shared hit=\(Int(hit)) read=\(Int(read))") }
            let loops = number("Actual Loops")
            if loops == 0 { details.append(L10n.text("Never executed")) }

            var node = QueryPlan.Node(id: nodes.count, depth: depth, title: title, details: details,
                                      startupCost: number("Startup Cost"), totalCost: number("Total Cost"),
                                      estimatedRows: number("Plan Rows"), warning: warning(for: title),
                                      actualTime: number("Actual Total Time"), actualRows: number("Actual Rows"), loops: loops)
            if text("Sort Space Type") == "Disk" { node.warning = .temporarySort }
            if node.warning == nil, node.isMisestimated { node.warning = .misestimate }
            nodes.append(node)
            for child in (plan["Plans"] as? [[String: Any]]) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(top, depth: 0)
        return QueryPlan(nodes: nodes, planningTime: (root["Planning Time"] as? NSNumber)?.doubleValue,
                         executionTime: (root["Execution Time"] as? NSNumber)?.doubleValue)
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
            let actual = splitActual(text)
            var node = QueryPlan.Node(id: nodes.count, depth: depth, title: title, details: [], startupCost: startup,
                                      totalCost: total, estimatedRows: rows, warning: warning(for: title),
                                      actualTime: actual?.time, actualRows: actual?.rows, loops: actual?.loops)
            if node.warning == nil, node.isMisestimated { node.warning = .misestimate }
            nodes.append(node)
        }
        return nodes.isEmpty ? nil : QueryPlan(nodes: nodes)
    }

    /// Splits "Seq Scan on t  (cost=0.00..1.12 rows=12 width=48)" into its title, costs, and row estimate.
    /// MySQL gives one cost, "(cost=1.25 rows=10)", which is the total.
    static func splitCost(_ text: String) -> (String, Double?, Double?, Double?) {
        let titleEnd = [text.range(of: "(cost="), text.range(of: "(actual ")].compactMap { $0?.lowerBound }.min()
        let title = titleEnd.map { text[..<$0].trimmingCharacters(in: .whitespaces) } ?? text
        guard let open = text.range(of: "(cost="), let close = text[open.upperBound...].firstIndex(of: ")") else {
            return (title, nil, nil, nil)
        }
        let body = text[open.upperBound..<close]
        let parts = body.split(separator: " ")
        let costs = parts.first?.components(separatedBy: "..") ?? []
        let rows = parts.first { $0.hasPrefix("rows=") }.flatMap { Double($0.dropFirst(5)) }
        if costs.count == 1 { return (title, nil, Double(costs[0]), rows) }
        return (title, costs.first.flatMap(Double.init), costs.count > 1 ? Double(costs[1]) : nil, rows)
    }

    /// Reads "(actual time=0.012..0.034 rows=10 loops=1)" from an analyzed plan line.
    static func splitActual(_ text: String) -> (time: Double?, rows: Double?, loops: Double?)? {
        if text.contains("(never executed)") { return (nil, 0, 0) }
        guard let open = text.range(of: "(actual "), let close = text[open.upperBound...].firstIndex(of: ")") else { return nil }
        var time: Double?, rows: Double?, loops: Double?
        for part in text[open.upperBound..<close].split(separator: " ") {
            if part.hasPrefix("time=") { time = part.dropFirst(5).components(separatedBy: "..").last.flatMap(Double.init) }
            else if part.hasPrefix("rows=") { rows = Double(part.dropFirst(5)) }
            else if part.hasPrefix("loops=") { loops = Double(part.dropFirst(6)) }
        }
        return (time, rows, loops)
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
