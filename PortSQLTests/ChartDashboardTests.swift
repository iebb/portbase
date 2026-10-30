import XCTest
@testable import PortSQL

final class ChartDashboardTests: XCTestCase {
    private func point(_ name: String, _ value: Double) -> VisualizationPlotPoint {
        VisualizationPlotPoint(id: name, xText: name, xNumber: nil, xDate: nil, yValue: value, group: nil, label: nil, metric: "users", sourceRowIDs: [UUID()])
    }

    func testNothingIsGroupedUnlessTheChartSetsTopK() {
        let points = [point("China", 37_305), point("Japan", 900), point("Korea", 600)] + (0..<40).map { point("Country \($0)", 10) }
        XCTAssertEqual(ChartRenderData.topLimited(points, limit: 100, xMode: .category).count, points.count)

        let top = ChartRenderData.topLimited(points, limit: 2, xMode: .category)
        XCTAssertEqual(top.map(\.xText), ["China", "Japan", "Other"], "The K largest, then Other")
        let other = try? XCTUnwrap(top.last)
        XCTAssertTrue(other.map(ChartRenderData.isOther) ?? false)
        XCTAssertEqual(top.reduce(0) { $0 + $1.yValue }, points.reduce(0) { $0 + $1.yValue }, accuracy: 0.001, "Nothing is dropped")
        XCTAssertEqual(other?.sourceRowIDs.count, 41)
    }

    func testPieSlicesPutOtherLastEvenWhenItIsLargest() {
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.chartType = .donut
        preset.topLimit = 1
        let result = QueryResultTable(
            columns: [QueryColumn(name: "region", type: "text"), QueryColumn(name: "n", type: "integer")],
            rows: [("A", "50"), ("B", "30"), ("C", "40")].map { QueryRow(cells: [.text($0.0), .integer($0.1)]) },
            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil, sourceQuery: nil)
        preset.xField = "region"; preset.yField = "n"; preset.yFields = ["n"]; preset.xAxisMode = .category
        let slices = ChartRenderData.build(result: result, preset: preset, dateFilter: nil).points
        XCTAssertEqual(slices.map(\.xText), ["A", "Other"])
        XCTAssertEqual(slices.last?.yValue, 70)
    }

    func testTopKOnADateAxisKeepsTheLargestPointsWithoutOther() {
        let points = (0..<10).map { index in
            VisualizationPlotPoint(id: "d\(index)", xText: "day \(index)", xNumber: nil, xDate: Date(timeIntervalSince1970: Double(index) * 86_400),
                                   yValue: Double(index), group: nil, label: nil, metric: "n", sourceRowIDs: [])
        }
        let top = ChartRenderData.topLimited(points, limit: 3, xMode: .date)
        XCTAssertEqual(top.map(\.yValue), [7, 8, 9], "A date axis has no place for Other, so the rest are left out")
    }

    func testTopKOnGroupedChartsKeepsTheLargestSeries() {
        let points = ["A": 100.0, "B": 50, "C": 5, "D": 1].flatMap { group, value in
            (0..<3).map { day in
                VisualizationPlotPoint(id: "\(group)\(day)", xText: "day \(day)", xNumber: nil, xDate: nil, yValue: value,
                                       group: group, label: nil, metric: "n", sourceRowIDs: [])
            }
        }
        let top = ChartRenderData.topLimited(points, limit: 2, xMode: .category)
        XCTAssertEqual(Set(top.compactMap(\.group)), ["A", "B", "Other"])
        XCTAssertEqual(top.filter { $0.group == "Other" }.map(\.yValue), [6, 6, 6], "C and D sum per day")
    }

    func testTilesSnapToTwentyFourthsAndStayReadable() {
        let layout = ChartTileLayout(spacing: 16)
        XCTAssertEqual(ChartTileLayout.effectiveSpan(4, width: 1_200, spacing: 16), 6, "Narrow tiles widen to the minimum width")
        XCTAssertEqual(ChartTileLayout.effectiveSpan(4, width: 360, spacing: 16), 24, "On a phone every tile is full width")
        let frames = layout.arrange(width: 1_184, spans: [12, 12, 8, 16, 24], heights: [300, 200, 300, 300, 300])
        XCTAssertEqual(frames.map { Int($0.minX) }, [0, 600, 0, 400, 0])
        XCTAssertEqual(frames.map { Int($0.minY) }, [0, 0, 316, 316, 632], "A row is as tall as its tallest tile")
        XCTAssertEqual(Int(frames[0].width), 584)
    }

    func testSizesFromEarlierVersionsAndUnknownPresentationsDecode() throws {
        let template = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object["gridSpan"] = nil
        object["tileSpan"] = 2
        object["presentation"] = "heatmap"
        let decoded = try JSONDecoder().decode(SavedVisualizationPreset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.gridSpan, 16, "Two of three columns become two thirds of the page")
        XCTAssertNil(decoded.presentation, "A presentation from a newer version falls back to the plot")
        XCTAssertNil(decoded.topLimit)
    }

    @MainActor
    func testLegendPositionSurvivesSavingAndUnknownPositionsFallBackToBottom() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legend-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var preset = VisualizationService.defaultPreset(for: .empty, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        preset.legendPosition = .right
        let store = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertTrue(store.saveVisualization(preset))
        let reopened = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(reopened.visualizations.first { $0.id == preset.id }?.legendPosition, .right, "Kept in the YAML library file")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        XCTAssertEqual(object["legendPosition"] as? String, "right")
        object["legendPosition"] = "left"
        let decoded = try JSONDecoder().decode(SavedVisualizationPreset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.legendPosition, "A position from a newer version falls back to the bottom")
        XCTAssertTrue(decoded.showsLegend)
    }

    func testSortingOrdersCategoriesAndKeepsOtherLast() {
        let points = [point("b", 5), point("a", 9), point("Other", 50), point("c", 1)].map { item -> VisualizationPlotPoint in
            item.xText == "Other"
                ? VisualizationPlotPoint(id: "portbase.other|users", xText: L10n.text("Other"), xNumber: nil, xDate: nil, yValue: 50,
                                         group: nil, label: nil, metric: "users", sourceRowIDs: [])
                : item
        }
        XCTAssertEqual(ChartRenderData.sorted(points, by: .valueDescending).map(\.xText), ["a", "b", "c", L10n.text("Other")])
        XCTAssertEqual(ChartRenderData.sorted(points, by: .valueAscending).map(\.xText), ["c", "b", "a", L10n.text("Other")])
        XCTAssertEqual(ChartRenderData.sorted(points, by: .label).map(\.xText), ["a", "b", "c", L10n.text("Other")])
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
        store.resizeChart(ids[1], height: 5_000, span: 99)
        store.setChartTopLimit(ids[1], 5)
        store.setChartDisplay(ids[1], chartType: nil, presentation: .table)
        store.setChartPageFilters(growth.id, dateRange: ChartDateRange(preset: .last30Days), values: ["region": "EU"])

        let reopened = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(reopened.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], ids[0]])
        let moved = try XCTUnwrap(reopened.charts(onPage: growth.id).first)
        XCTAssertEqual(moved.id, ids[1])
        XCTAssertEqual(moved.tileHeight, SavedVisualizationPreset.tileHeightRange.upperBound, "Sizes are clamped")
        XCTAssertEqual(moved.gridSpan, SavedVisualizationPreset.gridColumns)
        XCTAssertEqual(moved.topLimit, 5)
        XCTAssertEqual(moved.presentation, .table)
        let page = try XCTUnwrap(reopened.displayedChartPages.first { $0.id == growth.id })
        XCTAssertEqual(page.dateRange?.preset, .last30Days)
        XCTAssertEqual(page.parameterValues, ["region": "EU"])

        reopened.updateChart(ids[2]) { chart in
            chart.sortOrder = .valueDescending
            chart.barLayout = .normalized
            chart.isHorizontal = true
            chart.showsValues = true
        }
        let copy = try XCTUnwrap(reopened.duplicateChart(ids[2]))
        let original = try XCTUnwrap(reopened.visualizations.first { $0.id == ids[2] })
        XCTAssertNotEqual(copy.tileTitle, original.tileTitle, "A copy's tile says it is a copy")
        XCTAssertEqual(reopened.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], copy.id, ids[0]], "A copy sits right after its original")
        let again = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        let styled = try XCTUnwrap(again.visualizations.first { $0.id == ids[2] })
        XCTAssertEqual(styled.sortOrder, .valueDescending)
        XCTAssertEqual(styled.barLayout, .normalized)
        XCTAssertTrue(styled.isHorizontal)
        XCTAssertTrue(styled.showsValues)
        XCTAssertTrue(again.visualizations.first { $0.id == copy.id }?.isHorizontal == true, "A copy keeps the original's settings")

        reopened.deleteChartPage(growth.id)
        XCTAssertEqual(reopened.displayedChartPages.map(\.id), [ChartPage.defaultID])
        XCTAssertEqual(reopened.charts(onPage: ChartPage.defaultID).map(\.id), [ids[2], copy.id, ids[0], ids[1]], "A deleted page's charts move, not vanish")
    }
}
