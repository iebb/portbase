import Foundation

enum ChartQueryError: LocalizedError, Equatable {
    case missingQuery
    case missingConnection
    case missingValues([String])

    var errorDescription: String? {
        switch self {
        case .missingQuery: L10n.text("Chart query missing")
        case .missingConnection: L10n.text("The saved bookmark for this visualizer is unavailable.")
        case .missingValues(let names):
            L10n.format("Set %@ in this page's filters to run the chart.", names.map { ":" + $0 }.joined(separator: ", "))
        }
    }
}

/// Runs a saved chart's query read-only, binding the page's filter values as native parameters.
enum ChartQueryRunner {
    /// The query the chart runs: its saved SQL, without a trailing LIMIT or OFFSET when it uses all rows.
    static func query(for preset: SavedVisualizationPreset) -> String? {
        guard let sql = preset.sourceQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty else { return nil }
        return preset.usesUnlimitedRows ? VisualizationService.unlimitedQuery(from: sql) : sql
    }

    /// Named parameters the chart's query needs, such as "start" for `:start`.
    static func parameters(for preset: SavedVisualizationPreset, engine: DatabaseEngine) -> [String] {
        query(for: preset).map { QueryParameterService.parameters(in: $0, engine: engine) } ?? []
    }

    /// The values this chart uses from the page, so a cached result can tell when the filters changed.
    static func usedValues(for preset: SavedVisualizationPreset, engine: DatabaseEngine, page: [String: String]) -> [String: String] {
        let names = Set(parameters(for: preset, engine: engine))
        return page.filter { names.contains($0.key) }
    }

    static func run(_ preset: SavedVisualizationPreset, profile: ConnectionProfile?, pageValues: [String: String]) async throws -> QueryResultTable {
        guard let sql = query(for: preset) else { throw ChartQueryError.missingQuery }
        guard let profile else { throw ChartQueryError.missingConnection }
        let names = QueryParameterService.parameters(in: sql, engine: profile.engine)
        let missing = names.filter { pageValues[$0] == nil }
        guard missing.isEmpty else { throw ChartQueryError.missingValues(missing) }
        let bound = try QueryParameterService.boundQuery(sql: sql, values: pageValues, engine: profile.engine)
        var result = try await DatabaseService.shared.execute(
            query: bound.sql,
            values: bound.values,
            profile: profile,
            database: preset.databaseName,
            policy: .readOnly
        )
        result.sourceQuery = preset.sourceQuery
        result.sourceTableReference = preset.sourceTableReference
        return result
    }

    /// The row limit at the end of a query, if any, so a chart cut off by it can offer all rows.
    static func trailingLimit(in sql: String) -> Int? {
        let pattern = #"(?is)\bLIMIT\s+(\d+)(?:\s+OFFSET\s+\d+)?\s*;?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)),
              let range = Range(match.range(at: 1), in: sql) else { return nil }
        return Int(sql[range])
    }

    /// New charts drop the 100-row limit Explorer's templates add; other limits are intentional.
    static func defaultUsesAllRows(for sql: String?) -> Bool {
        sql.flatMap(trailingLimit(in:)) == 100
    }
}
