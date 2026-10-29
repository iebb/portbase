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

/// Lets the completion list take arrow keys, Return, Tab, and Esc while it's open.
@MainActor protocol SQLCompletionKeyHandling: AnyObject {
    func handleCompletionCommand(_ selector: Selector) -> Bool
    func requestCompletion()
}

private final class QueryTextView: NSTextView {
    var allowsSQLComments = true
    weak var completionKeys: SQLCompletionKeyHandling?
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
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Only typed characters pair; edits with an explicit range (indenting, completions) go through as they are.
        guard !hasMarkedText(), replacementRange.location == NSNotFound,
              let typed = (string as? String) ?? (string as? NSAttributedString)?.string, typed.count == 1, let character = typed.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        switch EditorAutoPairs.action(typing: character, in: self.string, selection: selection) {
        case .insert:
            super.insertText(string, replacementRange: replacementRange)
        case .stepOver:
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        case .pair(let pair):
            super.insertText(pair, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        case .wrap(let opener, let closer):
            let selected = (self.string as NSString).substring(with: selection)
            super.insertText(opener + selected + closer, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: (selected as NSString).length))
        }
    }
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, EditorAutoPairs.deletesPair(in: string, at: selection.location) {
            insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
            return
        }
        super.deleteBackward(sender)
    }
    /// Esc, F5, and Control-Space open the completion list.
    override func complete(_ sender: Any?) {
        if let completionKeys { completionKeys.requestCompletion() } else { super.complete(sender) }
    }
    override func doCommand(by selector: Selector) {
        if completionKeys?.handleCompletionCommand(selector) == true { return }
        super.doCommand(by: selector)
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
    // Line commands, sent from the Edit menu through the responder chain to the focused editor.
    @objc func duplicateLines(_ sender: Any?) { applyRangeEdit(SQLLineEditing.duplicateLines(string, selection: selectedRange())) }
    @objc func moveLinesUp(_ sender: Any?) { applyRangeEdit(SQLLineEditing.moveLines(string, selection: selectedRange(), up: true)) }
    @objc func moveLinesDown(_ sender: Any?) { applyRangeEdit(SQLLineEditing.moveLines(string, selection: selectedRange(), up: false)) }
    @objc func toggleSQLCase(_ sender: Any?) { applyRangeEdit(SQLLineEditing.toggleCase(string, selection: selectedRange())) }
    @objc func toggleSQLComment(_ sender: Any?) {
        guard allowsSQLComments, let edit = SQLEditingService.toggleLineComments(string, selection: selectedRange()) else { return }
        apply(edit)
    }

    /// Replaces just the edited range, so Undo reverts it in one step.
    private func applyRangeEdit(_ edit: SQLLineEditing.RangeEdit?) {
        guard !hasMarkedText(), let edit else { return }
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
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
    /// Completions at the caret; when set, a list opens at the caret as you type.
    var completion: SQLCompletionResult?
    var errorRange: NSRange?
    /// The SQL engine, for marking the statement at the caret; nil marks brackets only.
    var engine: DatabaseEngine?
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
        view.font = PortbaseFonts.codeFont(TypeSize.code)
        view.textContainerInset = NSSize(width: Spacing.m, height: Spacing.m)
        view.backgroundColor = palette.backgroundColor
        view.insertionPointColor = palette.caretColor
        view.usesFindPanel = true
        view.isIncrementalSearchingEnabled = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        if completion != nil { view.completionKeys = context.coordinator }
        view.setAccessibilityLabel(L10n.text(isJSON ? "JSON editor" : allowsSQLComments ? "SQL editor" : "Redis command editor"))
        let host = EditorHostView(textView: view)
        host.gutter?.palette = palette
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? EditorHostView, let view = host.textView as? QueryTextView else { return }
        context.coordinator.parent = self
        view.completionKeys = completion == nil ? nil : context.coordinator
        view.allowsSQLComments = allowsSQLComments && !isJSON
        view.setAccessibilityLabel(L10n.text(isJSON ? "JSON editor" : allowsSQLComments ? "SQL editor" : "Redis command editor"))
        let palette = palette
        if view.backgroundColor != palette.backgroundColor { view.backgroundColor = palette.backgroundColor }
        view.insertionPointColor = palette.caretColor
        host.gutter?.palette = palette
        context.coordinator.applying = true
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
            // Setting the text clears its colors, so all of it is colored again.
            context.coordinator.lastTokens = nil
            // Text set from outside, such as Format, isn't typing, so it doesn't open the list.
            context.coordinator.endTyping()
        }
        let start = min(max(0, cursorOffset), text.utf16.count)
        let range = NSRange(location: start, length: min(max(0, selectionLength), text.utf16.count - start))
        if view.selectedRange() != range { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
        context.coordinator.highlight(view)
        context.coordinator.applying = false
        if let completion { context.coordinator.updateCompletion(completion, in: view) }
        host.gutter?.needsDisplay = true
        host.needsLayout = true
        view.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, SQLCompletionKeyHandling {
        var parent: HighlightedQueryEditor
        var applying = false
        private lazy var signaturePopup = SQLSignaturePopup()
        private lazy var popup: SQLCompletionPopup = {
            let popup = SQLCompletionPopup()
            popup.onAccept = { [weak self] item in self?.accept(item) }
            return popup
        }()
        private var completion = SQLCompletionResult.empty
        /// The last completion the editor was given, so a redraw that brings the same one again does nothing.
        private var offered: SQLCompletionResult?
        private weak var completionView: NSTextView?
        /// Set while the user is typing a word, so the list may open; moving the caret clears it.
        private var typing = false
        /// Set when the list was asked for (Esc, Control-Space), so it opens even where it wouldn't on its own.
        private var requested = false
        private var lastString = ""
        private var lastText: String?
        private var lastScheme: ColorScheme?
        private var lastJSON = false
        private var lastError: NSRange?
        private var lastFontSize = 0.0
        private var lastPalette: EditorPalette?
        /// The tokens the text is colored with now, so an edit recolors only what changed; nil recolors it all.
        var lastTokens: [SQLToken]?
        /// The text the last edit inserted, which takes its neighbor's color until it's recolored.
        private var editedRange: NSRange?
        init(_ parent: HighlightedQueryEditor) { self.parent = parent }
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Several edits before a recolor (typing into marked text) aren't tracked one by one; all of it is recolored.
            if editedRange != nil { lastTokens = nil }
            editedRange = NSRange(location: range.location, length: (replacementString as NSString?)?.length ?? 0)
            guard parent.completion != nil, !applying else { return true }
            if let replacement = replacementString, !replacement.isEmpty {
                // Typing a name, a dot, or a space after a keyword can bring up the list; pasting can't.
                typing = replacement.count <= 2 && replacement.allSatisfy { $0.isLetter || $0.isNumber || "_.$ \"`(,=".contains($0) }
                if !typing { popup.hide() }
            } else {
                typing = popup.isVisible
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            lastString = view.string
            parent.text = view.string
            updateSelection(view)
            highlight(view)
            (view.enclosingScrollView?.superview as? EditorHostView)?.gutter?.needsDisplay = true
            view.enclosingScrollView?.needsLayout = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view = notification.object as? NSTextView else { return }
            // Moving the caret without typing closes the list.
            if view.string == lastString, parent.completion != nil { typing = false; popup.hide() }
            lastString = view.string
            updateSelection(view)
            updateDecorations(view)
        }

        /// Tints the statement Run would execute and the bracket pair at the caret, as layout-only
        /// attributes that leave the text and its undo history alone.
        private var decorationTask: Task<Void, Never>?

        /// Works the marks out off the main thread, so a long script doesn't slow typing, and applies them
        /// only if the text and caret are still what they were measured on.
        func updateDecorations(_ view: NSTextView) {
            decorationTask?.cancel()
            guard !view.hasMarkedText() else { return }
            let text = view.string, selection = view.selectedRange(), engine = parent.isJSON ? nil : parent.engine
            decorationTask = Task { [weak self, weak view] in
                let marks = await Task.detached(priority: .userInitiated) {
                    SQLEditorDecorations.marks(in: text, selection: selection, engine: engine)
                }.value
                guard !Task.isCancelled, let self, let view, view.selectedRange() == selection, view.string == text else { return }
                self.applyDecorations(marks, to: view)
            }
        }

        private func applyDecorations(_ marks: SQLEditorDecorations.Marks, to view: NSTextView) {
            guard let manager = view.layoutManager else { return }
            let length = (view.string as NSString).length
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            let tint = parent.palette.caretColor
            // An error's own highlight wins over the statement tint.
            if let statement = marks.statement, parent.errorRange == nil, NSMaxRange(statement) <= length {
                manager.addTemporaryAttribute(.backgroundColor, value: tint.withAlphaComponent(0.07), forCharacterRange: statement)
            }
            for bracket in marks.brackets where NSMaxRange(bracket) <= length {
                manager.addTemporaryAttribute(.backgroundColor, value: tint.withAlphaComponent(0.28), forCharacterRange: bracket)
            }
        }
        func textDidEndEditing(_ notification: Notification) { popup.hide(); signaturePopup.hide() }

        // MARK: Completion

        /// Takes a new completion for the text, if it's for the text and caret as they are now.
        func updateCompletion(_ completion: SQLCompletionResult, in view: NSTextView) {
            completionView = view
            guard completion != offered else { return }
            offered = completion
            let caret = view.selectedRange()
            let source = view.string as NSString
            guard caret.length == 0, NSMaxRange(completion.fragmentRange) == caret.location, NSMaxRange(completion.fragmentRange) <= source.length,
                  source.substring(with: completion.fragmentRange) == completion.fragment else { return }
            self.completion = completion
            updateSignature(in: view)
            // A list holding only the word already typed has nothing to offer.
            let complete = completion.items.count == 1 && completion.items[0].insertion == completion.fragment && completion.items[0].addition == nil
            if completion.items.isEmpty || (complete && !requested) { popup.hide(); return }
            if popup.isVisible || (typing && completion.opensAutomatically) || requested {
                requested = false
                showPopup(in: view)
            }
        }

        private func showPopup(in view: NSTextView) {
            guard let window = view.window, view.window?.firstResponder === view else { return }
            let caret = view.firstRect(forCharacterRange: NSRange(location: completion.fragmentRange.location, length: 0), actualRange: nil)
            let typed = completion.fragment.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? completion.fragment
            popup.show(completion.items, typed: typed.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]")), below: caret, in: window)
        }

        /// The parameter hint above the caret while it's inside a function call.
        private func updateSignature(in view: NSTextView) {
            guard let signature = completion.signature, let window = view.window, window.firstResponder === view else { signaturePopup.hide(); return }
            let caret = view.firstRect(forCharacterRange: NSRange(location: NSMaxRange(completion.fragmentRange), length: 0), actualRange: nil)
            signaturePopup.show(signature, above: caret, in: window)
        }

        func endTyping() {
            typing = false
            popup.hide()
        }

        func requestCompletion() {
            requested = true
            if let view = completionView, !completion.items.isEmpty { requested = false; showPopup(in: view) }
        }

        func handleCompletionCommand(_ selector: Selector) -> Bool {
            guard popup.isVisible else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): popup.move(by: -1)
            case #selector(NSResponder.moveDown(_:)): popup.move(by: 1)
            case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): popup.page(by: -1)
            case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): popup.page(by: 1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let item = popup.selectedItem { accept(item) } else { popup.hide() }
            case #selector(NSResponder.cancelOperation(_:)): endTyping()
            default:
                popup.hide()
                return false
            }
            return true
        }

        /// Inserts an item as ordinary edits, so a single Undo takes it back.
        private func accept(_ item: SQLCompletionItem) {
            guard let view = completionView, let plan = SQLCompletionEngine.edits(for: item, in: view.string, result: completion) else { return }
            popup.hide()
            SQLCompletionUsage.record(item)
            view.undoManager?.beginUndoGrouping()
            for edit in plan.edits where view.shouldChangeText(in: edit.range, replacementString: edit.text) {
                view.textStorage?.replaceCharacters(in: edit.range, with: edit.text)
                view.didChangeText()
            }
            view.undoManager?.endUndoGrouping()
            view.setSelectedRange(NSRange(location: min(plan.cursor, (view.string as NSString).length), length: 0))
            completion = .empty
            // A qualifier or schema just inserted goes straight on to its columns or tables.
            typing = item.insertion.hasSuffix(".")
            requested = typing
        }
        /// Only changes are written back: each write redraws the views watching the editor.
        private func updateSelection(_ view: NSTextView) {
            let range = view.selectedRange()
            if parent.cursorOffset != range.location { parent.cursorOffset = range.location }
            if parent.selectionLength != range.length { parent.selectionLength = range.length }
        }
        func highlight(_ view: NSTextView) {
            let previousApplying = applying
            applying = true
            defer { applying = previousApplying }
            guard !view.hasMarkedText(), let storage = view.textStorage else { return }
            let palette = parent.palette
            let restyle = lastScheme != parent.colorScheme || lastJSON != parent.isJSON || lastError != parent.errorRange || lastFontSize != parent.editorFontSize || lastPalette != palette
            guard restyle || lastText != view.string else { return }
            let oldLength = (lastText as NSString?)?.length ?? 0
            lastText = view.string; lastScheme = parent.colorScheme; lastJSON = parent.isJSON; lastError = parent.errorRange; lastFontSize = parent.editorFontSize; lastPalette = palette
            let selection = view.selectedRange()
            let font = PortbaseFonts.codeFont(max(10, min(24, parent.editorFontSize)))
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.plainColor]
            let tokens = parent.isJSON ? JSONSyntaxHighlighter.tokens(in: view.string) : SQLSyntaxHighlighter.tokens(in: view.string)
            let range = restyle ? nil : lastTokens.map { SQLSyntaxHighlighter.changedRange(from: $0, to: tokens, oldLength: oldLength, newLength: storage.length) }
            var dirty = range ?? NSRange(location: 0, length: storage.length)
            if let edited = editedRange, NSMaxRange(edited) <= storage.length { dirty = NSUnionRange(dirty, edited) }
            editedRange = nil
            lastTokens = tokens
            storage.beginEditing()
            storage.setAttributes(base, range: dirty)
            for token in tokens {
                let colored = NSIntersectionRange(token.range, dirty)
                if colored.length > 0 { storage.addAttribute(.foregroundColor, value: palette.color(for: token.kind), range: colored) }
            }
            if let range = parent.errorRange, range.location >= 0, NSMaxRange(range) <= storage.length {
                storage.addAttributes([.backgroundColor: NSColor.systemRed.withAlphaComponent(0.15), .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            storage.endEditing()
            view.typingAttributes = base
            view.setSelectedRange(selection)
            updateDecorations(view)
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
        let offset = view.enclosingScrollView?.contentView.bounds.minY ?? 0
        let attributes: [NSAttributedString.Key: Any] = [.font: PortbaseFonts.codeFont(TypeSize.caption), .foregroundColor: palette?.gutterTextColor ?? NSColor.secondaryLabelColor]
        // Only the lines in view are laid out and numbered, so a long script doesn't slow each keystroke.
        let visible = NSRect(x: 0, y: offset - view.textContainerOrigin.y, width: container.size.width, height: bounds.height)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = view.string.utf16.count
        let starts = SQLEditingService.lineStarts(in: view.string)
        // The first line that begins at or before the first visible character.
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= characters.location { low = middle } else { high = middle - 1 }
        }
        for line in low..<starts.count {
            let start = starts[line]
            if start > NSMaxRange(characters) && start < length { break }
            let frame: NSRect
            if manager.numberOfGlyphs == 0 || start >= length { frame = manager.extraLineFragmentRect }
            else { frame = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: start), effectiveRange: nil) }
            let y = frame.minY + view.textContainerOrigin.y - offset + 1
            if y > bounds.height { break }
            if y < -20 { continue }
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
        view.font = PortbaseFonts.codeFont(TypeSize.code)
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
