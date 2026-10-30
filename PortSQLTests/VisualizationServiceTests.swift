import XCTest
@testable import PortSQL

final class VisualizationServiceTests: XCTestCase {
    func testFieldDescriptorsDetectDateAndNumericColumns() {
        let descriptors = VisualizationService.fieldDescriptors(for: salesResult)

        XCTAssertEqual(descriptors.first(where: { $0.name == "day" })?.supportsDate, true)
        XCTAssertEqual(descriptors.first(where: { $0.name == "revenue" })?.supportsNumeric, true)
        XCTAssertEqual(descriptors.first(where: { $0.name == "region" })?.supportsCategory, true)
    }

    func testDefaultPresetUsesDateXAxisAndNumericYField() {
        let preset = VisualizationService.defaultPreset(
            for: salesResult,
            connectionProfileID: nil,
            connectionName: "Warehouse",
            databaseName: "analytics",
            sourceTableReference: "sales"
        )

        XCTAssertEqual(preset.xField, "day")
        XCTAssertEqual(preset.yField, "revenue")
        XCTAssertEqual(preset.xAxisMode, .date)
        XCTAssertEqual(preset.chartType, .line)
    }

    func testChartPointsAggregateMatchingXGroupAndMetric() {
        let preset = SavedVisualizationPreset(
            title: "Revenue",
            chartType: .bar,
            chartTitle: "Revenue",
            xField: "region",
            yField: "revenue",
            yFields: ["revenue"],
            groupField: nil,
            labelField: nil,
            xAxisTitle: "Region",
            yAxisTitle: "Revenue",
            xAxisMode: .category,
            usesUnlimitedRows: false,
            connectionName: "Warehouse",
            connectionProfileID: nil,
            databaseName: "analytics",
            sourceTableReference: "sales",
            sourceQuery: nil
        )

        let points = VisualizationService.chartPoints(for: salesResult, preset: preset)

        XCTAssertEqual(points.first(where: { $0.xText == "East" })?.yValue, 250)
        XCTAssertEqual(points.first(where: { $0.xText == "West" })?.yValue, 200)
    }

    func testUnlimitedQueryRemovesTrailingLimitOffsetAndKeepsSemicolon() {
        XCTAssertEqual(
            VisualizationService.unlimitedQuery(from: "SELECT * FROM sales ORDER BY day LIMIT 25 OFFSET 50;"),
            "SELECT * FROM sales ORDER BY day;"
        )
    }

    func testCompatibilityRequiresExistingXAndNumericYFields() {
        let compatible = VisualizationService.defaultPreset(
            for: salesResult,
            connectionProfileID: nil,
            connectionName: "Warehouse",
            databaseName: nil,
            sourceTableReference: nil
        )
        var incompatible = compatible
        incompatible.yFields = ["region"]
        incompatible.yField = "region"

        XCTAssertTrue(VisualizationService.isCompatible(compatible, with: salesResult))
        XCTAssertFalse(VisualizationService.isCompatible(incompatible, with: salesResult))
    }

    func testCategoryPointsKeepTheQueryOrderUntilSorted() {
        let result = countryResult(columns: ["country", "packages"], rows: [["Japan", "5"], ["Brazil", "9"], ["Canada", "1"], ["Japan", "2"]])
        var preset = VisualizationService.defaultPreset(for: result, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.xAxisMode = .category

        XCTAssertEqual(VisualizationService.chartPoints(for: result, preset: preset).map(\.xText), ["Japan", "Brazil", "Canada"])
        XCTAssertEqual(ChartRenderData.build(result: result, preset: preset, dateFilter: nil).points.map(\.xText), ["Japan", "Brazil", "Canada"])
        preset.sortOrder = .label
        XCTAssertEqual(ChartRenderData.build(result: result, preset: preset, dateFilter: nil).points.map(\.xText), ["Brazil", "Canada", "Japan"])
        preset.sortOrder = .valueDescending
        XCTAssertEqual(ChartRenderData.build(result: result, preset: preset, dateFilter: nil).points.map(\.xText), ["Brazil", "Japan", "Canada"])
    }

    func testAdaptedPresetDropsMissingFieldsAndLabelsFollowUneditedFields() {
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.xField = "region"
        preset.yFields = ["total_users", "packages"]
        preset.yField = "total_users"
        preset.xAxisTitle = "region"
        preset.yAxisTitle = "total_users + packages"
        preset.groupField = "plan"
        let result = countryResult(columns: ["country", "packages"], rows: [["Japan", "5"], ["Brazil", "9"]])

        let adapted = VisualizationService.adaptedPreset(preset, to: result)

        XCTAssertEqual(adapted.xField, "country")
        XCTAssertEqual(adapted.resolvedYFields, ["packages"])
        XCTAssertEqual(adapted.yField, "packages")
        XCTAssertEqual(adapted.xAxisTitle, "country")
        XCTAssertEqual(adapted.yAxisTitle, "packages")
        XCTAssertNil(adapted.groupField)

        preset.xAxisTitle = "Where"
        preset.yAxisTitle = "Volume"
        let edited = VisualizationService.adaptedPreset(preset, to: result)
        XCTAssertEqual(edited.xAxisTitle, "Where")
        XCTAssertEqual(edited.yAxisTitle, "Volume")
    }

    func testAdaptedPresetPicksADefaultMetricWhenNoneRemain() {
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.xField = "country"
        preset.yFields = ["total_users"]
        preset.yField = "total_users"
        preset.yAxisTitle = ""
        let adapted = VisualizationService.adaptedPreset(preset, to: countryResult(columns: ["country", "packages"], rows: [["Japan", "5"]]))

        XCTAssertEqual(adapted.resolvedYFields, ["packages"])
        XCTAssertEqual(adapted.yAxisTitle, "packages")
    }

    func testInferredTableReferenceReadsTheChangedQuery() {
        XCTAssertEqual(VisualizationService.inferredTableReference(in: "SELECT country, COUNT(*) FROM shop.orders GROUP BY 1"), "shop.orders")
        XCTAssertEqual(VisualizationService.inferredTableReference(in: "explain select * from logs;"), "logs")
        XCTAssertNil(VisualizationService.inferredTableReference(in: "SELECT 1"))
    }

    func testTileTitleShowsTheChartTitleSomeoneSet() {
        var preset = VisualizationService.defaultPreset(for: salesResult, connectionProfileID: nil, connectionName: "Warehouse",
                                                        databaseName: nil, sourceTableReference: "sales")
        preset.title = "Revenue by day"
        XCTAssertEqual(preset.chartTitle, "sales")
        XCTAssertEqual(preset.tileTitle, "Revenue by day")
        preset.chartTitle = "Daily Revenue"
        XCTAssertEqual(preset.tileTitle, "Daily Revenue")
        preset.chartTitle = " "
        XCTAssertEqual(preset.tileTitle, "Revenue by day")
    }

    private func countryResult(columns: [String], rows: [[String]]) -> QueryResultTable {
        QueryResultTable(
            columns: columns.map { QueryColumn(name: $0, type: $0 == "country" ? "text" : "integer") },
            rows: rows.map { QueryRow(values: $0) },
            executionSummary: "",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil
        )
    }

    private var salesResult: QueryResultTable {
        QueryResultTable(
            columns: [
                QueryColumn(name: "day", type: "date"),
                QueryColumn(name: "region", type: "text"),
                QueryColumn(name: "revenue", type: "decimal")
            ],
            rows: [
                QueryRow(values: ["2026-05-01", "East", "100.50"]),
                QueryRow(values: ["2026-05-02", "East", "149.50"]),
                QueryRow(values: ["2026-05-01", "West", "200"])
            ],
            executionSummary: "3 rows",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: "sales",
            sourceQuery: "SELECT * FROM sales"
        )
    }
}
