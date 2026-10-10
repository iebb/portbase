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
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

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

struct VisualizationDateFilter: Equatable {
    var field: String
    var start: Date
    var end: Date
}
