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

    // MARK: Reading dates and numbers

    /// The formatters the charts read every date with before `ChartDateText`, kept here to check against.
    private static let earlierDateFormatters: (iso: [ISO8601DateFormatter], text: [DateFormatter]) = {
        let options: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
        let iso = options.map { options in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            return formatter
        }
        let text = ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy/MM/dd", "yyyy/MM/dd HH:mm:ss", "MM/dd/yyyy", "MM/dd/yyyy HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
        return (iso, text)
    }()

    private func earlierDate(_ text: String) -> Date? {
        let formatters = Self.earlierDateFormatters
        for formatter in formatters.iso { if let date = formatter.date(from: text) { return date } }
        for formatter in formatters.text { if let date = formatter.date(from: text) { return date } }
        return nil
    }

    private static let earlierNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        return formatter
    }()

    private func earlierNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) { return direct.isFinite ? direct : nil }
        guard let value = Self.earlierNumberFormatter.number(from: trimmed)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    /// The same values every run.
    private struct Sequence: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    func testDatesTheFormattersReadAreReadTheSame() {
        var texts = ["2026-01-05", "2026-01-05 10:20:30", "2026-01-05T10:20:30", "2026-01-05T10:20:30Z", "2026-01-05T10:20:30z",
                     "2026-01-05T10:20:30.123Z", "2026-01-05T10:20:30.123456Z", "2026-01-05T10:20:30.1Z", "2026-01-05T10:20:30.9999Z",
                     "2026-01-05T10:20:30.0005Z", "1969-12-31T23:59:59.5Z", "2026-01-05T10:20:30.123+09:00", "2026-01-05T10:20:30+09:00",
                     "2026-01-05T10:20:30+0900", "2026-01-05T10:20:30+09", "2026-01-05T10:20:30-00:30", "2026-01-05T10:20:30+14:00",
                     "2026-01-05T10:20:30-12:00", "2026-01-05T10:20:30+25:00", "2026-01-05T10:20:30+09:60", "2026-01-05T10:20:30+0",
                     "2026-01-05T10:20:30+9", "2026-01-05T10:20:30+090", "2026-01-05T10:20:30ZZ", "2026-01-05T10:20:30 Z",
                     "2026-1-5", "2026-13-05", "2026-02-30", "2026-02-29", "2024-02-29", "2100-02-29", "2000-02-29", "2026-00-10", "2026-01-00",
                     "2026-01-05 24:00:00", "2026-01-05 23:59:60", "2026-01-05 23:59:59", "2026/01/05", "2026/01/05 10:20:30", "2026/1/5",
                     "01/05/2026", "01/05/2026 10:20:30", "1/5/2026", "13/05/2026", "1/5/26", "2026-01-05 trailing", "2026-01-05t10:20:30Z",
                     "-2026-01-05", "+2026-01-05", "0001-01-01", "0099-01-01", "99-01-01", "026-01-05", "1500-03-01", "1582-10-10",
                     "1599-12-31", "1600-01-01", "1600-02-29", "9999-12-31 23:59:59", "10000-01-01", "20260105", "20260105T102030Z",
                     "٢٠٢٦-٠١-٠٥", "12:30:00", "2026-01", "1e-5", "5-3", "2026-01-05  10:20:30", "2026-01-5 1:2:3", "abc", "12345",
                     "3f2a9c1e-0000-4000-8000-123456789abc", "12345678-1234-4234-8234-123456789012", "value 12", "2026-01-05T25:00:00Z",
                     "2026-01-05T10:60:00Z", "2026-01-05T10:20:60Z", "1970-01-01", "1970-01-01T00:00:00Z", "2038-01-19 03:14:08"]
        var random = Sequence()
        for _ in 0..<1_500 {
            let year = Int.random(in: 1590...2110, using: &random), month = Int.random(in: 0...13, using: &random), day = Int.random(in: 0...32, using: &random)
            let hour = Int.random(in: 0...24, using: &random), minute = Int.random(in: 0...60, using: &random), second = Int.random(in: 0...60, using: &random)
            let padded = Int.random(in: 0..<8, using: &random) > 0
            func field(_ value: Int, _ width: Int = 2) -> String { padded ? String(format: "%0\(width)d", value) : String(value) }
            let separator = ["-", "-", "-", "/"].randomElement(using: &random)!
            var text = Int.random(in: 0..<6, using: &random) == 0
                ? [field(month), field(day), field(year, 4)].joined(separator: "/")
                : [field(year, 4), field(month), field(day)].joined(separator: separator)
            if Int.random(in: 0..<4, using: &random) > 0 {
                text += ["T", " ", " "].randomElement(using: &random)! + [field(hour), field(minute), field(second)].joined(separator: ":")
                if Int.random(in: 0..<3, using: &random) == 0 { text += "." + String(Int.random(in: 0...999_999, using: &random)) }
                text += ["", "", "Z", "+00", "+00:00", "-0530", "+09:00", "+14:00", "-12", " UTC"].randomElement(using: &random)!
            }
            texts.append(text)
        }
        let characters = Array("0123456789-/: TZ.+")
        for _ in 0..<600 {
            texts.append(String((0..<Int.random(in: 6...22, using: &random)).map { _ in characters.randomElement(using: &random)! }))
        }
        // Numbers, which are never handed to the formatters, and text that is nearly one.
        let numeric = Array("0123456789012345..-+eE")
        for _ in 0..<1_500 {
            texts.append(String((0..<Int.random(in: 1...12, using: &random)).map { _ in numeric.randomElement(using: &random)! }))
        }
        texts += ["1.2.3", "1.5", "12498.75", "-0.5", "+3.25", "1e5", "1.5e-3", "2026.01.05", "2026.0105", "20.26", "1767608430.5", "0x10", "١٢٣", "١.٥", "inf", "nan"]

        var readByBoth = 0
        for text in texts {
            let now = VisualizationService.parsedDate(from: text, sourceType: "text")
            guard let earlier = earlierDate(text) else { continue }
            readByBoth += 1
            XCTAssertEqual(now, earlier, text.debugDescription)
        }
        XCTAssertGreaterThan(readByBoth, 400, "The values exercise the dates the formatters read")
    }

    func testDatesDatabasesPrintAreRead() {
        func seconds(_ text: String) -> Double? { VisualizationService.parsedDate(from: text, sourceType: "")?.timeIntervalSince1970 }
        XCTAssertEqual(seconds("2026-01-05"), 1_767_571_200)
        XCTAssertEqual(seconds("2026-01-05 10:20:30"), 1_767_608_430)
        XCTAssertEqual(seconds(" 2026-01-05T10:20:30Z\n"), 1_767_608_430)
        // PostgreSQL's timestamptz, a MySQL DATETIME(6) and ClickHouse's DateTime64 weren't read as dates at all.
        XCTAssertEqual(seconds("2026-01-05 10:20:30+00:00"), 1_767_608_430)
        XCTAssertEqual(seconds("2026-01-05 10:20:30+09"), 1_767_576_030)
        XCTAssertEqual(seconds("2026-01-05 19:20:30.5+0900"), 1_767_608_430.5)
        XCTAssertEqual(seconds("2026-01-05 10:20:30.123456"), 1_767_608_430.123)
        XCTAssertEqual(seconds("2026-01-05T10:20:30.25"), 1_767_608_430.25)
        XCTAssertEqual(seconds("2026-01-05 10:20:30Z"), 1_767_608_430)
        XCTAssertEqual(seconds("2026-01-05 04:50:30-05:30"), 1_767_608_430)
        XCTAssertEqual(seconds("1969-12-31 23:59:59.25"), -0.75)
        XCTAssertEqual(seconds("2024-02-29 00:00:00"), 1_709_164_800)
        XCTAssertEqual(seconds("9999-12-31 23:59:59"), 253_402_300_799)
        // Seconds and milliseconds since 1970 still count.
        XCTAssertEqual(seconds("1767608430"), 1_767_608_430)
        XCTAssertEqual(seconds("1767608430123"), 1_767_608_430.123)
        for text in ["", "  ", "abc", "42", "-5", "2026-02-30 10:00:00", "2026-01-05 10:20", "2026-01-05 10:20:30.", "2026-01-05 10:20:30+", "2026-01-05 10:20:30+1",
                     "2026-01-05 10:20:30.1234567890", "2026-01-05 10:20:30 +09:00", "2026-01-05 25:00:00", "2026-01-05 10:20:30+15:00x",
                     "3f2a9c1e-0000-4000-8000-123456789abc", "10:20:30", "2026-01-05 10:20:30.5.5"] {
            XCTAssertNil(seconds(text), text.debugDescription)
        }
        XCTAssertFalse(ChartDateText.mayBeDate("3f2a9c1e-0000"), "An identifier isn't handed to the formatters")
        XCTAssertFalse(ChartDateText.mayBeDate("12345"))
        XCTAssertFalse(ChartDateText.mayBeDate("north-1"))
        XCTAssertTrue(ChartDateText.mayBeDate("1/5/2026"))
        XCTAssertTrue(ChartDateText.mayBeDate("٢٠٢٦-٠١-٠٥"))
    }

    func testNumbersAreReadAsTheFormatterReadThem() {
        var texts = ["1,234.5", "12 abc", "abc", "1 234", "12%", "$5", "١٢٣", "1e5", "1E5", "+5", "-5", ".5", "5.", "1,2,3", "0x10", "1_000", "１２",
                     "nan", "inf", "-inf", "infinity", "NaN", "-", ".", "1.2.3", "(5)", "5-", "1e", "1,234,567.89e2", "  ", "1\u{00A0}234", "+1,234",
                     "1,", ",1", "٣٫٥", "1e+5", "1E-3", "1.5E", "E5", "1,23", "0,5", " 42 ", "\t7\n", "1e999", "-1e999", "0x1p3", "007", "+.5e1", "٤٢ ", "1e5x"]
        var random = Sequence()
        let characters = Array("0123456789012345+-.,eExX_ %")
        for _ in 0..<6_000 {
            texts.append(String((0..<Int.random(in: 1...8, using: &random)).map { _ in characters.randomElement(using: &random)! }))
        }
        for text in texts {
            XCTAssertEqual(VisualizationService.parsedNumber(from: text), earlierNumber(text), text.debugDescription)
        }
    }

    func testTimestampsWithAZoneOrAFractionChartOverTime() throws {
        let result = QueryResultTable(
            columns: [QueryColumn(name: "at", type: "timestamptz"), QueryColumn(name: "seen", type: "timestamp"), QueryColumn(name: "total", type: "integer")],
            rows: [QueryRow(cells: [.dateTime("2026-01-05 10:00:00+00:00"), .dateTime("2026-01-05 10:00:00.25"), .integer("3")]),
                   QueryRow(cells: [.dateTime("2026-01-06 10:00:00+00:00"), .dateTime("2026-01-06 10:00:00.5"), .integer("5")]),
                   QueryRow(cells: [.dateTime("2026-01-06 10:00:00+00:00"), .dateTime("2026-01-07 10:00:00.75"), .integer("7")])],
            executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil)
        var preset = VisualizationService.defaultPreset(for: result, connectionProfileID: nil, connectionName: "", databaseName: nil, sourceTableReference: nil)
        XCTAssertEqual(preset.xField, "at")
        XCTAssertEqual(preset.xAxisMode, .date)
        let points = VisualizationService.chartPoints(for: result, preset: preset)
        XCTAssertEqual(points.map(\.yValue), [3, 12], "Rows at the same instant add up")
        XCTAssertEqual(points.first?.xDate, Date(timeIntervalSince1970: 1_767_607_200))
        preset.xField = "seen"
        XCTAssertEqual(VisualizationService.chartPoints(for: result, preset: preset).count, 3)
        let bounds = try XCTUnwrap(VisualizationService.dateBounds(for: result, field: "seen"))
        XCTAssertEqual(bounds.upperBound.timeIntervalSince1970 - bounds.lowerBound.timeIntervalSince1970, 172_800.5)
    }

    func testFieldDescriptorsAreKeptPerResult() {
        let first = countryResult(columns: ["country", "users"], rows: [["Japan", "5"], [" Japan ", "7"], ["", "9"], ["Chile", "x"]])
        let descriptors = VisualizationService.fieldDescriptors(for: first)
        XCTAssertEqual(descriptors.map(\.nonEmptyCount), [3, 4])
        XCTAssertEqual(descriptors.map(\.distinctCount), [2, 4], "Values are compared without surrounding spaces")
        XCTAssertEqual(descriptors.map(\.sampleValue), ["Japan", "5"])
        XCTAssertEqual(VisualizationService.fieldDescriptors(for: first), descriptors)
        XCTAssertTrue(VisualizationService.hasNumericField(first))

        // The same shape and size, fetched again with other values.
        let second = countryResult(columns: ["country", "users"], rows: [["Peru", "5"], ["Peru", "5"], ["Peru", "5"], ["Peru", "5"]])
        XCTAssertEqual(VisualizationService.fieldDescriptors(for: second).map(\.distinctCount), [1, 1])

        let words = QueryResultTable(columns: [QueryColumn(name: "name", type: "text"), QueryColumn(name: "amount", type: "text")],
                                     rows: [QueryRow(values: ["a", "1.5"]), QueryRow(values: ["b", "2"])],
                                     executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil)
        XCTAssertTrue(VisualizationService.hasNumericField(words), "Text that reads as numbers counts")
        var named = words
        named.rows = [QueryRow(values: ["a", "x"]), QueryRow(values: ["b", "y"])]
        XCTAssertFalse(VisualizationService.hasNumericField(named))
        XCTAssertFalse(VisualizationService.hasNumericField(.empty))

        let blob = QueryResultTable(columns: [QueryColumn(name: "body", type: "blob")],
                                    rows: [QueryRow(cells: [.binary(Data(repeating: 1, count: 400_000))]), QueryRow(cells: [.binary(Data([2]))]), QueryRow(cells: [.null])],
                                    executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil)
        let body = VisualizationService.fieldDescriptors(for: blob)[0]
        XCTAssertEqual([body.nonEmptyCount, body.distinctCount], [2, 2])
        XCTAssertLessThan(body.sampleValue.count, 600)
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
