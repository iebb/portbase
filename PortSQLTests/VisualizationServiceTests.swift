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
