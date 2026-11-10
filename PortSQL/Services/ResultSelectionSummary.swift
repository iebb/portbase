import Foundation

/// Figures for the selected result cells, as TablePlus and DataGrip show beside a selection: how many
/// values, and for numbers their sum, average, minimum, and maximum. Dates get a minimum and maximum.
struct ResultSelectionSummary: Equatable, Sendable {
    var cells = 0
    var values = 0
    var nulls = 0
    var distinct = 0
    var sum: ExactDecimal?
    var average: ExactDecimal?
    var minimum: String?
    var maximum: String?
    /// Digits after the point in the most precise number, so sums keep the inputs' scale.
    var scale = 0

    var isNumeric: Bool { sum != nil }

    static func make(_ payload: ResultGridClipboard.Payload) -> ResultSelectionSummary {
        var summary = ResultSelectionSummary()
        var numbers: [ExactDecimal] = []
        var dates: [String] = []
        var seen = Set<QueryCell>()
        var allNumeric = true, allDates = true
        for row in payload.rows {
            for cell in row.cells {
                summary.cells += 1
                if cell.isNull { summary.nulls += 1; continue }
                summary.values += 1
                if seen.count < 100_000 { seen.insert(cell) }
                switch cell {
                case .integer(let text), .decimal(let text):
                    allDates = false
                    // Exact at any size, so a total of large or very precise values never rounds or overflows.
                    if allNumeric, let number = ExactDecimal(text) {
                        numbers.append(number)
                        if let point = text.firstIndex(of: "."), !text.contains(where: { $0 == "e" || $0 == "E" }) {
                            summary.scale = max(summary.scale, text.distance(from: text.index(after: point), to: text.endIndex))
                        }
                    } else { allNumeric = false }
                case .dateTime(let text):
                    allNumeric = false
                    if allDates { dates.append(text) }
                default:
                    allNumeric = false; allDates = false
                }
            }
        }
        summary.distinct = seen.count
        if allNumeric, !numbers.isEmpty {
            let total = numbers.reduce(ExactDecimal.zero, +)
            summary.sum = total
            summary.average = total.divided(by: numbers.count, fractionDigits: max(summary.scale, 2) + 4)
            summary.minimum = numbers.min()!.plainDescription
            summary.maximum = numbers.max()!.plainDescription
        } else if allDates, !dates.isEmpty {
            // ISO dates and times sort as text in time order.
            summary.minimum = dates.min()
            summary.maximum = dates.max()
        }
        return summary
    }

    /// A number as SQL and spreadsheets read it, with no grouping and a point for decimals.
    static func plain(_ value: ExactDecimal, scale: Int? = nil) -> String {
        guard let scale else { return value.plainDescription }
        var text = value.rounded(toScale: scale).plainDescription
        // Like a database's own rendering, trailing zeros after the point are dropped.
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// A number for reading, grouped by the person's locale.
    static func display(_ value: ExactDecimal, fractionDigits: Int) -> String {
        value.formatted(fractionDigits: fractionDigits)
    }

    var sumText: String? { sum.map { Self.display($0, fractionDigits: scale) } }
    var averageText: String? { average.map { Self.display($0, fractionDigits: max(scale, 2)) } }
    var minimumText: String? { isNumeric ? minimum.flatMap(ExactDecimal.init).map { Self.display($0, fractionDigits: scale) } : minimum }
    var maximumText: String? { isNumeric ? maximum.flatMap(ExactDecimal.init).map { Self.display($0, fractionDigits: scale) } : maximum }
}
