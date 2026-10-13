import AppKit
import SwiftUI

private final class EditorHostView: NSView {
    let scrollView = NSScrollView()
    let textView: NSTextView
    let gutter: QueryLineGutter?
    override var isFlipped: Bool { true }

    init(textView: NSTextView, showsLineNumbers: Bool = true) {
        self.textView = textView
        gutter = showsLineNumbers ? QueryLineGutter(textView: textView) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let margin: CGFloat = showsLineNumbers ? 40 : 0
        scrollView.frame = NSRect(x: margin, y: 0, width: bounds.width - margin, height: bounds.height)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        scrollView.documentView = textView
        if let gutter { addSubview(gutter) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func scrolled() { gutter?.needsDisplay = true }
    override func layout() {
        super.layout()
        let margin: CGFloat = gutter == nil ? 0 : 40
        scrollView.frame = NSRect(x: margin, y: 0, width: max(1, bounds.width - margin), height: bounds.height)
        gutter?.frame = NSRect(x: 0, y: 0, width: margin, height: bounds.height)
        let width = max(1, scrollView.contentSize.width)
        textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, scrollView.contentSize.height)))
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        gutter?.needsDisplay = true
    }
}

private final class QueryTextView: NSTextView {
    var allowsSQLComments = true
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.control), event.keyCode == 49 {
            complete(nil)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "/", allowsSQLComments {
            if let edit = SQLEditingService.toggleLineComments(string, selection: selectedRange()) { apply(edit) }
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "]" {
            indentSelection(removing: false)
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "[" {
            indentSelection(removing: true)
        } else { super.keyDown(with: event) }
    }
    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 { indentSelection(removing: false) }
        else { insertText("  ", replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { indentSelection(removing: true) }
    private func indentSelection(removing: Bool) {
        let source = string as NSString, selection = selectedRange()
        let range = source.lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
        let block = source.substring(with: range) as NSString
        let starts = SQLEditingService.lineStarts(in: block as String)
        var replacement = ""
        var firstDelta = 0
        for (index, start) in starts.enumerated() {
            guard start < block.length || block.length == 0 else { continue }
            let end = index + 1 < starts.count ? starts[index + 1] : block.length
            let line = block.substring(with: NSRange(location: start, length: end - start))
            let removed = removing ? (line.hasPrefix("  ") ? 2 : line.hasPrefix(" ") || line.hasPrefix("\t") ? 1 : 0) : 0
            if index == 0 { firstDelta = removing ? -removed : 2 }
            replacement += removing ? String(line.dropFirst(removed)) : "  " + line
        }
        let newText = source.replacingCharacters(in: range, with: replacement)
        let newSelection = selection.length == 0 ? NSRange(location: max(range.location, selection.location + firstDelta), length: 0) : NSRange(location: range.location, length: replacement.utf16.count)
        apply(SQLEditingService.Edit(text: newText, selection: newSelection))
    }
    override func insertNewline(_ sender: Any?) {
        let source = string as NSString, selection = selectedRange()
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        insertText("\n" + prefix.prefix(while: { $0 == " " || $0 == "\t" }), replacementRange: selection)
    }
    private func apply(_ edit: SQLEditingService.Edit) {
        let full = NSRange(location: 0, length: string.utf16.count)
        insertText(edit.text, replacementRange: full)
        setSelectedRange(edit.selection)
    }

}

struct HighlightedQueryEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int
    @Binding var selectionLength: Int
    var colorScheme: ColorScheme = .light
    var isJSON = false
    var allowsSQLComments = true
    var fitsContent = false
    var suggestions: [String] = []
    var errorRange: NSRange?
    @AppStorage("Portbase.editorFontSize") private var editorFontSize = 13.0
    @AppStorage(EditorTheme.storageKey) private var themeName = EditorTheme.portbase.rawValue
    fileprivate var palette: EditorPalette { (EditorTheme(rawValue: themeName) ?? .portbase).palette(for: colorScheme) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = QueryTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 240), textContainer: container)
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.backgroundColor = .textBackgroundColor
        view.textColor = .textColor
        view.font = .monospacedSystemFont(ofSize: TypeSize.body, weight: .regular)
        view.textContainerInset = NSSize(width: Spacing.m, height: Spacing.m)
        view.backgroundColor = palette.backgroundColor
        view.insertionPointColor = palette.caretColor
        view.usesFindPanel = true
        view.isIncrementalSearchingEnabled = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel(L10n.text(isJSON ? "JSON editor" : allowsSQLComments ? "SQL editor" : "Redis command editor"))
        let host = EditorHostView(textView: view)
        host.gutter?.palette = palette
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? EditorHostView, let view = host.textView as? QueryTextView else { return }
        context.coordinator.parent = self
        view.allowsSQLComments = allowsSQLComments && !isJSON
        view.setAccessibilityLabel(L10n.text(isJSON ? "JSON editor" : allowsSQLComments ? "SQL editor" : "Redis command editor"))
        let palette = palette
        if view.backgroundColor != palette.backgroundColor { view.backgroundColor = palette.backgroundColor }
        view.insertionPointColor = palette.caretColor
        host.gutter?.palette = palette
        context.coordinator.applying = true
        if view.string != text { view.string = text; view.undoManager?.removeAllActions() }
        let start = min(max(0, cursorOffset), text.utf16.count)
        let range = NSRange(location: start, length: min(max(0, selectionLength), text.utf16.count - start))
        if view.selectedRange() != range { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
        context.coordinator.highlight(view)
        context.coordinator.applying = false
        host.gutter?.needsDisplay = true
        host.needsLayout = true
        view.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedQueryEditor
        var applying = false
        private var lastText: String?
        private var lastScheme: ColorScheme?
        private var lastJSON = false
        private var lastError: NSRange?
        private var lastFontSize = 0.0
        private var lastPalette: EditorPalette?
        init(_ parent: HighlightedQueryEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            updateSelection(view)
            highlight(view)
            (view.enclosingScrollView?.superview as? EditorHostView)?.gutter?.needsDisplay = true
            view.enclosingScrollView?.needsLayout = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            updateSelection(view)
        }
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            let completions = parent.suggestions.filter { prefix.isEmpty || $0.localizedCaseInsensitiveContains(prefix) }
            index?.pointee = 0
            return Array(completions.prefix(30))
        }
        private func updateSelection(_ view: NSTextView) {
            parent.cursorOffset = view.selectedRange().location
            parent.selectionLength = view.selectedRange().length
        }
        func highlight(_ view: NSTextView) {
            let previousApplying = applying
            applying = true
            defer { applying = previousApplying }
            guard !view.hasMarkedText(), let storage = view.textStorage else { return }
            let palette = parent.palette
            guard lastText != view.string || lastScheme != parent.colorScheme || lastJSON != parent.isJSON || lastError != parent.errorRange || lastFontSize != parent.editorFontSize || lastPalette != palette else { return }
            lastText = view.string; lastScheme = parent.colorScheme; lastJSON = parent.isJSON; lastError = parent.errorRange; lastFontSize = parent.editorFontSize; lastPalette = palette
            let selection = view.selectedRange()
            let font = NSFont.monospacedSystemFont(ofSize: max(10, min(24, parent.editorFontSize)), weight: .regular)
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.plainColor]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            for token in parent.isJSON ? JSONSyntaxHighlighter.tokens(in: view.string) : SQLSyntaxHighlighter.tokens(in: view.string) {
                storage.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: token.range)
            }
            if let range = parent.errorRange, range.location >= 0, NSMaxRange(range) <= storage.length {
                storage.addAttributes([.backgroundColor: NSColor.systemRed.withAlphaComponent(0.15), .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            storage.endEditing()
            view.typingAttributes = base
            view.setSelectedRange(selection)
        }
    }
}

private final class QueryLineGutter: NSView {
    weak var textView: NSTextView?
    var palette: EditorPalette? { didSet { if palette != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        (palette?.gutterColor ?? NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        guard let view = textView, let manager = view.layoutManager, let container = view.textContainer else { return }
        manager.ensureLayout(for: container)
        let offset = view.enclosingScrollView?.contentView.bounds.minY ?? 0
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: TypeSize.caption, weight: .regular), .foregroundColor: palette?.gutterTextColor ?? NSColor.secondaryLabelColor]
        for (line, start) in SQLEditingService.lineStarts(in: view.string).enumerated() {
            let frame: NSRect
            if manager.numberOfGlyphs == 0 || start >= view.string.utf16.count { frame = manager.extraLineFragmentRect }
            else { frame = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: start), effectiveRange: nil) }
            let y = frame.minY + view.textContainerOrigin.y - offset + 1
            if y < -20 || y > bounds.height { continue }
            let label = String(line + 1) as NSString
            label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attributes).width - 9, y: y), withAttributes: attributes)
        }
    }
}

struct HighlightedClauseEditor: View {
    @Binding var text: String
    var colorScheme: ColorScheme = .light
    var accessibilityLabel = "SQL clause editor"
    var onFocusChanged: (Bool) -> Void = { _ in }
    @State private var cursor = 0
    @State private var selection = 0
    var body: some View {
        HighlightedQueryEditor(text: $text, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme)
            .accessibilityLabel(L10n.text(accessibilityLabel)).frame(minHeight: 60)
    }
}

struct NativeReadOnlyText: NSViewRepresentable {
    let value: String
    func makeNSView(context: Context) -> NSView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.font = .monospacedSystemFont(ofSize: TypeSize.body, weight: .regular)
        view.usesFindPanel = true
        view.textContainerInset = NSSize(width: Spacing.s, height: Spacing.s)
        view.autoresizingMask = [.width]
        return EditorHostView(textView: view, showsLineNumbers: false)
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? EditorHostView else { return }
        if host.textView.string != value { host.textView.string = value; host.needsLayout = true }
    }
}

struct ScriptActivitySheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(spacing: Spacing.l) {
            Text(url.lastPathComponent).font(.cardTitle)
            if let error { Text(error).foregroundStyle(.red) }
            Button("Save File") {
                let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
                if panel.runModal() == .OK, let target = panel.url {
                    do { try Data(contentsOf: url).write(to: target, options: .atomic); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.keyboardShortcut(.defaultAction)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(Spacing.xxl).frame(minWidth: 360)
    }
}
