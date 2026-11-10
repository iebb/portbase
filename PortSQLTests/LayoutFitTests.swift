#if canImport(UIKit) && !os(macOS)
import SwiftUI
import UIKit
import XCTest
@testable import PortSQL

/// Renders every tab at the sizes Portbase runs at: the iPhone Duo's folded and unfolded screens, an
/// iPhone and an iPad. Each render is attached to the test report, and a labeled control that lands
/// outside the screen sideways fails the test, as the Explorer's clause row did on the unfolded Duo.
/// The window's own system chrome follows the simulator's screen, so this checks the pages' content.
@MainActor
final class LayoutFitTests: XCTestCase {
    private struct Screen {
        let name: String
        let size: CGSize
    }

    private let screens = [
        Screen(name: "duo-outer", size: CGSize(width: 466, height: 678)),
        Screen(name: "duo-inner", size: CGSize(width: 669, height: 951)),
        Screen(name: "duo-inner-landscape", size: CGSize(width: 951, height: 669)),
        Screen(name: "iphone", size: CGSize(width: 402, height: 874)),
        Screen(name: "ipad", size: CGSize(width: 1032, height: 1376)),
    ]
    private let tabs = ["home", "explorer", "console", "charts", "servers"]

    func testEveryTabFitsEveryScreenWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutFit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await SQLiteFileStore.shared.create(name: "Layout fixture")
        defer { try? SQLiteFileStore.shared.remove(fileName: file.fileName) }
        var profile = ConnectionProfile(name: "Northstar Demo", engine: .sqlite, host: "", port: 0, username: "", password: "", defaultDatabase: "main")
        profile.sqliteFileName = file.fileName
        for statement in [
            "CREATE TABLE customers(customer_id INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT)",
            "CREATE TABLE orders(order_id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(customer_id), placed_at DATETIME, status TEXT, total NUMERIC)",
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 40) INSERT INTO customers SELECT x, 'Customer ' || x, CASE x % 3 WHEN 0 THEN 'Japan' WHEN 1 THEN 'Norway' ELSE 'Canada' END FROM n",
            "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 300) INSERT INTO orders SELECT x, 1 + x % 40, datetime('2026-01-01', '+' || x || ' hours'), CASE x % 4 WHEN 0 THEN 'refunded' ELSE 'paid' END, x * 1.25 FROM n",
        ] {
            _ = try await SQLiteDatabaseClient.execute(query: statement, profile: profile, policy: .mutation())
        }

        let bookmarks = BookmarkStore(directory: directory.appendingPathComponent("bookmarks"), cloudSyncEnabled: false)
        XCTAssertTrue(bookmarks.upsert(profile))
        let library = WorkspaceLibraryStore(directory: directory.appendingPathComponent("library"), cloudSyncEnabled: false)
        let consoles = ConsoleStore(directory: directory.appendingPathComponent("consoles"))
        consoles.configure(bookmarks: bookmarks, library: library)
        let workspace = consoles.active.workspace
        workspace.selectBookmark(profile.id)
        workspace.queryText = "SELECT o.order_id, c.name, c.country, o.placed_at, o.status, o.total FROM orders o JOIN customers c USING (customer_id) ORDER BY o.order_id"
        workspace.runQuery()
        for _ in 0..<200 where workspace.isRunning || workspace.isLoadingSchema { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(workspace.result.rows.isEmpty, workspace.errorMessage ?? "The fixture query returned nothing")

        var failures: [String] = []
        for screen in screens {
            for tab in tabs {
                let root = RootView(initialTab: tab)
                    .environmentObject(bookmarks)
                    .environmentObject(library)
                    .environmentObject(workspace)
                    .environmentObject(workspace.editor)
                    .environmentObject(consoles)
                let window = UIWindow(frame: CGRect(origin: .zero, size: screen.size))
                let host = UIHostingController(rootView: root)
                window.rootViewController = host
                window.makeKeyAndVisible()
                // Let SwiftUI settle: the first passes lay out navigation, the later ones its contents.
                for _ in 0..<6 {
                    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                let image = UIGraphicsImageRenderer(size: screen.size).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: screen.size), afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(screen.name)-\(tab)"
                attachment.lifetime = .keepAlways
                add(attachment)
                for element in Self.overflowing(in: host.view, width: screen.size.width) {
                    failures.append("\(screen.name) \(tab): \(element)")
                }
                window.isHidden = true
            }
        }
        XCTAssertTrue(failures.isEmpty, "Controls outside the screen:\n" + failures.joined(separator: "\n"))
        XCTAssertNil(library.storageError); XCTAssertNil(consoles.storageError)
    }

    /// The check itself finds a control pushed past the edge, so a pass means the pages fit.
    func testOverflowCheckFindsAControlPastTheEdge() async throws {
        // One label well inside the screen, and one placed so it runs past the right edge.
        let wide = ZStack(alignment: .topLeading) {
            Button("Inside") {}.offset(x: 20, y: 20)
            Button("Past the edge") {}.fixedSize().offset(x: 350, y: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let host = UIHostingController(rootView: wide)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<4 { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let found = Self.overflowing(in: host.view, width: 400)
        XCTAssertTrue(found.contains { $0.contains("Past the edge") }, "\(found)")
        XCTAssertFalse(found.contains { $0.contains("Inside") }, "\(found)")
        window.isHidden = true
    }

    /// Labeled buttons and text whose frame starts left of the screen or runs past its right edge, outside
    /// anything that scrolls sideways (a result grid or a row of page tabs scrolls by design).
    private static func overflowing(in view: UIView, width: CGFloat) -> [String] {
        var found: [String] = []
        func visit(_ element: NSObject, insideHorizontalScroll: Bool, depth: Int) {
            guard depth < 40 else { return }
            var scrolls = insideHorizontalScroll
            if let scroll = element as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { scrolls = true }
            if !scrolls, element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty,
               element.accessibilityTraits.contains(.button) || element.accessibilityTraits.contains(.staticText) {
                let frame = element.accessibilityFrame
                if frame.width > 0, frame.height > 0, frame.minY < 10_000, frame.minX < -1 || frame.maxX > width + 1 {
                    found.append("\"\(label.prefix(40))\" at x \(Int(frame.minX))–\(Int(frame.maxX))")
                }
            }
            let children: [NSObject]
            if let elements = element.accessibilityElements as? [NSObject], !elements.isEmpty { children = elements }
            else if let view = element as? UIView { children = view.subviews }
            else {
                let count = element.accessibilityElementCount()
                children = count > 0 && count != NSNotFound ? (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject } : []
            }
            for child in children { visit(child, insideHorizontalScroll: scrolls, depth: depth + 1) }
        }
        visit(view, insideHorizontalScroll: false, depth: 0)
        return found
    }
}
#endif
