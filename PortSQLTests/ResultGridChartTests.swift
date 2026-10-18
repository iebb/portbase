import XCTest
@testable import PortSQL

final class ResultGridChartTests: XCTestCase {
    @MainActor func testMalformedChartLibraryRecoversWholeBackupAndPreservesDamagedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        var preset = SavedVisualizationPreset.empty
        preset.title = "Saved chart"
        preset.sourceQuery = "SELECT\tid FROM sales;"
        store.saveVisualization(preset)
        store.saveVisualization(preset)
        let file = directory.appendingPathComponent("visualization-presets.yml")
        let backup = file.appendingPathExtension("backup")
        // Older encoders used literal tabs in quoted SQL; recovery must retain those drafts too.
        let previous = try String(contentsOf: backup, encoding: .utf8).replacingOccurrences(of: "\\t", with: "\t")
        try previous.write(to: backup, atomically: true, encoding: .utf8)
        let damaged = previous + "\n- id: \"unfinished-chart\"\n  title: \"unfinished\""
        try damaged.write(to: file, atomically: true, encoding: .utf8)

        let recovered = WorkspaceLibraryStore(directory: directory, cloudSyncEnabled: false)
        XCTAssertEqual(recovered.visualizations.map(\.id), [preset.id])
        XCTAssertEqual(recovered.visualizations.first?.sourceQuery, preset.sourceQuery)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), previous)
        let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("visualization-presets.yml.damaged-") })
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), damaged)
    }

    func testRangeCopyPreservesTypesAndVisibleColumnOrder() throws {
        let result = QueryResultTable(columns: [
            QueryColumn(name: "optional", type: "text"), QueryColumn(name: "text", type: "text"),
            QueryColumn(name: "bytes", type: "binary"), QueryColumn(name: "time", type: "timestamp")
        ], rows: [QueryRow(cells: [.null, .text(""), .binary(Data([0, 255])), .dateTime("2026-09-22 12:00:00.123456+09")]),
                  QueryRow(cells: [.text("NULL"), .text("a\tb\nc"), .binary(Data()), .dateTime("2026-09-23 12:00:00.000001+09")])],
            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil)
        let selection = ResultGridSelection(anchor: .init(row: 1, column: 3), end: .init(row: 0, column: 0))
        let payload = ResultGridClipboard.payload(result: result, visibleColumns: [3, 0, 1, 2], selection: selection)
        XCTAssertEqual(payload.columns.map(\.name), ["time", "optional", "text", "bytes"])
        XCTAssertEqual(payload.rows[0].cells, [.dateTime("2026-09-22 12:00:00.123456+09"), .null, .text(""), .binary(Data([0, 255]))])
        let text = ResultGridClipboard.text(payload, headers: false)
        XCTAssertTrue(text.contains("\tNULL\t\"\"\t\"0x00ff\""))
        XCTAssertTrue(text.contains("\t\"NULL\"\t\"a\tb\nc\""))
        let decoded = try JSONDecoder().decode(ResultGridClipboard.Payload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.rows.map(\.cells), payload.rows.map(\.cells))
    }

    func testDateFilteredAggregateDrilldownRetainsOnlyContributingDocuments() throws {
        var result = QueryResultTable(columns: [QueryColumn(name: "day", type: "date"), QueryColumn(name: "region", type: "text"), QueryColumn(name: "amount", type: "decimal")],
            rows: [QueryRow(cells: [.dateTime("2026-09-21T15:00:00Z"), .text("East"), .decimal("10.5")]),
                   QueryRow(cells: [.dateTime("2026-09-22T03:00:00Z"), .text("East"), .decimal("20")]),
                   QueryRow(cells: [.dateTime("2026-09-23T00:00:00Z"), .text("East"), .decimal("50")]),
                   QueryRow(cells: [.dateTime("2026-09-22T03:00:00Z"), .text("West"), .decimal("9")])],
            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: "sales", isExplorerGenerated: true)
        result.documents = ["{\"_id\":1}", "{\"_id\":2}", "{\"_id\":3}", "{\"_id\":4}"]
        let formatter = ISO8601DateFormatter()
        let filter = VisualizationDateFilter(field: "day", start: try XCTUnwrap(formatter.date(from: "2026-09-21T15:00:00Z")), end: try XCTUnwrap(formatter.date(from: "2026-09-22T15:00:00Z")))
        let filtered = VisualizationService.filteredResult(result, dateFilter: filter)
        var preset = SavedVisualizationPreset.empty
        preset.xField = "region"; preset.yField = "amount"; preset.xAxisMode = .category
        let point = try XCTUnwrap(VisualizationService.chartPoints(for: filtered, preset: preset).first { $0.xText == "East" })
        XCTAssertEqual(point.yValue, 30.5)
        let matching = VisualizationService.matchingResult(filtered, point: point)
        XCTAssertEqual(matching.rows.map(\.id), Array(result.rows.prefix(2)).map(\.id))
        XCTAssertEqual(matching.documents, Array(result.documents!.prefix(2)))
        XCTAssertEqual(matching.isExplorerGenerated, false)
        XCTAssertEqual(matching.rows[0].cells[0], result.rows[0].cells[0])
        XCTAssertNil(VisualizationService.parsedNumber(from: "NaN"))
        XCTAssertNil(VisualizationService.parsedNumber(from: "Infinity"))
    }
}

final class ResultGridColumnOrderTests: XCTestCase {
    private func columns(_ names: String...) -> [QueryColumn] { names.map { QueryColumn(name: $0, type: "text") } }

    func testSavedOrderAppliesByNameAndNewColumnsKeepTheirPlace() {
        let saved = ["email", "name", "id"]
        XCTAssertEqual(ResultGridColumnOrder.apply(saved, to: columns("id", "name", "email")), [2, 1, 0])
        // "created_at" is new: it stays at its own position while the known columns follow the saved order.
        XCTAssertEqual(ResultGridColumnOrder.apply(saved, to: columns("id", "created_at", "name", "email")), [3, 1, 2, 0])
        XCTAssertEqual(ResultGridColumnOrder.apply([], to: columns("a", "b")), [0, 1])
    }

    func testDuplicateNamesKeepSeparatePlaces() {
        let cols = columns("id", "name", "id")
        XCTAssertEqual(ResultGridColumnOrder.keys(for: cols), ["id", "name", "id#1"])
        XCTAssertEqual(ResultGridColumnOrder.apply(["id#1", "name", "id"], to: cols), [2, 1, 0])
    }

    func testVisibleColumnsFollowTheOrderWithPinnedFirst() {
        var configuration = ResultGridConfiguration()
        configuration.hidden = [1]
        configuration.pinned = [0]
        XCTAssertEqual(configuration.visibleColumns(count: 4, order: [3, 2, 1, 0]), [0, 3, 2])
        XCTAssertEqual(configuration.visibleColumns(count: 4, order: [9, 9]), [0, 2, 3], "An invalid order falls back to the natural one")
    }
}
