import XCTest
@testable import PortSQL
#if os(macOS)
import AppKit
import SwiftUI
#endif

final class EditorAndSelectionToolsTests: XCTestCase {
#if os(macOS)
    @MainActor
    func testMacPointerDragSelectsRectangleAndReturnEditsTheRange() async throws {
        var selection: ResultGridSelection?
        var openedBulkEditor = false
        let result = QueryResultTable(columns: [QueryColumn(name: "a", type: "text"), QueryColumn(name: "b", type: "text")],
                                      rows: (0..<4).map { QueryRow(cells: [.text(String($0)), .text("value")]) },
                                      executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil, sourceQuery: nil)
        let grid = GridCollectionBridge(result: result, visibleColumns: [0, 1], configuration: ResultGridConfiguration(),
                                        selection: Binding(get: { selection }, set: { selection = $0 }), extendsSelection: .constant(false),
                                        rowHeight: 24, primaryKeys: [], sortedColumn: nil, sortDirection: nil,
                                        onInspectCell: { _, _ in }, onEditSelectedCells: { openedBulkEditor = true; return true },
                                        onConfigureColumn: { _ in }, onPinColumn: { _ in }, onHideColumn: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: grid)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        for _ in 0..<20 where findTable(host) == nil { await Task.yield() }
        let table = try XCTUnwrap(findTable(host))
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, row: Int, column: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let rect = table.frameOfCell(atColumn: column, row: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        table.mouseDown(with: try event(.leftMouseDown, row: 0, column: 0))
        table.mouseDragged(with: try event(.leftMouseDragged, row: 2, column: 1))
        table.mouseUp(with: try event(.leftMouseUp, row: 2, column: 1))
        XCTAssertEqual(selection, ResultGridSelection(anchor: .init(row: 0, column: 0), end: .init(row: 2, column: 1)))
        table.mouseDown(with: try event(.leftMouseDown, row: 3, column: 1, flags: .shift))
        table.mouseUp(with: try event(.leftMouseUp, row: 3, column: 1))
        XCTAssertEqual(selection?.count, 8, "Shift-click retains the drag's original anchor")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: enter)
        XCTAssertTrue(openedBulkEditor, "Return opens one editor for the whole range")
        XCTAssertEqual(selection?.count, 8)
    }
#endif

    func testGridRectangleResolvesDisplayOrderAndRejectsStalePositions() {
        let selection = ResultGridSelection(anchor: .init(row: 2, column: 1), end: .init(row: 0, column: 0))
        XCTAssertEqual(selection.loadedCells(rowIndices: [8, 3, 6], visibleColumns: [4, 2]), [
            .init(row: 8, column: 4), .init(row: 8, column: 2),
            .init(row: 3, column: 4), .init(row: 3, column: 2),
            .init(row: 6, column: 4), .init(row: 6, column: 2),
        ], "Filtered and sorted rows and pinned/reordered columns map to loaded cells")
        XCTAssertTrue(selection.loadedCells(rowIndices: [8], visibleColumns: [4, 2]).isEmpty)
        XCTAssertTrue(selection.loadedCells(rowIndices: [8, 3, 6], visibleColumns: [4]).isEmpty)
    }

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

    func testResultTabsNameWhatEachStatementDid() {
        func result(_ sql: String, table: String?, rows: Int = 0, columns: Int = 1, affected: Int? = nil) -> QueryResultTable {
            var table = QueryResultTable(columns: (0..<columns).map { QueryColumn(name: "c\($0)", type: "text") },
                                         rows: Array(repeating: QueryRow(cells: Array(repeating: .text("x"), count: columns)), count: rows),
                                         executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: table, sourceQuery: sql)
            table.affectedRowCount = affected
            return table
        }
        XCTAssertEqual(ResultTabLabel.title(for: result("SELECT * FROM \"main\".\"orders\"", table: "\"main\".\"orders\""), number: 1, engine: .postgresql), "orders")
        XCTAssertEqual(ResultTabLabel.title(for: result("update customers set vip = 1", table: "customers"), number: 2, engine: .postgresql), "UPDATE customers")
        XCTAssertEqual(ResultTabLabel.title(for: result("SELECT 1", table: nil), number: 3, engine: .postgresql), "SELECT")
        XCTAssertEqual(ResultTabLabel.title(for: result("-- note\nWITH x AS (SELECT 1) SELECT * FROM x", table: "x"), number: 1, engine: .postgresql), "x",
                       "Comments are skipped")
        XCTAssertEqual(ResultTabLabel.title(for: result("", table: nil), number: 4, engine: .postgresql), L10n.format("Result %d", 4))
        XCTAssertEqual(ResultTabLabel.detail(for: result("SELECT", table: nil, rows: 3)), L10n.plural("row_count", count: 3))
        XCTAssertEqual(ResultTabLabel.detail(for: result("DELETE", table: nil, columns: 0, affected: 2)), L10n.plural("affected_count", count: 2))
        XCTAssertEqual(ResultTabLabel.shortName("`shop`.`line_items`"), "line_items")
        XCTAssertEqual(ResultTabLabel.titles(for: [result("SELECT * FROM orders", table: "orders"), result("SELECT 1", table: nil),
                                                   result("SELECT n FROM orders", table: "orders")], engine: .postgresql),
                       ["orders", "SELECT", "orders (2)"])
    }
}
