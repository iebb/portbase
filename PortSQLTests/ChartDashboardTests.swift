import XCTest
@testable import PortSQL

final class ChartDashboardTests: XCTestCase {
    private func point(_ name: String, _ value: Double) -> VisualizationPlotPoint {
        VisualizationPlotPoint(id: name, xText: name, xNumber: nil, xDate: nil, yValue: value, group: nil, label: nil, metric: "users", sourceRowIDs: [UUID()])
    }

    func testPieKeepsLargestSlicesAndCombinesTheTailIntoOther() {
        let points = [point("China", 37_305), point("Japan", 900), point("Korea", 600)] + (0..<40).map { point("Country \($0)", 10) }
        let slices = ChartRenderData.sectorPoints(points)
        XCTAssertLessThanOrEqual(slices.count, ChartRenderData.maximumSlices)
        XCTAssertEqual(slices.first?.xText, "China")
        let other = try? XCTUnwrap(slices.last)
        XCTAssertEqual(other?.id, "portbase.other")
        XCTAssertEqual(slices.reduce(0) { $0 + $1.yValue }, points.reduce(0) { $0 + $1.yValue }, accuracy: 0.001, "Nothing is dropped")
        XCTAssertEqual(other?.sourceRowIDs.count, 41, "Korea (1.5%) and the 40 small countries combine")

        let single = ChartRenderData.sectorPoints([point("A", 50), point("B", 0.5)])
        XCTAssertEqual(single.map(\.xText), ["A", "B"], "A single small slice stays itself rather than becoming Other")
    }

    func testThinningKeepsEndpointsAndPeaks() {
        let xs = (0..<5_000).map(Double.init)
        var ys = xs.map { sin($0 / 300) }
        ys[2_345] = 50
        let kept = ChartRenderData.largestTriangleThreeBuckets(xs: xs, ys: ys, threshold: 600)
        XCTAssertEqual(kept.count, 600)
        XCTAssertEqual(kept.first, 0)
        XCTAssertEqual(kept.last, 4_999)
        XCTAssertTrue(kept.contains(2_345), "A spike survives thinning")
        XCTAssertEqual(kept, kept.sorted())
    }

    func testCategoriesKeepNullEmptyAndNullTextApart() {
        let result = QueryResultTable(
            columns: [QueryColumn(name: "label", type: "text"), QueryColumn(name: "n", type: "integer")],
            rows: [QueryRow(cells: [.null, .integer("1")]), QueryRow(cells: [.text("NULL"), .integer("2")]), QueryRow(cells: [.text(""), .integer("3")])],
            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil, sourceQuery: nil)
        var preset = VisualizationService.defaultPreset(for: result, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.xField = "label"; preset.yField = "n"; preset.yFields = ["n"]; preset.xAxisMode = .category
        XCTAssertEqual(VisualizationService.chartPoints(for: result, preset: preset).count, 3)
    }

    func testStaleGeneratedTitlesFollowTheCurrentSetup() {
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.chartType = .donut
        preset.xField = "country"; preset.yField = "total_users"; preset.yFields = ["total_users"]
        preset.title = "nekokotel.travelsim_view_country_stats • Bar • mcc by first_user_at"
        XCTAssertEqual(preset.displayTitle, VisualizationService.generatedTitle(chartType: .donut, xField: "country", yFields: ["total_users"], source: nil))
        preset.title = "Signups • weekly"
        XCTAssertEqual(preset.displayTitle, "Signups • weekly", "A title someone typed is kept")
    }

    func testDateRangesAndParameterStrings() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-18T09:30:00Z"))
        let week = ChartDateRange(preset: .last7Days).interval(now: now, calendar: calendar)
        XCTAssertEqual(ChartDateRange.parameterString(week.start), "2026-10-11 09:30:00")
        XCTAssertEqual(ChartDateRange.parameterString(week.end), "2026-10-18 09:30:00")
        let lastMonth = ChartDateRange(preset: .lastMonth).interval(now: now, calendar: calendar)
        XCTAssertEqual(ChartDateRange.parameterString(lastMonth.start), "2026-09-01 00:00:00")
        XCTAssertEqual(ChartDateRange.parameterString(lastMonth.end), "2026-10-01 00:00:00")

        var page = ChartPage(title: "Growth")
        page.dateRange = ChartDateRange(preset: .last7Days)
        page.parameterValues = ["region": "EU"]
        let values = page.boundValues(now: now, calendar: calendar)
        XCTAssertEqual(values["start"], "2026-10-11 09:30:00")
        XCTAssertEqual(values["region"], "EU")
        page.dateRange = nil
        XCTAssertEqual(page.boundValues(now: now, calendar: calendar)["start"], "1970-01-01 00:00:00", "All Time still runs a query that uses :start")
    }

    func testTrailingLimitDetectionAndTheExplorerDefault() {
        XCTAssertEqual(ChartQueryRunner.trailingLimit(in: "SELECT * FROM t\nLIMIT 100"), 100)
        XCTAssertEqual(ChartQueryRunner.trailingLimit(in: "SELECT * FROM t LIMIT 25 OFFSET 50;"), 25)
        XCTAssertNil(ChartQueryRunner.trailingLimit(in: "SELECT * FROM (SELECT 1 LIMIT 5) s"))
        XCTAssertTrue(ChartQueryRunner.defaultUsesAllRows(for: "SELECT * FROM t LIMIT 100"))
        XCTAssertFalse(ChartQueryRunner.defaultUsesAllRows(for: "SELECT * FROM t ORDER BY n DESC LIMIT 10"), "An intentional top-N limit is kept")

        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.sourceQuery = "SELECT * FROM t LIMIT 100"
        preset.usesUnlimitedRows = true
        XCTAssertEqual(ChartQueryRunner.query(for: preset), "SELECT * FROM t")
        preset.usesUnlimitedRows = false
        XCTAssertEqual(ChartQueryRunner.query(for: preset), "SELECT * FROM t LIMIT 100")
    }

    func testChartParametersComeFromTheQuery() {
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.sourceQuery = "SELECT day, count(*) FROM signups WHERE created_at >= :start AND created_at < :end AND region = :region -- :ignored\nGROUP BY day"
        XCTAssertEqual(ChartQueryRunner.parameters(for: preset, engine: .postgresql), ["end", "region", "start"])
        XCTAssertEqual(ChartQueryRunner.usedValues(for: preset, engine: .postgresql, page: ["region": "EU", "other": "x"]), ["region": "EU"])
    }

    @MainActor
    func testPagesOrderMoveResizeAndSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        store.currentChartPageID = ChartPage.defaultID
        let template = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "Fixture", databaseName: nil, sourceTableReference: nil)
        var ids: [UUID] = []
        for index in 0..<3 {
            var chart = template; chart.id = UUID(); chart.title = "Chart \(index)"
            store.saveVisualization(chart)
            ids.append(chart.id)
        }
        XCTAssertEqual(store.charts(onPage: ChartPage.defaultID).map(\.id), ids, "New charts go to the end of the open page")

        store.moveChart(ids[2], toPage: ChartPage.defaultID, before: ids[0])
        XCTAssertEqual(store.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], ids[0], ids[1]])

        let growth = store.addChartPage(title: "Growth")
        XCTAssertEqual(store.displayedChartPages.map(\.title), ["Overview", "Growth"])
        XCTAssertEqual(store.currentChartPageID, growth.id)
        store.moveChart(ids[1], toPage: growth.id, before: nil)
        store.resizeChart(ids[1], height: 5_000, span: 7)
        store.setChartPageFilters(growth.id, dateRange: ChartDateRange(preset: .last30Days), values: ["region": "EU"])

        let reopened = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(reopened.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], ids[0]])
        let moved = try XCTUnwrap(reopened.charts(onPage: growth.id).first)
        XCTAssertEqual(moved.id, ids[1])
        XCTAssertEqual(moved.tileHeight, SavedVisualizationPreset.tileHeightRange.upperBound, "Sizes are clamped")
        XCTAssertEqual(moved.tileSpan, 3)
        let page = try XCTUnwrap(reopened.displayedChartPages.first { $0.id == growth.id })
        XCTAssertEqual(page.dateRange?.preset, .last30Days)
        XCTAssertEqual(page.parameterValues, ["region": "EU"])

        reopened.deleteChartPage(growth.id)
        XCTAssertEqual(reopened.displayedChartPages.map(\.id), [ChartPage.defaultID])
        XCTAssertEqual(reopened.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], ids[0], ids[1]], "A deleted page's charts move, not vanish")
    }
}
