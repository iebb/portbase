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

/// Lets a few chart queries run at a time; the rest wait their turn in order.
actor ChartRunGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
        // A query cancelled while it waited passes its slot on rather than keeping it.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    func release() {
        // A finished query hands its slot straight to the next waiting one.
        if waiting.isEmpty { running = max(0, running - 1) } else { waiting.removeFirst().resume() }
    }
}

/// Runs a saved chart's query read-only, binding the page's filter values as native parameters.
enum ChartQueryRunner {
    static let gate = ChartRunGate(limit: 4)

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

    /// The connection a chart runs on. A chart saved with a connection uses only that one, so a deleted
    /// connection never sends the query to whichever server happens to be selected.
    static func profile(for preset: SavedVisualizationPreset, lookup: (UUID) -> ConnectionProfile?,
                        fallback: ConnectionProfile?) -> ConnectionProfile? {
        guard let id = preset.connectionProfileID else { return fallback }
        return lookup(id)
    }

    /// The filter values a result was fetched with, compared by setting rather than by timestamp so a
    /// rolling "Last 7 Days" doesn't count as changed every second.
    static func filterSignature(for preset: SavedVisualizationPreset, engine: DatabaseEngine, page: ChartPage) -> [String: String] {
        let names = Set(parameters(for: preset, engine: engine))
        var signature = (page.parameterValues ?? [:]).filter { names.contains($0.key) }
        if names.contains(ChartPage.startParameter) || names.contains(ChartPage.endParameter), let range = page.dateRange {
            signature["portbase.dateRange"] = range.preset.rawValue + (range.preset == .custom ? range.title : "")
        }
        return signature
    }

    static func run(_ preset: SavedVisualizationPreset, profile: ConnectionProfile?, pageValues: [String: String]) async throws -> QueryResultTable {
        guard let sql = query(for: preset) else { throw ChartQueryError.missingQuery }
        guard let profile else { throw ChartQueryError.missingConnection }
        let names = QueryParameterService.parameters(in: sql, engine: profile.engine)
        let missing = names.filter { pageValues[$0] == nil }
        guard missing.isEmpty else { throw ChartQueryError.missingValues(missing) }
        let bound = try QueryParameterService.boundQuery(sql: sql, values: pageValues, engine: profile.engine)
        // Refresh All on a large page would otherwise open a connection per chart at once.
        try await gate.acquire()
        defer { Task { await gate.release() } }
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
