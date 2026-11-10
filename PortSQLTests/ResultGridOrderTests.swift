import SwiftUI
import XCTest
@testable import PortSQL

final class ResultGridOrderTests: XCTestCase {
    private func table(_ rows: [[QueryCell]], columns: [String] = ["value"]) -> QueryResultTable {
        QueryResultTable(columns: columns.map { QueryColumn(name: $0, type: "text") }, rows: rows.map(QueryRow.init(cells:)),
                         executionSummary: "", generatedMutation: nil, profiles: [], sourceTableReference: nil)
    }

    func testRowOrderBelongsToTheResultItWasWorkedOutFor() throws {
        let result = table([[.integer("3")], [.integer("1")], [.integer("2")], [.null]])
        let sorted = try XCTUnwrap(LoadedRowOrder.make(of: result, filter: LoadedResultFilter(), sort: LoadedResultSort(column: 0)))
        XCTAssertEqual(Array(sorted), [1, 2, 0, 3])
        XCTAssertFalse(sorted.isAsLoaded)
        XCTAssertTrue(sorted.isOrder(of: result))

        var edited = result
        edited.rows[1].cells[0] = .integer("9")
        XCTAssertTrue(sorted.isOrder(of: edited), "An edited cell leaves every position valid")
        XCTAssertFalse(sorted.isOrder(of: table([[.integer("5")], [.integer("4")]])), "A query run again has other rows")
        var shorter = result
        shorter.rows.removeLast()
        XCTAssertFalse(sorted.isOrder(of: shorter))

        let filtered = try XCTUnwrap(LoadedRowOrder.make(of: result, filter: LoadedResultFilter(column: 0, mode: .greaterThan, text: "1"),
                                                         sort: LoadedResultSort(column: 0, descending: true)))
        XCTAssertEqual(Array(filtered), [0, 2])

        let asLoaded = LoadedRowOrder(of: result)
        XCTAssertTrue(asLoaded.isAsLoaded)
        XCTAssertEqual(Array(asLoaded), [0, 1, 2, 3])
        XCTAssertEqual(LoadedRowOrder(of: table([])).count, 0)
        let selection = ResultGridSelection(anchor: .init(row: 1, column: 0), end: .init(row: 2, column: 0))
        XCTAssertEqual(selection.loadedCells(rowIndices: sorted, visibleColumns: [0]), [.init(row: 2, column: 0), .init(row: 0, column: 0)])
        XCTAssertEqual(selection.loadedCells(rowIndices: filtered, visibleColumns: [0]), [], "A range past the shown rows edits nothing")
    }

    func testCancelledFilteringGivesNoOrder() async {
        let result = table((0..<2_000).map { [.text("row \($0)")] })
        let work = Task.detached { () -> LoadedRowOrder? in
            withUnsafeCurrentTask { $0?.cancel() }
            return LoadedRowOrder.make(of: result, filter: LoadedResultFilter(column: nil, text: "row"), sort: nil)
        }
        let order = await work.value
        XCTAssertNil(order, "A filter typed over is dropped rather than shown")
    }

    func testFilteringASCIITextAgreesWithTheLocalizedComparison() {
        let texts = ["", "Hello World", "HELLO", "hell", "naïve café", "Café HELLO", "cafe\u{301} au lait", "e\u{301}", "日本語のテキスト", "東京 Tokyo 支店",
                     "İstanbul", "STRASSE", "straße", "a_b%c", "tab\there", "Hello 🦊", "🦊 fox", "K", "\u{212A}elvin", "ﬁre", "fire"]
        let needles = ["hello", "HELLO", "e", "cafe", "café", "tokyo", "日本", "k", "fi", "ss", "i", "_b%", "\t", " ", "fox", "o w"]
        for needle in needles {
            for text in texts {
                let cell = QueryCell.text(text)
                XCTAssertEqual(LoadedResultFilter.Condition(mode: .contains, text: needle).matches(cell),
                               text.localizedCaseInsensitiveContains(needle), "\(text.debugDescription) contains \(needle.debugDescription)")
                XCTAssertEqual(LoadedResultFilter.Condition(mode: .equals, text: needle).matches(cell),
                               text.compare(needle, options: .caseInsensitive) == .orderedSame, "\(text.debugDescription) equals \(needle.debugDescription)")
            }
        }
        let needle = ASCIIFolding.lowercased("Hello")!
        XCTAssertEqual(ASCIIFolding.contains(needle, in: "oh HELLO there"), true)
        XCTAssertEqual(ASCIIFolding.contains(needle, in: "help"), false)
        XCTAssertEqual(ASCIIFolding.contains(needle, in: "日本 hello"), true, "ASCII found whole needs no second look")
        XCTAssertNil(ASCIIFolding.contains(needle, in: "日本語"), "Other text is the locale's to judge")
        XCTAssertNil(ASCIIFolding.contains(ASCIIFolding.lowercased("e")!, in: "e\u{301}"), "A letter with a combining mark isn't that letter")
        XCTAssertNil(ASCIIFolding.lowercased("café"))
        XCTAssertNil(ASCIIFolding.lowercased(""))
        XCTAssertEqual(ASCIIFolding.equals(needle, "HeLLo"), true)
        XCTAssertEqual(ASCIIFolding.equals(needle, "hello!"), false)
    }

    func testCellTextIsCutShortWhileTheValueStaysWhole() {
        XCTAssertEqual(Data([0x00, 0x0F, 0xA0, 0xFF]).hexEncoded(), "000fa0ff")
        XCTAssertEqual(Data([0x00, 0x0F, 0xA0, 0xFF]).hexEncoded(uppercase: true), "000FA0FF")
        XCTAssertEqual(QueryCell.binary(Data([0xDE, 0xAD])).displayValue, "0xdead")
        XCTAssertEqual(QueryCell.binary(Data([0xDE, 0xAD])).cellText, "0xdead")
        XCTAssertEqual(QueryCell.binary(Data()).cellText, "0x")

        let blob = QueryCell.binary(Data(repeating: 0xAB, count: 1_000_000))
        XCTAssertEqual(blob.cellText, "0x" + String(repeating: "ab", count: 256) + "…")
        XCTAssertEqual(blob.displayValue.count, 2_000_002, "Copy and export still get every byte")

        let limit = QueryCell.cellTextLimit
        XCTAssertEqual(QueryCell.text(String(repeating: "a", count: limit)).cellText.count, limit)
        XCTAssertEqual(QueryCell.text(String(repeating: "a", count: limit + 1)).cellText, String(repeating: "a", count: limit) + "…")
        XCTAssertEqual(QueryCell.json(String(repeating: "🦊", count: limit)).cellText, String(repeating: "🦊", count: limit) + "…",
                       "A cut falls between characters, never inside one")
        XCTAssertEqual(QueryCell.null.cellText, "")
        XCTAssertEqual(QueryCell.integer("42").cellText, "42")
        XCTAssertEqual(ResultGridAccessibility.rowLabel(columns: [QueryColumn(name: "body", type: "text")],
                                                        cells: [.text(String(repeating: "a", count: 5_000))]).count, "body: ".count + limit + 1)
    }

    /// A grid that stays on screen while its result is replaced, as the Mac console's does, must not look
    /// the new rows up by the positions a sort gave the old ones.
    @MainActor
    func testSortedGridTakesASmallerResult() async throws {
        let large = table((0..<400).map { [.integer(String(400 - $0))] })
        let small = table([[.integer("30")], [.integer("10")], [.integer("20")]])
        let host = GridHost(ResultGridView(result: large, fillsAvailableSpace: true))
        defer { host.close() }
        try await host.waitForGrid()
        let firstCell = try host.firstCellText()
        XCTAssertEqual(firstCell, "400")

        try host.clickFirstColumnHeader()
        try await host.wait(until: { try host.firstCellText() == "1" })

        host.show(ResultGridView(result: small, fillsAvailableSpace: true))
        try await host.wait(until: { try host.rowCount() == 3 })
        let sortedFirstCell = try host.firstCellText()
        XCTAssertEqual(sortedFirstCell, "10", "The sort carries over to rows of the same columns")
    }
}

/// A result grid in a window, with the few things a test does to it on either platform.
@MainActor
private final class GridHost {
    struct Timeout: Error {}

#if os(macOS)
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    private let host: NSHostingView<ResultGridView>

    init(_ grid: ResultGridView) {
        host = NSHostingView(rootView: grid)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func close() { window.close() }
    func show(_ grid: ResultGridView) { host.rootView = grid }
    private func layout() { host.layoutSubtreeIfNeeded() }

    private func grid() -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? ResultTableView { return table }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(host)
    }

    func rowCount() throws -> Int { try XCTUnwrap(grid()).numberOfRows }

    func firstCellText() throws -> String? {
        let table = try XCTUnwrap(grid())
        guard table.numberOfRows > 0 else { return nil }
        return (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
    }

    func clickFirstColumnHeader() throws {
        let table = try XCTUnwrap(grid())
        table.delegate?.tableView?(table, didClick: try XCTUnwrap(table.tableColumns.first))
    }
#else
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    private let host: UIHostingController<ResultGridView>

    init(_ grid: ResultGridView) {
        host = UIHostingController(rootView: grid)
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    func close() { window.isHidden = true }
    func show(_ grid: ResultGridView) { host.rootView = grid }
    private func layout() { host.view.setNeedsLayout(); host.view.layoutIfNeeded() }

    private func grid() -> UICollectionView? {
        func find(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView { return collection }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(host.view)
    }

    /// Sections are the header and then the rows.
    func rowCount() throws -> Int { try XCTUnwrap(grid()).numberOfSections - 1 }

    func firstCellText() throws -> String? {
        let collection = try XCTUnwrap(grid())
        collection.layoutIfNeeded()
        guard collection.numberOfSections > 1, let cell = collection.cellForItem(at: IndexPath(item: 1, section: 1)) else { return nil }
        return cell.contentView.subviews.lazy.compactMap { ($0 as? UILabel)?.text }.first
    }

    func clickFirstColumnHeader() throws {
        let collection = try XCTUnwrap(grid())
        collection.delegate?.collectionView?(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
    }
#endif

    func waitForGrid() async throws {
        try await wait(until: { self.grid() != nil })
    }

    /// Lets SwiftUI and the work it starts settle until the condition holds.
    func wait(until condition: () throws -> Bool) async throws {
        for _ in 0..<100 {
            layout()
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Timeout()
    }
}
