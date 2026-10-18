import Foundation

enum VisualizationChartType: String, CaseIterable, Identifiable, Codable {
    case bar
    case line
    case area
    case point
    case rule
    case pie
    case donut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bar: L10n.text("Bar")
        case .line: L10n.text("Line")
        case .area: L10n.text("Area")
        case .point: L10n.text("Point")
        case .rule: L10n.text("Rule")
        case .pie: L10n.text("Pie")
        case .donut: L10n.text("Donut")
        }
    }

    var symbolName: String {
        switch self {
        case .bar: "chart.bar.xaxis"
        case .line: "chart.line.uptrend.xyaxis"
        case .area: "chart.line.flattrend.xyaxis"
        case .point: "chart.dots.scatter"
        case .rule: "chart.line.uptrend.xyaxis.circle"
        case .pie: "chart.pie"
        case .donut: "circle.hexagongrid.circle"
        }
    }

    var supportsCartesianAxes: Bool {
        switch self {
        case .pie, .donut:
            false
        default:
            true
        }
    }

}

/// Ways to show a chart's data other than a plot. Kept apart from the chart type so versions that
/// don't know them still read the chart and draw its plot.
enum ChartPresentation: String, Codable, CaseIterable, Identifiable {
    case table
    case number

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: L10n.text("Table")
        case .number: L10n.text("Number")
        }
    }

    var symbolName: String {
        switch self {
        case .table: "tablecells"
        case .number: "number.square"
        }
    }
}

/// The order of categories along the axis.
enum ChartSortOrder: String, Codable, CaseIterable, Identifiable {
    case valueDescending, valueAscending, label
    var id: String { rawValue }
    var title: String {
        switch self {
        case .valueDescending: L10n.text("Largest First")
        case .valueAscending: L10n.text("Smallest First")
        case .label: L10n.text("By Label")
        }
    }
}

/// How bars of several series share a category.
enum ChartBarLayout: String, Codable, CaseIterable, Identifiable {
    case stacked, grouped, normalized
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stacked: L10n.text("Stacked")
        case .grouped: L10n.text("Side by Side")
        case .normalized: L10n.text("100% Stacked")
        }
    }
}

enum VisualizationFieldMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case category
    case number
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: L10n.text("Auto")
        case .category: L10n.text("Category")
        case .number: L10n.text("Number")
        case .date: L10n.text("Date")
        }
    }
}

struct SavedVisualizationPreset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var chartType: VisualizationChartType
    var chartTitle: String
    var xField: String
    var yField: String
    var yFields: [String]
    var groupField: String?
    var labelField: String?
    var xAxisTitle: String
    var yAxisTitle: String
    var xAxisMode: VisualizationFieldMode
    var usesUnlimitedRows: Bool
    var connectionName: String
    var connectionProfileID: UUID?
    var databaseName: String?
    var sourceTableReference: String?
    var sourceQuery: String?
    /// The dashboard page the chart sits on; nil or an unknown page places it on the first page.
    var pageID: UUID?
    /// Order within its page, lowest first. Separate from `updatedAt`, which sync uses for revisions.
    var position: Double = 0
    /// The tile's height on the dashboard; nil uses the default.
    var tileHeight: Double?
    /// The tile's width in 24ths of the page, from 4 to 24. Narrow screens widen tiles to a minimum width.
    var gridSpan: Int = 8
    /// Whether the chart lists its series or slices under the plot.
    var showsLegend = true
    /// Keeps the largest K categories, series, or rows and combines the rest into "Other"; nil shows everything.
    var topLimit: Int?
    /// Shows the data as a table or a single number instead of the plot.
    var presentation: ChartPresentation?
    /// Category order; nil keeps the query's order.
    var sortOrder: ChartSortOrder?
    /// Bars of several series side by side or as shares; nil stacks them.
    var barLayout: ChartBarLayout?
    /// Draws bars horizontally, which suits long category names.
    var isHorizontal = false
    /// Labels each bar, point, or slice with its value.
    var showsValues = false
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var resolvedYFields: [String] {
        let fields = yFields.isEmpty ? [yField] : yFields
        var seen = Set<String>()
        return fields.filter { field in
            let normalized = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }

    var supportsMetricStacking: Bool {
        chartType == .bar || chartType == .area
    }

    var yFieldsSummary: String {
        let metrics = resolvedYFields
        switch metrics.count {
        case 0:
            return ""
        case 1:
            return metrics[0]
        case 2:
            return metrics.joined(separator: " + ")
        default:
            return L10n.format("%@ + %d more", metrics[0], metrics.count - 1)
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        chartType: VisualizationChartType,
        chartTitle: String,
        xField: String,
        yField: String,
        yFields: [String] = [],
        groupField: String?,
        labelField: String?,
        xAxisTitle: String,
        yAxisTitle: String,
        xAxisMode: VisualizationFieldMode,
        usesUnlimitedRows: Bool,
        connectionName: String,
        connectionProfileID: UUID?,
        databaseName: String?,
        sourceTableReference: String?,
        sourceQuery: String?,
        pageID: UUID? = nil,
        position: Double = 0,
        tileHeight: Double? = nil,
        gridSpan: Int = 8,
        showsLegend: Bool = true,
        topLimit: Int? = nil,
        presentation: ChartPresentation? = nil,
        sortOrder: ChartSortOrder? = nil,
        barLayout: ChartBarLayout? = nil,
        isHorizontal: Bool = false,
        showsValues: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.chartType = chartType
        self.chartTitle = chartTitle
        self.xField = xField
        self.yField = yField
        self.yFields = yFields
        self.groupField = groupField
        self.labelField = labelField
        self.xAxisTitle = xAxisTitle
        self.yAxisTitle = yAxisTitle
        self.xAxisMode = xAxisMode
        self.usesUnlimitedRows = usesUnlimitedRows
        self.connectionName = connectionName
        self.connectionProfileID = connectionProfileID
        self.databaseName = databaseName
        self.sourceTableReference = sourceTableReference
        self.sourceQuery = sourceQuery
        self.pageID = pageID
        self.position = position
        self.tileHeight = tileHeight.map(Self.clampedTileHeight)
        self.gridSpan = Self.clampedGridSpan(gridSpan)
        self.showsLegend = showsLegend
        self.topLimit = topLimit.map(Self.clampedTopLimit)
        self.presentation = presentation
        self.sortOrder = sortOrder
        self.barLayout = barLayout
        self.isHorizontal = isHorizontal
        self.showsValues = showsValues
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        chartType = try container.decode(VisualizationChartType.self, forKey: .chartType)
        chartTitle = try container.decode(String.self, forKey: .chartTitle)
        xField = try container.decode(String.self, forKey: .xField)
        yField = try container.decode(String.self, forKey: .yField)
        yFields = try container.decodeIfPresent([String].self, forKey: .yFields) ?? []
        groupField = try container.decodeIfPresent(String.self, forKey: .groupField)
        labelField = try container.decodeIfPresent(String.self, forKey: .labelField)
        xAxisTitle = try container.decode(String.self, forKey: .xAxisTitle)
        yAxisTitle = try container.decode(String.self, forKey: .yAxisTitle)
        xAxisMode = try container.decode(VisualizationFieldMode.self, forKey: .xAxisMode)
        usesUnlimitedRows = try container.decodeIfPresent(Bool.self, forKey: .usesUnlimitedRows) ?? false
        connectionName = try container.decode(String.self, forKey: .connectionName)
        connectionProfileID = try container.decodeIfPresent(UUID.self, forKey: .connectionProfileID)
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName)
        sourceTableReference = try container.decodeIfPresent(String.self, forKey: .sourceTableReference)
        sourceQuery = try container.decodeIfPresent(String.self, forKey: .sourceQuery)
        pageID = try? container.decodeIfPresent(UUID.self, forKey: .pageID)
        position = (try? container.decodeIfPresent(Double.self, forKey: .position)) ?? 0
        tileHeight = (try? container.decodeIfPresent(Double.self, forKey: .tileHeight)).flatMap { $0 }.map(Self.clampedTileHeight)
        if let span = try? container.decodeIfPresent(Int.self, forKey: .gridSpan) {
            gridSpan = Self.clampedGridSpan(span)
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
            gridSpan = Self.gridSpan(fromLegacyTileSpan: (try? legacy?.decodeIfPresent(Int.self, forKey: .tileSpan)).flatMap { $0 } ?? 1)
        }
        showsLegend = (try? container.decodeIfPresent(Bool.self, forKey: .showsLegend)) ?? true
        topLimit = (try? container.decodeIfPresent(Int.self, forKey: .topLimit)).flatMap { $0 }.map(Self.clampedTopLimit)
        // An unknown presentation from a newer version falls back to the plot.
        presentation = (try? container.decodeIfPresent(ChartPresentation.self, forKey: .presentation)).flatMap { $0 }
        sortOrder = (try? container.decodeIfPresent(ChartSortOrder.self, forKey: .sortOrder)).flatMap { $0 }
        barLayout = (try? container.decodeIfPresent(ChartBarLayout.self, forKey: .barLayout)).flatMap { $0 }
        isHorizontal = (try? container.decodeIfPresent(Bool.self, forKey: .isHorizontal)).flatMap { $0 } ?? false
        showsValues = (try? container.decodeIfPresent(Bool.self, forKey: .showsValues)).flatMap { $0 } ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// The title to show. Earlier versions generated titles like "orders • Bar • total by day" that went
    /// stale when the chart changed; those show a title generated from the current setup instead.
    var displayTitle: String {
        let parts = title.components(separatedBy: " • ")
        let chartTypes = Set(VisualizationChartType.allCases.flatMap { [$0.title, $0.rawValue.capitalized] })
        if parts.count == 3, chartTypes.contains(parts[1]), parts[2].contains(" by ") {
            return VisualizationService.generatedTitle(chartType: chartType, xField: xField, yFields: resolvedYFields, source: nil)
        }
        return title
    }

    static let tileHeightRange: ClosedRange<Double> = 200...900
    static let defaultTileHeight: Double = 320

    static func clampedTileHeight(_ height: Double) -> Double {
        min(max(height.isFinite ? height : defaultTileHeight, tileHeightRange.lowerBound), tileHeightRange.upperBound)
    }

    private enum LegacyKeys: String, CodingKey { case tileSpan }

    static func clampedTopLimit(_ limit: Int) -> Int { min(max(limit, 1), 1_000) }

    /// The title of how the chart is shown: its presentation, or its chart type.
    var displayKindTitle: String { presentation?.title ?? chartType.title }
    var displayKindSymbol: String { presentation?.symbolName ?? chartType.symbolName }

    static let gridColumns = 24

    static func clampedGridSpan(_ span: Int) -> Int { min(max(span, 4), gridColumns) }

    /// Earlier versions stored one to three columns of a three-column page.
    static func gridSpan(fromLegacyTileSpan span: Int) -> Int { clampedGridSpan(min(max(span, 1), 3) * 8) }

    /// The nearest three-column width, still written for versions that read only that.
    var legacyTileSpan: Int { min(3, max(1, Int((Double(gridSpan) / 8).rounded()))) }

    var resolvedTileHeight: Double { tileHeight ?? Self.defaultTileHeight }

    static let empty = SavedVisualizationPreset(
        title: "",
        chartType: .bar,
        chartTitle: "",
        xField: "",
        yField: "",
        yFields: [],
        groupField: nil,
        labelField: nil,
        xAxisTitle: "",
        yAxisTitle: "",
        xAxisMode: .automatic,
        usesUnlimitedRows: false,
        connectionName: "",
        connectionProfileID: nil,
        databaseName: nil,
        sourceTableReference: nil,
        sourceQuery: nil
    )
}

/// A named dashboard page that groups saved charts. Pages sync through iCloud like the charts.
struct ChartPage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var position: Double = 0
    /// The page's date range, sent to its charts as the `:start` and `:end` parameters. Without one,
    /// "All Time" sends the widest dates every supported database accepts.
    var dateRange: ChartDateRange?
    /// Values for other named parameters in the page's chart queries, such as `:region`.
    var parameterValues: [String: String]?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// The page charts sit on before any page is created, kept stable so every device agrees.
    static let defaultID = UUID(uuidString: "6D1C0B5E-4C2A-4E8B-9A57-0C9A8E3F2B10")!
    static var defaultPage: ChartPage { ChartPage(id: defaultID, title: L10n.text("Overview"), createdAt: .distantPast, updatedAt: .distantPast) }

    static let startParameter = "start"
    static let endParameter = "end"

    /// Every value the page supplies to its charts' named parameters, as strings bound natively.
    func boundValues(now: Date = .now, calendar: Calendar = .current) -> [String: String] {
        var values = parameterValues ?? [:]
        if let dateRange {
            let interval = dateRange.interval(now: now, calendar: calendar)
            values[Self.startParameter] = ChartDateRange.parameterString(interval.start)
            values[Self.endParameter] = ChartDateRange.parameterString(interval.end)
        } else {
            values[Self.startParameter] = "1970-01-01 00:00:00"
            values[Self.endParameter] = "9999-12-31 23:59:59"
        }
        return values
    }
}

/// A page-wide date range: a rolling preset or fixed dates.
struct ChartDateRange: Codable, Hashable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case last24Hours, last7Days, last30Days, last90Days, thisMonth, lastMonth, yearToDate, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .last24Hours: L10n.text("Last 24 Hours")
            case .last7Days: L10n.text("Last 7 Days")
            case .last30Days: L10n.text("Last 30 Days")
            case .last90Days: L10n.text("Last 90 Days")
            case .thisMonth: L10n.text("This Month")
            case .lastMonth: L10n.text("Last Month")
            case .yearToDate: L10n.text("Year to Date")
            case .custom: L10n.text("Custom Range")
            }
        }
    }

    var preset: Preset
    var start: Date?
    var end: Date?

    /// Rolling ranges are computed when charts run, so a saved page always means "the last 7 days".
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        func ago(_ component: Calendar.Component, _ value: Int) -> Date { calendar.date(byAdding: component, value: -value, to: now) ?? now }
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        switch preset {
        case .last24Hours: return DateInterval(start: ago(.hour, 24), end: now)
        case .last7Days: return DateInterval(start: ago(.day, 7), end: now)
        case .last30Days: return DateInterval(start: ago(.day, 30), end: now)
        case .last90Days: return DateInterval(start: ago(.day, 90), end: now)
        case .thisMonth: return DateInterval(start: startOfMonth, end: now)
        case .lastMonth:
            let previous = calendar.date(byAdding: .month, value: -1, to: startOfMonth) ?? startOfMonth
            return DateInterval(start: previous, end: startOfMonth)
        case .yearToDate: return DateInterval(start: calendar.dateInterval(of: .year, for: now)?.start ?? now, end: now)
        case .custom:
            let start = start ?? ago(.day, 7), end = max(end ?? now, start)
            return DateInterval(start: start, end: end)
        }
    }

    var title: String {
        guard preset == .custom else { return preset.title }
        let interval = interval()
        return interval.start.formatted(date: .abbreviated, time: .omitted) + " – " + interval.end.formatted(date: .abbreviated, time: .omitted)
    }

    /// UTC timestamps as databases read them: "2026-10-18 09:30:00".
    static func parameterString(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: .gmt, calendar: Calendar(identifier: .gregorian)))
    }
}

struct VisualizationFieldDescriptor: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let sourceType: String
    let nonEmptyCount: Int
    let distinctCount: Int
    let sampleValue: String
    let supportsCategory: Bool
    let supportsNumeric: Bool
    let supportsDate: Bool
}

struct VisualizationPlotPoint: Identifiable, Hashable {
    let id: String
    let xText: String
    let xNumber: Double?
    let xDate: Date?
    var yValue: Double
    let group: String?
    var label: String?
    let metric: String?
    var sourceRowIDs: [UUID] = []
}

struct VisualizationDateFilter: Hashable, Sendable {
    var field: String
    var start: Date
    var end: Date
}
