import XCTest
@testable import PortSQL

final class WorkspaceInsightsAndPaletteTests: XCTestCase {
    private func table(_ columns: [(String, String)], _ rows: [[QueryCell]]) -> QueryResultTable {
        QueryResultTable(
            columns: columns.map { QueryColumn(name: $0.0, type: $0.1) },
            rows: rows.map { QueryRow(cells: $0) },
            executionSummary: "",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil,
            sourceQuery: nil,
            affectedRowCount: nil,
            isTruncated: false,
            isExplorerGenerated: false
        )
    }

    func testInsightsSummarizeNumericColumnsAndKeepNullDistinctFromEmptyText() {
        let result = table([("total", "numeric"), ("note", "text")], [
            [.decimal("10.5"), .text("")],
            [.integer("20"), .null],
            [.null, .text("NULL")],
            [.integer("30"), .text("")],
        ])

        let insights = ResultInsightsService.insights(for: result)
        XCTAssertEqual(insights.rowCount, 4)

        let total = insights.columns[0]
        XCTAssertEqual(total.kind, .numeric)
        XCTAssertEqual(total.nullCount, 1)
        XCTAssertEqual(total.distinctCount, 3)
        XCTAssertEqual(total.numeric?.minimum, 10.5)
        XCTAssertEqual(total.numeric?.maximum, 30)
        XCTAssertEqual(total.numeric?.median, 20)
        XCTAssertEqual(total.numeric?.sum, 60.5)
        XCTAssertEqual(total.numeric?.bins.reduce(0) { $0 + $1.count }, 3)

        let note = insights.columns[1]
        XCTAssertEqual(note.kind, .text)
        XCTAssertEqual(note.nullCount, 1, "SQL NULL is counted separately")
        XCTAssertEqual(note.emptyTextCount, 2, "Empty text is not NULL")
        XCTAssertEqual(note.topValues.first, ValueFrequency(value: "", count: 2))
        XCTAssertTrue(note.topValues.contains(ValueFrequency(value: "NULL", count: 1)), "The literal string NULL stays a value")
        XCTAssertEqual(insights.completeness, 6.0 / 8.0, accuracy: 0.0001)
    }

    func testInsightsTrackTemporalRangesUniqueKeysAndBinaryBytes() {
        let result = table([("id", "int"), ("placed_at", "date"), ("payload", "blob")], [
            [.integer("1"), .dateTime("2026-10-03"), .binary(Data([0x00, 0xFF]))],
            [.integer("2"), .dateTime("2026-10-07"), .binary(Data([0x00, 0xFF]))],
            [.integer("3"), .dateTime("2026-10-05"), .binary(Data([0x01]))],
        ])

        let insights = ResultInsightsService.insights(for: result)
        XCTAssertTrue(insights.columns[0].isUnique)
        XCTAssertEqual(insights.columns[1].kind, .temporal)
        XCTAssertEqual(insights.columns[1].earliest, "2026-10-03")
        XCTAssertEqual(insights.columns[1].latest, "2026-10-07")
        XCTAssertNil(insights.columns[1].numeric)
        XCTAssertEqual(insights.columns[2].kind, .binary)
        XCTAssertEqual(insights.columns[2].topValues.first, ValueFrequency(value: "0x00ff", count: 2))
    }

    func testHistogramHandlesConstantColumns() throws {
        let summary = try XCTUnwrap(ResultInsightsService.summary(of: [4, 4, 4]))
        XCTAssertEqual(summary.bins.count, 1)
        XCTAssertEqual(summary.bins[0].count, 3)
        XCTAssertEqual(summary.mean, 4)
    }

    func testActivityBucketsRecentHistoryByDayAndOutcome() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15)))
        func entry(daysAgo: Int, outcome: QueryHistoryOutcome?, duration: TimeInterval?, connection: String = "Prod") -> QueryHistoryEntry {
            QueryHistoryEntry(title: "q", sql: "SELECT 1", connectionName: connection, summary: "",
                              executedAt: now.addingTimeInterval(TimeInterval(-daysAgo * 86_400)), duration: duration, outcome: outcome)
        }
        let history = [
            entry(daysAgo: 0, outcome: .succeeded, duration: 0.1),
            entry(daysAgo: 0, outcome: .failed, duration: 0.3),
            entry(daysAgo: 1, outcome: nil, duration: 0.2, connection: "Staging"),
            entry(daysAgo: 2, outcome: .cancelled, duration: nil),
            entry(daysAgo: 30, outcome: .succeeded, duration: 9),
        ]

        let activity = WorkspaceActivityService.activity(history: history, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(activity.days.count, 7)
        XCTAssertEqual(activity.executionCount, 4, "Entries outside the window are excluded")
        XCTAssertEqual(activity.days.last?.succeeded, 1)
        XCTAssertEqual(activity.days.last?.failed, 1)
        XCTAssertEqual(activity.days[5].succeeded, 1, "Legacy entries without an outcome count as succeeded")
        XCTAssertEqual(activity.days[4].cancelled, 1)
        XCTAssertEqual(try XCTUnwrap(activity.successRate), 2.0 / 3.0, accuracy: 0.0001, "Cancelled runs do not affect the success rate")
        XCTAssertEqual(try XCTUnwrap(activity.medianDuration), 0.2, accuracy: 0.0001)
        XCTAssertEqual(activity.busiestConnection, "Prod")
    }

    func testActivityWithoutHistoryHasNoRates() {
        let activity = WorkspaceActivityService.activity(history: [])
        XCTAssertFalse(activity.hasActivity)
        XCTAssertNil(activity.successRate)
        XCTAssertNil(activity.medianDuration)
        XCTAssertEqual(activity.days.count, 14)
    }

    func testTemplatesQuoteIdentifiersPerEngineAndSeparateWrites() {
        let table = SchemaTableDescriptor(schemaName: "public", name: "order items", columns: [
            SchemaColumnDescriptor(name: "id", type: "int", isNullable: false, isPrimaryKey: true, isUnique: true),
            SchemaColumnDescriptor(name: "unit price", type: "numeric", isNullable: true, isPrimaryKey: false, isUnique: false),
        ], rowCountEstimate: nil)

        let postgres = SQLTemplateService.templates(table: table, engine: .postgresql)
        XCTAssertTrue(postgres.first { $0.kind == .select }?.sql.contains("FROM public.\"order items\"") == true)
        XCTAssertTrue(postgres.first { $0.kind == .select }?.sql.contains("\"unit price\"") == true)
        XCTAssertEqual(Set(postgres.filter(\.isWrite).map(\.kind)), [.insert, .update, .delete, .createIndex])
        XCTAssertTrue(postgres.first { $0.kind == .update }?.sql.contains(":id") == true, "Write templates use named parameters, never literal values")

        let mysql = SQLTemplateService.templates(table: table, engine: .mysql)
        XCTAssertTrue(mysql.first { $0.kind == .select }?.sql.contains("`order items`") == true)
        XCTAssertEqual(SQLTemplateService.identifier("plain_name", engine: .mysql), "plain_name")
        XCTAssertEqual(SQLTemplateService.identifier("we\"ird", engine: .sqlite), "\"we\"\"ird\"")
    }

    func testTemplateInsertionReplacesSelectionAtUTF16Cursor() {
        let edit = SQLTemplateService.insert("SELECT 1;", into: "-- é\nOLD", cursor: 5, selectionLength: 3)
        XCTAssertEqual(edit.text, "-- é\nSELECT 1;")
        XCTAssertEqual(edit.cursor, ("-- é\nSELECT 1;" as NSString).length)

        let appended = SQLTemplateService.insert("SELECT 2;", into: "SELECT 1;", cursor: 99, selectionLength: 0)
        XCTAssertEqual(appended.text, "SELECT 1;\n\nSELECT 2;")
    }

    func testCommandPaletteSearchRanksPrefixesAboveSubsequences() throws {
        let prefix = try XCTUnwrap(CommandPaletteSearch.score("Format Query", query: "for"))
        let word = try XCTUnwrap(CommandPaletteSearch.score("Run Format", query: "for"))
        let fuzzy = try XCTUnwrap(CommandPaletteSearch.score("Find Our Rows", query: "for"))
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, fuzzy)
        XCTAssertNil(CommandPaletteSearch.score("Explain", query: "xyz"))
        XCTAssertEqual(CommandPaletteSearch.score("Anything", query: "  "), 0)
    }

    func testThemePreferencesFallBackToDefaults() {
        let defaults = UserDefaults.standard
        let previousTheme = defaults.string(forKey: EditorTheme.storageKey)
        let previousAccent = defaults.string(forKey: PortbaseAccent.storageKey)
        defer {
            defaults.set(previousTheme, forKey: EditorTheme.storageKey)
            defaults.set(previousAccent, forKey: PortbaseAccent.storageKey)
        }
        defaults.set("unknown", forKey: EditorTheme.storageKey)
        defaults.set("unknown", forKey: PortbaseAccent.storageKey)
        XCTAssertEqual(EditorTheme.current, .portbase)
        XCTAssertEqual(PortbaseAccent.current, .indigo)
        XCTAssertTrue(EditorTheme.midnight.palette(for: .light).isDark)
        XCTAssertFalse(EditorTheme.paper.palette(for: .dark).isDark)
        XCTAssertNotEqual(EditorTheme.portbase.palette(for: .light), EditorTheme.portbase.palette(for: .dark))
    }
}
