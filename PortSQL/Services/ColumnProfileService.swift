import Foundation

/// A column's figures over every row its query would return, computed by the database rather than
/// from the loaded rows.
struct ServerColumnProfile: Equatable, Sendable {
    let nonNull: Int
    let distinct: Int?
    let minimum: String?
    let maximum: String?
    let average: String?
}

struct ServerResultProfile: Equatable, Sendable {
    let rowCount: Int
    /// By column index in the result.
    let columns: [Int: ServerColumnProfile]
}

/// Profiles a SQL result on the server with one read-only aggregate query over its source, without the
/// LIMIT or OFFSET that paged it. Only read-only statements without named parameters are profiled, and
/// the query runs under the read-only execution policy.
enum ColumnProfileService {
    /// Wide results are profiled on their first columns, so the query stays a reasonable size.
    static let maximumColumns = 60

    static func canProfile(_ result: QueryResultTable, engine: DatabaseEngine) -> Bool {
        query(for: result, kinds: [:], engine: engine) != nil
    }

    /// The aggregate query: COUNT(*), then for each column its non-NULL count, and where the type allows,
    /// distinct count, minimum, maximum and average. Columns are read back by position.
    static func query(for result: QueryResultTable, kinds: [Int: ColumnInsight.Kind], engine: DatabaseEngine) -> String? {
        guard engine.isSQL, let source = result.sourceQuery,
              result.documents == nil, !result.columns.isEmpty else { return nil }
        var inner = VisualizationService.queryWithoutLimitAndOffset(source).trimmingCharacters(in: .whitespacesAndNewlines)
        inner = VisualizationService.queryWithoutTrailingOrderBy(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        while inner.hasSuffix(";") { inner.removeLast(); inner = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        let upper = inner.uppercased()
        guard upper.hasPrefix("SELECT") || upper.hasPrefix("WITH"),
              SQLSafetyService.isReadOnlySQL(inner, engine: engine),
              SQLEditingService.statementRanges(in: inner, engine: engine).count <= 1,
              QueryParameterService.parameters(in: inner, engine: engine).isEmpty else { return nil }
        // A subquery can't expose two columns with one name.
        let names = result.columns.map(\.name)
        guard Set(names.map { $0.lowercased() }).count == names.count else { return nil }

        var expressions = ["COUNT(*)"]
        for index in result.columns.indices.prefix(maximumColumns) {
            let column = "p." + SQLTemplateService.identifier(result.columns[index].name, engine: engine)
            let kind = kinds[index] ?? .text
            expressions.append("COUNT(\(column))")
            // JSON and binary values can't be compared in every database, and PostgreSQL has no MIN of a boolean.
            let comparable = kind == .numeric || kind == .temporal || kind == .text || (kind == .boolean && engine != .postgresql)
            expressions.append(comparable ? "COUNT(DISTINCT \(column))" : "NULL")
            expressions.append(comparable ? "MIN(\(column))" : "NULL")
            expressions.append(comparable ? "MAX(\(column))" : "NULL")
            expressions.append(kind == .numeric ? "AVG(\(column))" : "NULL")
        }
        return "SELECT " + expressions.joined(separator: ", ") + " FROM (" + inner + ") AS p"
    }

    static func profile(from row: QueryRow, columnCount: Int) -> ServerResultProfile? {
        let cells = row.cells
        guard let total = cells.first.flatMap(integer) else { return nil }
        var columns: [Int: ServerColumnProfile] = [:]
        for index in 0..<min(columnCount, maximumColumns) {
            let base = 1 + index * 5
            guard cells.count >= base + 5, let nonNull = integer(cells[base]) else { continue }
            columns[index] = ServerColumnProfile(nonNull: nonNull, distinct: integer(cells[base + 1]),
                                                 minimum: text(cells[base + 2]), maximum: text(cells[base + 3]),
                                                 average: text(cells[base + 4]))
        }
        return ServerResultProfile(rowCount: total, columns: columns)
    }

    static func run(result: QueryResultTable, kinds: [Int: ColumnInsight.Kind], profile: ConnectionProfile,
                    database: String?) async throws -> ServerResultProfile {
        guard let sql = query(for: result, kinds: kinds, engine: profile.engine) else { throw DatabaseServiceError.readOnlyQueryRequired }
        let table = try await DatabaseService.shared.execute(query: sql, profile: profile, database: database, policy: .readOnly)
        guard let row = table.rows.first, let summary = Self.profile(from: row, columnCount: result.columns.count) else {
            throw DatabaseServiceError.unsupported
        }
        return summary
    }

    private static func integer(_ cell: QueryCell) -> Int? {
        switch cell {
        case .integer(let text), .decimal(let text), .text(let text): Int(text) ?? Double(text).flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
        default: nil
        }
    }

    private static func text(_ cell: QueryCell) -> String? { cell.isNull ? nil : cell.displayValue }
}
