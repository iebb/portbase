import Foundation

/// Summaries of a materialized result. Values are computed from the loaded rows only.
struct ResultInsights: Equatable {
    let rowCount: Int
    let columns: [ColumnInsight]

    /// Share of non-NULL cells across the loaded result.
    var completeness: Double {
        let cells = rowCount * columns.count
        guard cells > 0 else { return 1 }
        return Double(cells - columns.reduce(0) { $0 + $1.nullCount }) / Double(cells)
    }

    var numericColumnCount: Int { columns.filter { $0.kind == .numeric }.count }

    static let empty = ResultInsights(rowCount: 0, columns: [])
}

struct ColumnInsight: Identifiable, Equatable {
    enum Kind: Equatable {
        case numeric, temporal, boolean, text, json, binary, empty
    }

    let id: Int
    let name: String
    let type: String
    let kind: Kind
    let rowCount: Int
    let nullCount: Int
    let emptyTextCount: Int
    let distinctCount: Int
    let numeric: NumericSummary?
    let earliest: String?
    let latest: String?
    let topValues: [ValueFrequency]

    var nullRatio: Double { rowCount == 0 ? 0 : Double(nullCount) / Double(rowCount) }
    var isUnique: Bool { rowCount > 0 && nullCount == 0 && distinctCount == rowCount }
}

struct NumericSummary: Equatable {
    let minimum: Double
    let maximum: Double
    let mean: Double
    let median: Double
    let sum: Double
    let bins: [HistogramBin]
}

struct HistogramBin: Identifiable, Equatable {
    let id: Int
    let lowerBound: Double
    let upperBound: Double
    let count: Int
}

struct ValueFrequency: Identifiable, Equatable {
    var id: String { value }
    let value: String
    let count: Int
}

enum ResultInsightsService {
    static let histogramBinCount = 10
    static let topValueCount = 5

    static func insights(for result: QueryResultTable) -> ResultInsights {
        ResultInsights(
            rowCount: result.rows.count,
            columns: result.columns.indices.map { insight(column: $0, in: result) }
        )
    }

    static func insight(column index: Int, in result: QueryResultTable) -> ColumnInsight {
        let column = result.columns[index]
        var nullCount = 0
        var emptyTextCount = 0
        var numbers: [Double] = []
        var counts: [String: Int] = [:]
        var kinds: [ColumnInsight.Kind: Int] = [:]
        var earliest: String?
        var latest: String?

        for row in result.rows {
            let cell = row.cells.indices.contains(index) ? row.cells[index] : .null
            let kind = kind(of: cell)
            if kind == .empty { nullCount += 1; continue }
            kinds[kind, default: 0] += 1
            switch cell {
            case .integer(let value), .decimal(let value):
                if let number = Double(value), number.isFinite { numbers.append(number) }
            case .dateTime(let value):
                if earliest.map({ value < $0 }) ?? true { earliest = value }
                if latest.map({ value > $0 }) ?? true { latest = value }
            case .text(let value) where value.isEmpty:
                emptyTextCount += 1
            default:
                break
            }
            // Binary values are counted by their bytes, never by a lossy text rendering.
            let key: String
            if case .binary(let data) = cell { key = "0x" + data.prefix(32).map { String(format: "%02x", $0) }.joined() + (data.count > 32 ? "…" : "") }
            else { key = cell.displayValue }
            counts[key, default: 0] += 1
        }

        let dominant = kinds.max { lhs, rhs in lhs.value == rhs.value ? rank(lhs.key) > rank(rhs.key) : lhs.value < rhs.value }?.key ?? .empty
        let numeric = dominant == .numeric && !numbers.isEmpty ? summary(of: numbers) : nil
        let topValues = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(topValueCount)
            .map { ValueFrequency(value: $0.key, count: $0.value) }

        return ColumnInsight(
            id: index,
            name: column.name,
            type: column.type,
            kind: dominant,
            rowCount: result.rows.count,
            nullCount: nullCount,
            emptyTextCount: emptyTextCount,
            distinctCount: counts.count,
            numeric: numeric,
            earliest: dominant == .temporal ? earliest : nil,
            latest: dominant == .temporal ? latest : nil,
            topValues: topValues
        )
    }

    static func summary(of values: [Double]) -> NumericSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let sum = sorted.reduce(0, +)
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let minimum = sorted[0], maximum = sorted[sorted.count - 1]
        return NumericSummary(minimum: minimum, maximum: maximum, mean: sum / Double(sorted.count), median: median,
                              sum: sum, bins: histogram(sorted, minimum: minimum, maximum: maximum))
    }

    private static func histogram(_ values: [Double], minimum: Double, maximum: Double) -> [HistogramBin] {
        guard maximum > minimum else {
            return [HistogramBin(id: 0, lowerBound: minimum, upperBound: maximum, count: values.count)]
        }
        let width = (maximum - minimum) / Double(histogramBinCount)
        var counts = Array(repeating: 0, count: histogramBinCount)
        for value in values {
            counts[min(histogramBinCount - 1, max(0, Int((value - minimum) / width)))] += 1
        }
        return counts.indices.map { index in
            HistogramBin(id: index, lowerBound: minimum + Double(index) * width,
                         upperBound: index == histogramBinCount - 1 ? maximum : minimum + Double(index + 1) * width,
                         count: counts[index])
        }
    }

    private static func kind(of cell: QueryCell) -> ColumnInsight.Kind {
        switch cell {
        case .null: .empty
        case .integer, .decimal: .numeric
        case .dateTime: .temporal
        case .boolean: .boolean
        case .text: .text
        case .json: .json
        case .binary: .binary
        }
    }

    // Ties prefer the more specific interpretation.
    private static func rank(_ kind: ColumnInsight.Kind) -> Int {
        switch kind {
        case .numeric: 0
        case .temporal: 1
        case .boolean: 2
        case .json: 3
        case .binary: 4
        case .text: 5
        case .empty: 6
        }
    }
}
