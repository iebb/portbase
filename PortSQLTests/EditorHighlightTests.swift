import SwiftUI
import XCTest
@testable import PortSQL

final class EditorHighlightTests: XCTestCase {
    /// Each UTF-16 unit's token kind, as one letter: Keyword, String, Number, Comment, Identifier,
    /// sYmbol, or a dot for none.
    private func kinds(_ text: String) -> String {
        var kinds = [Character](repeating: ".", count: (text as NSString).length)
        for token in SQLSyntaxHighlighter.tokens(in: text) {
            let letter: Character = switch token.kind {
            case .keyword: "K"
            case .stringLiteral: "S"
            case .numberLiteral: "N"
            case .comment: "C"
            case .identifier: "I"
            case .symbol: "Y"
            }
            for index in token.range.location..<NSMaxRange(token.range) { kinds[index] = letter }
        }
        return String(kinds)
    }

    func testTokensCoverKeywordsLiteralsCommentsAndNames() {
        XCTAssertEqual(kinds("SELECT a_1, 'it''s' FROM t -- x"),
                             "KKKKKK.IIIY.SSSSSSS.KKKK.I.CCCC")
        XCTAssertEqual(kinds("x=1.5/*c*/+`k`"),
                             "IYNNNCCCCCYSSS")
        XCTAssertEqual(kinds(#"'a\'b' "q""#), "SSSSSS.SSS")
        XCTAssertEqual(kinds("wHeRe where_ $1 _id a$b"), "KKKKK.IIIIII.YN.III.III", "Keywords match in any case, as whole words")
        XCTAssertEqual(kinds("current_timestamp auto_incrementx"), "KKKKKKKKKKKKKKKKK.IIIIIIIIIIIIIII")
        XCTAssertEqual(kinds("'open"), "SSSSS")
        XCTAssertEqual(kinds("/* open"), "CCCCCCC")
        XCTAssertEqual(kinds("a - -b"), "I.Y.YI")
        XCTAssertEqual(kinds(""), "")
    }

    func testLineCommentsEndAtWindowsLineEndings() {
        XCTAssertEqual(kinds("SELECT 1 -- c\r\nFROM t\r\n-- d\rx"),
                             "KKKKKK.N.CCCC..KKKK.I..CCCC.I", "A comment ends with its line, whichever way the line ends")
    }

    func testTokensCountUnicodeInUTF16() {
        // An accent, a skin tone or a joiner belongs to the character before it.
        XCTAssertEqual(kinds("sélect e\u{301}x 名前"), "IIIIII.III.II")
        XCTAssertEqual(kinds("🦊 👩🏽‍💻 x"), "YY.YYYYYYY.I")
        XCTAssertEqual(kinds("٣٤ + Ⅳ ½"), "NN.Y.N.N")
        XCTAssertEqual(kinds("'👩🏽‍💻日本語', 42;"), "SSSSSSSSSSSSY.NNY")
        XCTAssertEqual(kinds("a\u{3000}b\u{A0}c"), "I.I.I", "Other spaces separate words too")
        let lone = String(decoding: [0x61, 0xD83E, 0x62] as [UInt16], as: UTF16.self)
        XCTAssertEqual(SQLSyntaxHighlighter.tokens(in: lone).count, 3, "Half a surrogate pair is a symbol, not a crash")
    }

    func testRangesFollowEdits() {
        func moved(_ range: NSRange, _ edited: NSRange, _ delta: Int) -> NSRange {
            SQLSyntaxHighlighter.range(range, afterEditing: edited, changeInLength: delta)
        }
        let mark = NSRange(location: 10, length: 5)
        XCTAssertEqual(moved(mark, NSRange(location: 20, length: 3), 3), mark, "Text typed after it")
        XCTAssertEqual(moved(mark, NSRange(location: 2, length: 3), 3), NSRange(location: 13, length: 5), "Text typed before it")
        XCTAssertEqual(moved(mark, NSRange(location: 2, length: 0), -4), NSRange(location: 6, length: 5), "Text deleted before it")
        XCTAssertEqual(moved(mark, NSRange(location: 12, length: 2), 2), NSRange(location: 10, length: 7), "Text typed inside it")
        XCTAssertEqual(moved(mark, NSRange(location: 15, length: 1), 1), NSRange(location: 10, length: 6), "Text typed at its end looks like it")
        XCTAssertEqual(moved(mark, NSRange(location: 8, length: 0), -4), NSRange(location: 8, length: 3), "Its start deleted")
        XCTAssertEqual(moved(mark, NSRange(location: 5, length: 1), -19), NSRange(location: 5, length: 1), "All of it replaced")
        XCTAssertEqual(moved(mark, NSRange(location: 0, length: 0), -30), NSRange(location: 0, length: 0), "All of it deleted")
    }

#if canImport(UIKit)
    private struct Editor: View {
        @State var text: String
        @State private var cursor = 0
        @State private var selection = 0
        var body: some View {
            HighlightedQueryEditor(text: $text, cursorOffset: $cursor, selectionLength: $selection, engine: .postgresql)
        }
    }

    /// Typing recolors only what it changed, and the editor still shows what coloring all of it would.
    @MainActor
    func testTypingRecolorsOnlyWhatChanged() async throws {
        let lines = (0..<40).map { "SELECT id, name FROM users WHERE id = \($0) AND note = 'n\($0)'; -- row \($0)" }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let host = UIHostingController(rootView: Editor(text: lines.joined(separator: "\n")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func find(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        for _ in 0..<50 where find(host.view) == nil { host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let textView = try XCTUnwrap(find(host.view))
        let storage = textView.textStorage
        let palette = EditorTheme.current.palette(for: .light)

        /// The first place the editor's colors differ from a fresh coloring of its text.
        func firstWrongColor() -> String? {
            var expected = [UIColor](repeating: palette.plainColor, count: storage.length)
            for token in SQLSyntaxHighlighter.tokens(in: storage.string) {
                for index in token.range.location..<NSMaxRange(token.range) { expected[index] = palette.color(for: token.kind) }
            }
            for index in 0..<storage.length where storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor != expected[index] {
                return "\(index): " + (storage.string as NSString).substring(with: NSRange(location: max(0, index - 10), length: min(20, storage.length - max(0, index - 10))))
            }
            return nil
        }
        /// How the tinted text differs from the statement and brackets at the caret, as when a tint stays
        /// where an earlier mark was before the text moved.
        func wrongMarks() -> String? {
            let marks = SQLEditorDecorations.marks(in: storage.string, selection: textView.selectedRange, engine: .postgresql)
            var expected = IndexSet()
            for range in [marks.statement].compactMap({ $0 }) + marks.brackets { expected.insert(integersIn: range.location..<NSMaxRange(range)) }
            var tinted = IndexSet()
            storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if value != nil { tinted.insert(integersIn: range.location..<NSMaxRange(range)) }
            }
            return tinted == expected ? nil : "tinted \(tinted.rangeView.map { $0 }), not \(expected.rangeView.map { $0 }), with the caret at \(textView.selectedRange)"
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
        try await settle()
        XCTAssertNil(firstWrongColor())
        XCTAssertNil(wrongMarks())

        // A mark far from the edits: styling everything again would clear it, recoloring a part doesn't.
        let marker = NSAttributedString.Key("PortbaseTests.marker")
        let far = NSRange(location: storage.length - 30, length: 10)
        storage.addAttribute(marker, value: true, range: far)
        func markerSurvives() -> Bool {
            var range = NSRange()
            let last = storage.length - 25
            return storage.attribute(marker, at: last, effectiveRange: &range) != nil
        }

        let sameShape = (storage.string as NSString).range(of: "= 0")
        let edits: [(location: Int, length: Int, text: String)] = [
            // The same tokens as before, so only the edit itself says the new text needs its colors.
            (sameShape.location, sameShape.length, "= 5"),
            (7, 0, "x"),            // inside a name
            (0, 1, "s"),            // a keyword's first letter, still a keyword
            (0, 6, "selec"),        // no longer one
            (40, 0, "'"),           // opens a string that runs on over the lines below
            (40, 1, ""),            // and closes it again
            (100, 0, "/* "),        // a comment to the end
            (100, 3, ""),
            (20, 0, "\n  AND 1 = 1\n"),
            (5, 30, ""),
            (60, 0, " "),
        ]
        for edit in edits {
            textView.selectedRange = NSRange(location: edit.location, length: edit.length)
            if edit.text.isEmpty { textView.deleteBackward() } else { textView.insertText(edit.text) }
            try await settle()
            XCTAssertNil(firstWrongColor(), "After putting \(edit.text.debugDescription) at \(edit.location)")
            XCTAssertNil(wrongMarks(), "After putting \(edit.text.debugDescription) at \(edit.location)")
        }
        XCTAssertTrue(markerSurvives(), "The lines an edit didn't touch were left as they were")

        // Two edits before the editor recolors are both covered.
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertText("'")
        textView.selectedRange = NSRange(location: 200, length: 0)
        textView.insertText("'")
        try await settle()
        XCTAssertNil(firstWrongColor())
        XCTAssertNil(wrongMarks())
    }
#endif
}
