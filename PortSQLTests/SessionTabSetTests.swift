import XCTest
@testable import PortSQL

final class SessionTabSetTests: XCTestCase {
    func testStartsWithTheConsoleThatCannotClose() {
        var tabs = SessionTabSet()
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console])
        tabs.close(tabs.selectedID)
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console])
    }

    func testBrowsingTablesReplacesThePreviewTab() {
        var tabs = SessionTabSet()
        tabs.openTable("public.users")
        tabs.openTable("public.orders")
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console, .table("public.orders")])
        XCTAssertTrue(tabs.selected.isPreview)

        tabs.keep(tabs.selectedID)
        tabs.openTable("public.items")
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console, .table("public.orders"), .table("public.items")])
    }

    func testOpeningAnOpenTableFocusesItAndCanKeepIt() {
        var tabs = SessionTabSet()
        tabs.openTable("users")
        let users = tabs.selectedID
        tabs.show(.structure)
        tabs.openTable("users", keeps: true)
        XCTAssertEqual(tabs.selectedID, users)
        XCTAssertFalse(tabs.selected.isPreview)
        XCTAssertEqual(tabs.tabs.count, 3)
    }

    func testSinglePagesOpenOnceAndChatsAsOftenAsAsked() {
        var tabs = SessionTabSet()
        tabs.show(.charts)
        tabs.show(.console)
        tabs.show(.charts)
        let first = tabs.addChat()
        let second = tabs.addChat()
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console, .charts, .chat, .chat])
        XCTAssertEqual(tabs.chatIDs, [first, second])

        tabs.show(.console)
        tabs.showChat()
        XCTAssertEqual(tabs.selectedID, second)
    }

    func testShowChatStartsOneWhenThereIsNone() {
        var tabs = SessionTabSet()
        tabs.showChat()
        XCTAssertEqual(tabs.selected.kind, .chat)
        XCTAssertEqual(tabs.chatIDs.count, 1)
    }

    func testClosingSelectsTheRightNeighborThenTheLeft() {
        var tabs = SessionTabSet()
        tabs.show(.structure)
        let structure = tabs.selectedID
        tabs.show(.charts)
        let charts = tabs.selectedID
        tabs.select(structure)
        tabs.close(structure)
        XCTAssertEqual(tabs.selectedID, charts)
        tabs.close(charts)
        XCTAssertEqual(tabs.selected.kind, .console)
    }

    func testCloseOthersKeepsTheConsole() {
        var tabs = SessionTabSet()
        tabs.openTable("a", keeps: true)
        tabs.addChat()
        let chat = tabs.selectedID
        tabs.show(.structure)
        tabs.closeOthers(than: chat)
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console, .chat])
        XCTAssertEqual(tabs.selectedID, chat)
    }

    func testChangingDatabaseClosesTablesOnly() {
        var tabs = SessionTabSet()
        tabs.openTable("a", keeps: true)
        tabs.addChat()
        tabs.openTable("b")
        tabs.closeTables()
        XCTAssertEqual(tabs.tabs.map(\.kind), [.console, .chat])
        XCTAssertEqual(tabs.selected.kind, .console)

        tabs.showChat()
        tabs.openTable("c")
        tabs.showChat()
        tabs.closeTables()
        XCTAssertEqual(tabs.selected.kind, .chat)
    }
}
