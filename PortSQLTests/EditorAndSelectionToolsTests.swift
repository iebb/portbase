import XCTest
@testable import PortSQL

final class EditorAndSelectionToolsTests: XCTestCase {
    private func apply(_ edit: SQLLineEditing.RangeEdit?, to text: String) -> (String, NSRange)? {
        guard let edit else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), edit.selection)
    }

    func testDuplicateLines() {
        let text = "SELECT 1\nFROM t\nWHERE x"
        let middle = apply(SQLLineEditing.duplicateLines(text, selection: NSRange(location: 11, length: 0)), to: text)
        XCTAssertEqual(middle?.0, "SELECT 1\nFROM t\nFROM t\nWHERE x")
        XCTAssertEqual(middle?.1, NSRange(location: 18, length: 0), "The caret moves to the copy")
        let last = apply(SQLLineEditing.duplicateLines(text, selection: NSRange(location: 20, length: 0)), to: text)
        XCTAssertEqual(last?.0, "SELECT 1\nFROM t\nWHERE x\nWHERE x")
        XCTAssertEqual(last?.1, NSRange(location: 28, length: 0))
        let crlf = apply(SQLLineEditing.duplicateLines("a\r\nb", selection: NSRange(location: 3, length: 0)), to: "a\r\nb")
        XCTAssertEqual(crlf?.0, "a\r\nb\r\nb", "Keeps the file's line endings")
    }

    func testMoveLines() {
        let text = "one\ntwo\nthree"
        let up = apply(SQLLineEditing.moveLines(text, selection: NSRange(location: 5, length: 0), up: true), to: text)
        XCTAssertEqual(up?.0, "two\none\nthree")
        XCTAssertEqual(up?.1, NSRange(location: 1, length: 0))
        let down = apply(SQLLineEditing.moveLines(text, selection: NSRange(location: 5, length: 0), up: false), to: text)
        XCTAssertEqual(down?.0, "one\nthree\ntwo", "The last line gets the newline, the moved one gives it up")
        XCTAssertEqual(down?.1, NSRange(location: 11, length: 0))
        let lastUp = apply(SQLLineEditing.moveLines(text, selection: NSRange(location: 10, length: 0), up: true), to: text)
        XCTAssertEqual(lastUp?.0, "one\nthree\ntwo")
        let block = apply(SQLLineEditing.moveLines(text, selection: NSRange(location: 0, length: 8), up: false), to: text)
        XCTAssertEqual(block?.0, "three\none\ntwo", "A selection ending at a line's start doesn't take that line")
        XCTAssertNil(SQLLineEditing.moveLines(text, selection: NSRange(location: 0, length: 0), up: true))
        XCTAssertNil(SQLLineEditing.moveLines(text, selection: NSRange(location: 10, length: 0), up: false))
    }

    func testToggleCase() {
        XCTAssertEqual(apply(SQLLineEditing.toggleCase("select x", selection: NSRange(location: 0, length: 6)), to: "select x")?.0, "SELECT x")
        XCTAssertEqual(apply(SQLLineEditing.toggleCase("SELECT x", selection: NSRange(location: 0, length: 6)), to: "SELECT x")?.0, "select x")
        XCTAssertEqual(apply(SQLLineEditing.toggleCase("from orders o", selection: NSRange(location: 2, length: 0)), to: "from orders o")?.0, "FROM orders o",
                       "With nothing selected, the word at the caret")
    }

    func testNumericSelectionSummary() {
        let payload = ResultGridClipboard.Payload(columns: [QueryColumn(name: "total", type: "numeric")], rows: [
            QueryRow(cells: [.decimal("10.50")]), QueryRow(cells: [.decimal("2.25")]), QueryRow(cells: [.null]), QueryRow(cells: [.integer("7")]),
        ])
        let summary = ResultSelectionSummary.make(payload)
        XCTAssertEqual(summary.cells, 4)
        XCTAssertEqual(summary.values, 3)
        XCTAssertEqual(summary.nulls, 1)
        XCTAssertEqual(summary.sum, Decimal(string: "19.75"))
        XCTAssertEqual(summary.minimum, "2.25")
        XCTAssertEqual(summary.maximum, "10.5")
        XCTAssertEqual(summary.scale, 2)
        XCTAssertEqual(ResultSelectionSummary.plain(summary.average!, scale: 4), "6.5833")
        // Exact decimal arithmetic: 0.1 + 0.2 is 0.3, not 0.30000000000000004.
        let exact = ResultSelectionSummary.make(.init(columns: [QueryColumn(name: "n", type: "numeric")],
                                                      rows: [QueryRow(cells: [.decimal("0.1")]), QueryRow(cells: [.decimal("0.2")])]))
        XCTAssertEqual(exact.sum.map { ResultSelectionSummary.plain($0) }, "0.3")
    }

    func testMixedAndDateSelections() {
        let mixed = ResultSelectionSummary.make(.init(columns: [QueryColumn(name: "a", type: "text"), QueryColumn(name: "b", type: "int")],
                                                      rows: [QueryRow(cells: [.text("x"), .integer("1")]), QueryRow(cells: [.text("x"), .integer("2")])]))
        XCTAssertNil(mixed.sum, "Text in the selection means no sum")
        XCTAssertEqual(mixed.distinct, 3)
        let dates = ResultSelectionSummary.make(.init(columns: [QueryColumn(name: "d", type: "date")],
                                                      rows: [QueryRow(cells: [.dateTime("2026-03-01")]), QueryRow(cells: [.dateTime("2025-12-31")])]))
        XCTAssertEqual(dates.minimum, "2025-12-31")
        XCTAssertEqual(dates.maximum, "2026-03-01")
        XCTAssertNil(dates.sum)
    }

    func testLoadedRowsSortByTypeWithNullsLast() {
        let result = QueryResultTable(columns: [QueryColumn(name: "n", type: "numeric"), QueryColumn(name: "name", type: "text")], rows: [
            QueryRow(cells: [.decimal("10.5"), .text("item10")]),
            QueryRow(cells: [.null, .text("item2")]),
            QueryRow(cells: [.decimal("9"), .null]),
            QueryRow(cells: [.decimal("-3"), .text("Item1")]),
            QueryRow(cells: [.decimal("9.00"), .text("item2")]),
        ], executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil, sourceQuery: nil)
        let all = Array(result.rows.indices)
        XCTAssertEqual(LoadedResultSort(column: 0).ordered(all, in: result), [3, 2, 4, 0, 1], "Numerically, not as text; ties keep their order")
        XCTAssertEqual(LoadedResultSort(column: 0, descending: true).ordered(all, in: result), [0, 2, 4, 3, 1], "NULLs stay last")
        XCTAssertEqual(LoadedResultSort(column: 1).ordered(all, in: result), [3, 1, 4, 0, 2], "Natural order: item2 before item10")
        XCTAssertEqual(LoadedResultSort(column: 0).ordered([4, 0, 3], in: result), [3, 4, 0], "Sorts within a filtered set")
        XCTAssertEqual(LoadedResultSort.next(after: nil, column: 1), LoadedResultSort(column: 1))
        XCTAssertEqual(LoadedResultSort.next(after: LoadedResultSort(column: 1), column: 1), LoadedResultSort(column: 1, descending: true))
        XCTAssertNil(LoadedResultSort.next(after: LoadedResultSort(column: 1, descending: true), column: 1))
        XCTAssertEqual(LoadedResultSort.next(after: LoadedResultSort(column: 1, descending: true), column: 0), LoadedResultSort(column: 0))
    }

    func testEditorMarksTheStatementAndMatchingBracket() {
        let script = "SELECT COUNT(*) FROM t;\nSELECT ')' AS x, (1 + (2)) FROM u;"
        let source = script as NSString
        let caretAfterCount = source.range(of: "COUNT(").location + 6
        let marks = SQLEditorDecorations.marks(in: script, selection: NSRange(location: caretAfterCount, length: 0), engine: .postgresql)
        XCTAssertEqual(marks.brackets, [NSRange(location: caretAfterCount - 1, length: 1), NSRange(location: caretAfterCount + 1, length: 1)])
        XCTAssertEqual(marks.statement.map { source.substring(with: $0) }?.hasPrefix("SELECT COUNT(*) FROM t"), true)

        let outer = source.range(of: "(1 + (2))").location
        let nested = SQLEditorDecorations.marks(in: script, selection: NSRange(location: outer, length: 0), engine: .postgresql)
        XCTAssertEqual(nested.brackets, [NSRange(location: outer, length: 1), NSRange(location: outer + 8, length: 1)],
                       "Nested pairs count, and the ')' in the string doesn't")
        XCTAssertEqual(nested.statement.map { source.substring(with: $0) }?.hasPrefix("SELECT ')'"), true)

        let inString = source.range(of: "')'").location + 2
        XCTAssertTrue(SQLEditorDecorations.marks(in: script, selection: NSRange(location: inString, length: 0), engine: .postgresql).brackets.isEmpty)
        XCTAssertNil(SQLEditorDecorations.marks(in: "SELECT (1)", selection: NSRange(location: 3, length: 0), engine: .postgresql).statement,
                     "One statement needs no mark")
        XCTAssertNil(SQLEditorDecorations.marks(in: script, selection: NSRange(location: 0, length: 6), engine: .postgresql).statement,
                     "A selection runs as it is")
        XCTAssertEqual(SQLEditorDecorations.marks(in: "{\"a\": [1, 2]}", selection: NSRange(location: 1, length: 0), engine: nil).brackets.count, 2,
                       "JSON brackets match too")
    }
}
