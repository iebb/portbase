#if canImport(UIKit)
import SwiftUI
import UIKit

private final class QueryTextView: UITextView {
    var allowsSQLComments = true
    var showsLineNumbers = true
    /// Accepts a completion from the keyboard bar, or from Tab on a hardware keyboard.
    var onAcceptCompletion: ((SQLCompletionItem) -> Void)?
    private(set) var completionItems: [SQLCompletionItem] = []
    private var completionSignature: SQLSignatureHint?
    private var editingToolbar: UIToolbar?
    private var fullToolbarItems: [UIBarButtonItem] = []
    private var compactToolbarItems: [UIBarButtonItem] = []
    private let suggestionScroll = UIScrollView()
    private let suggestionStack = UIStackView()
    /// Glass behind the suggestions, as the system draws behind its own bar, so the page doesn't show through.
    private lazy var suggestionBackground: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) { effect = UIGlassEffect() } else { effect = UIBlurEffect(style: .systemThickMaterial) }
        let view = UIVisualEffectView(effect: effect)
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()
    var palette: EditorPalette? {
        didSet { if palette != oldValue { gutter.backgroundColor = palette?.gutterColor ?? .secondarySystemBackground; gutter.setNeedsDisplay() } }
    }
    private lazy var gutter = QueryLineNumberGutter(textView: self)
    private(set) var lineStarts = [0]
    private var numberedText = ""

    override func layoutSubviews() {
        super.layoutSubviews()
        if gutter.superview == nil { addSubview(gutter) }
        gutter.isHidden = !showsLineNumbers
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: Sizes.editorGutter, height: bounds.height)
        refreshLineNumbers()
        bringSubviewToFront(gutter)
    }

    func refreshLineNumbers() {
        if numberedText != text {
            numberedText = text ?? ""
            lineStarts = SQLEditingService.lineStarts(in: numberedText)
        }
        gutter.setNeedsDisplay()
    }

    func installEditingToolbar() {
        let toolbar = UIToolbar()
        toolbar.frame.size.height = 44
        func item(_ title: String, _ symbol: String, _ action: Selector) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
            item.accessibilityLabel = L10n.text(title)
            item.width = 44
            return item
        }
        var actions = [
            UIAction(title: L10n.text("Indent"), image: UIImage(systemName: "increase.indent")) { [weak self] _ in self?.indent() },
            UIAction(title: L10n.text("Outdent"), image: UIImage(systemName: "decrease.indent")) { [weak self] _ in self?.outdent() }
        ]
        if allowsSQLComments {
            actions.append(UIAction(title: L10n.text("Toggle SQL Comment"), image: UIImage(systemName: "text.bubble")) { [weak self] _ in self?.toggleComment() })
        }
        actions += [
            UIAction(title: L10n.text("Duplicate Line"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateLines() },
            UIAction(title: L10n.text("Move Line Up"), image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in self?.moveLinesUp() },
            UIAction(title: L10n.text("Move Line Down"), image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in self?.moveLinesDown() },
            UIAction(title: L10n.text("Toggle Case"), image: UIImage(systemName: "textformat")) { [weak self] _ in self?.toggleCase() },
        ]
        let editingTools = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: actions))
        editingTools.accessibilityLabel = L10n.text("Editing Tools")
        editingTools.width = 44
        let hide = item("Hide Keyboard", "keyboard.chevron.compact.down", #selector(hideKeyboard))
        fullToolbarItems = [
            item("Undo", "arrow.uturn.backward", #selector(undoEdit)),
            item("Redo", "arrow.uturn.forward", #selector(redoEdit)),
            item("Find and Replace", "magnifyingglass", #selector(findText)),
            item("Go to Line", "list.number", #selector(goToLine)),
            editingTools,
            UIBarButtonItem(systemItem: .flexibleSpace),
            hide
        ]
        // While suggestions show, every tool is a menu item beside Hide Keyboard.
        let allTools = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: L10n.text("Undo"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.undoEdit() },
            UIAction(title: L10n.text("Redo"), image: UIImage(systemName: "arrow.uturn.forward")) { [weak self] _ in self?.redoEdit() },
            UIAction(title: L10n.text("Find and Replace"), image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.findText() },
            UIAction(title: L10n.text("Go to Line"), image: UIImage(systemName: "list.number")) { [weak self] _ in self?.goToLine() },
        ] + actions))
        allTools.accessibilityLabel = L10n.text("Editing Tools")
        allTools.width = 44
        compactToolbarItems = [UIBarButtonItem(systemItem: .flexibleSpace), allTools, hide]
        toolbar.items = completionItems.isEmpty ? fullToolbarItems : compactToolbarItems
        editingToolbar = toolbar

        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        suggestionBackground.translatesAutoresizingMaskIntoConstraints = false
        suggestionBackground.isHidden = completionItems.isEmpty
        suggestionScroll.translatesAutoresizingMaskIntoConstraints = false
        suggestionScroll.showsHorizontalScrollIndicator = false
        suggestionScroll.contentInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        suggestionStack.axis = .horizontal
        suggestionStack.spacing = 6
        suggestionStack.alignment = .center
        suggestionStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionScroll.addSubview(suggestionStack)
        suggestionBackground.contentView.addSubview(suggestionScroll)
        container.addSubview(suggestionBackground)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 52),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            suggestionBackground.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            suggestionBackground.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -136),
            suggestionBackground.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            suggestionBackground.heightAnchor.constraint(equalToConstant: 44),
            suggestionScroll.leadingAnchor.constraint(equalTo: suggestionBackground.contentView.leadingAnchor),
            suggestionScroll.trailingAnchor.constraint(equalTo: suggestionBackground.contentView.trailingAnchor),
            suggestionScroll.topAnchor.constraint(equalTo: suggestionBackground.contentView.topAnchor),
            suggestionScroll.bottomAnchor.constraint(equalTo: suggestionBackground.contentView.bottomAnchor),
            suggestionStack.leadingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.leadingAnchor),
            suggestionStack.trailingAnchor.constraint(equalTo: suggestionScroll.contentLayoutGuide.trailingAnchor),
            suggestionStack.centerYAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.centerYAnchor),
            suggestionStack.heightAnchor.constraint(equalTo: suggestionScroll.frameLayoutGuide.heightAnchor),
        ])
        inputAccessoryView = container
    }

    /// Shows completions in the keyboard bar, led by the parameter hint inside a function call, or the
    /// editing tools when there's neither.
    func setCompletions(_ items: [SQLCompletionItem], signature: SQLSignatureHint? = nil) {
        let shown = Array(items.prefix(12))
        guard shown.map(\.id) != completionItems.map(\.id) || signature != completionSignature else { return }
        completionItems = shown
        completionSignature = signature
        suggestionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let signature { suggestionStack.addArrangedSubview(signatureLabel(signature)) }
        for item in shown { suggestionStack.addArrangedSubview(completionButton(item)) }
        let empty = shown.isEmpty && signature == nil
        suggestionBackground.isHidden = empty
        suggestionScroll.contentOffset = CGPoint(x: -suggestionScroll.contentInset.left, y: 0)
        editingToolbar?.setItems(empty ? fullToolbarItems : compactToolbarItems, animated: false)
    }

    private func signatureLabel(_ signature: SQLSignatureHint) -> UIView {
        let text = NSMutableAttributedString()
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        text.append(NSAttributedString(string: signature.name + "(", attributes: plain))
        for (index, parameter) in signature.parameters.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: ", ", attributes: plain)) }
            text.append(NSAttributedString(string: parameter, attributes: index == signature.argument
                ? [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor(PortSQLPalette.accent)] : plain))
        }
        text.append(NSAttributedString(string: ")", attributes: plain))
        let label = UILabel()
        label.attributedText = text
        label.accessibilityLabel = L10n.format("Parameter %@", signature.parameters[signature.argument])
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 36),
        ])
        return container
    }

    private func completionButton(_ item: SQLCompletionItem) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.cornerStyle = .capsule
        configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        configuration.image = UIImage(systemName: item.kind.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        configuration.imagePadding = 5
        let tint = UIColor(item.kind.tint)
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in tint }
        var title = AttributedString(item.label)
        title.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        title.foregroundColor = UIColor.label
        if let detail = item.detail, !detail.isEmpty {
            var suffix = AttributedString("  " + detail)
            suffix.font = UIFont.systemFont(ofSize: 11)
            suffix.foregroundColor = UIColor.secondaryLabel
            title += suffix
        }
        configuration.attributedTitle = title
        configuration.titleLineBreakMode = .byTruncatingMiddle
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.accessibilityLabel = L10n.format("Insert %@", item.label)
        button.accessibilityValue = [item.kind.title, item.detail].compactMap { $0 }.joined(separator: ", ")
        button.addAction(UIAction { [weak self] _ in self?.onAcceptCompletion?(item) }, for: .primaryActionTriggered)
        return button
    }

    override func insertText(_ text: String) {
        guard markedTextRange == nil else { super.insertText(text); return }
        if text == "\t" {
            // Tab on a hardware keyboard takes the first suggestion, as in desktop editors.
            if let first = completionItems.first, let onAcceptCompletion { onAcceptCompletion(first); return }
            super.insertText("  "); return
        }
        if text == "\n" {
            let source = (self.text ?? "") as NSString
            let range = source.lineRange(for: NSRange(location: selectedRange.location, length: 0))
            let prefix = source.substring(with: NSRange(location: range.location, length: selectedRange.location - range.location))
            super.insertText("\n" + prefix.prefix(while: { $0 == " " || $0 == "\t" }))
        } else if text.count == 1, let character = text.first {
            let selection = selectedRange
            switch EditorAutoPairs.action(typing: character, in: self.text ?? "", selection: selection) {
            case .insert:
                super.insertText(text)
            case .stepOver:
                selectedRange = NSRange(location: selection.location + 1, length: 0)
                delegate?.textViewDidChangeSelection?(self)
            case .pair(let pair):
                super.insertText(pair)
                selectedRange = NSRange(location: selection.location + 1, length: 0)
                delegate?.textViewDidChangeSelection?(self)
            case .wrap(let opener, let closer):
                guard let range = selectedTextRange else { super.insertText(text); return }
                let selected = ((self.text ?? "") as NSString).substring(with: selection)
                replace(range, withText: opener + selected + closer)
                selectedRange = NSRange(location: selection.location + 1, length: (selected as NSString).length)
                delegate?.textViewDidChangeSelection?(self)
            }
        } else { super.insertText(text) }
    }

    override func deleteBackward() {
        let selection = selectedRange
        if markedTextRange == nil, selection.length == 0, EditorAutoPairs.deletesPair(in: text ?? "", at: selection.location),
           let start = position(from: beginningOfDocument, offset: selection.location - 1),
           let end = position(from: start, offset: 2), let range = textRange(from: start, to: end) {
            replace(range, withText: "")
            return
        }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(title: L10n.text("Indent"), action: #selector(indent), input: "]", modifierFlags: .command),
            UIKeyCommand(title: L10n.text("Outdent"), action: #selector(outdent), input: "[", modifierFlags: .command),
            UIKeyCommand(title: L10n.text("Go to Line"), action: #selector(goToLine), input: "l", modifierFlags: .command),
            UIKeyCommand(title: L10n.text("Duplicate Line"), action: #selector(duplicateLines), input: "d", modifierFlags: .command),
            UIKeyCommand(title: L10n.text("Move Line Up"), action: #selector(moveLinesUp), input: "[", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: L10n.text("Move Line Down"), action: #selector(moveLinesDown), input: "]", modifierFlags: [.command, .alternate]),
            UIKeyCommand(title: L10n.text("Toggle Case"), action: #selector(toggleCase), input: "u", modifierFlags: [.command, .shift])
        ] + (allowsSQLComments ? [UIKeyCommand(title: L10n.text("Toggle SQL Comment"), action: #selector(toggleComment), input: "/", modifierFlags: .command)] : [])
    }

    @objc private func undoEdit() { undoManager?.undo() }
    @objc private func redoEdit() { undoManager?.redo() }
    @objc private func findText() { findInteraction?.presentFindNavigator(showingReplace: true) }
    @objc private func hideKeyboard() { resignFirstResponder() }
    @objc private func indent() { changeIndent(removing: false) }
    @objc private func outdent() { changeIndent(removing: true) }
    @objc private func toggleComment() {
        guard allowsSQLComments, markedTextRange == nil,
              let edit = SQLEditingService.toggleLineComments(text ?? "", selection: selectedRange),
              let range = textRange(from: beginningOfDocument, to: endOfDocument) else { return }
        replace(range, withText: edit.text)
        selectedRange = edit.selection
    }

    @objc private func duplicateLines() { applyLineEdit(SQLLineEditing.duplicateLines(text ?? "", selection: selectedRange)) }
    @objc private func moveLinesUp() { applyLineEdit(SQLLineEditing.moveLines(text ?? "", selection: selectedRange, up: true)) }
    @objc private func moveLinesDown() { applyLineEdit(SQLLineEditing.moveLines(text ?? "", selection: selectedRange, up: false)) }
    @objc private func toggleCase() { applyLineEdit(SQLLineEditing.toggleCase(text ?? "", selection: selectedRange)) }

    /// Replaces just the edited range, so Undo reverts it in one step.
    private func applyLineEdit(_ edit: SQLLineEditing.RangeEdit?) {
        guard markedTextRange == nil, let edit,
              let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length), let range = textRange(from: start, to: end) else { return }
        replace(range, withText: edit.replacement)
        selectedRange = edit.selection
        scrollRangeToVisible(edit.selection)
        delegate?.textViewDidChangeSelection?(self)
    }

    @objc private func goToLine() {
        guard markedTextRange == nil else { return }
        var responder: UIResponder? = self
        while responder != nil && !(responder is UIViewController) { responder = responder?.next }
        guard let controller = responder as? UIViewController else { return }
        refreshLineNumbers()
        let alert = UIAlertController(title: L10n.text("Go to Line"), message: L10n.format("Line 1–%d", lineStarts.count), preferredStyle: .alert)
        alert.addTextField { field in field.keyboardType = .numberPad; field.placeholder = L10n.text("Line number") }
        alert.addAction(UIAlertAction(title: L10n.text("Cancel"), style: .cancel))
        let go = UIAlertAction(title: L10n.text("Go"), style: .default) { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text, let line = Int(value),
                  self.lineStarts.indices.contains(line - 1) else { return }
            self.becomeFirstResponder()
            self.selectedRange = NSRange(location: self.lineStarts[line - 1], length: 0)
            self.scrollRangeToVisible(self.selectedRange)
            self.delegate?.textViewDidChangeSelection?(self)
        }
        alert.addAction(go)
        go.isEnabled = false
        alert.textFields?.first?.addAction(UIAction { [weak go, weak alert, weak self] _ in
            guard let line = Int(alert?.textFields?.first?.text ?? ""), let self else { go?.isEnabled = false; return }
            go?.isEnabled = self.lineStarts.indices.contains(line - 1)
        }, for: .editingChanged)
        controller.present(alert, animated: true)
    }

    private func changeIndent(removing: Bool) {
        guard markedTextRange == nil else { return }
        if selectedRange.length == 0 && !removing { insertText("  "); return }
        let source = (text ?? "") as NSString
        var selection = selectedRange
        // A selection ending at the next line's start does not include that line.
        if selection.length > 0, source.substring(with: NSRange(location: NSMaxRange(selection) - 1, length: 1)) == "\n" {
            selection.length -= 1
        }
        let range = source.lineRange(for: selection)
        let original = source.substring(with: range)
        var lines = original.components(separatedBy: "\n")
        for index in lines.indices where index != lines.count - 1 || !lines[index].isEmpty {
            if removing {
                if lines[index].hasPrefix("\t") { lines[index].removeFirst() }
                else { lines[index].removeFirst(lines[index].prefix(2).prefix(while: { $0 == " " }).count) }
            } else { lines[index] = "  " + lines[index] }
        }
        let replacement = lines.joined(separator: "\n")
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: replacement)
        selectedRange = NSRange(location: range.location, length: replacement.utf16.count)
    }
}

private final class QueryLineNumberGutter: UIView {
    private weak var textView: QueryTextView?
    init(textView: QueryTextView) {
        self.textView = textView
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .secondarySystemBackground
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let font = PortbaseFonts.codeFont(textView.font?.pointSize ?? TypeSize.code)
        let manager = textView.layoutManager
        let container = textView.textContainer
        let visible = CGRect(x: 0, y: textView.contentOffset.y - textView.textContainerInset.top, width: textView.bounds.width, height: textView.bounds.height)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for (index, offset) in textView.lineStarts.enumerated() where offset >= characters.location && offset <= NSMaxRange(characters) {
            let y: CGFloat
            if offset == textView.textStorage.length {
                y = manager.extraLineFragmentRect.minY
            } else {
                let glyph = manager.glyphIndexForCharacter(at: offset)
                y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            let value = String(index + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textView.palette?.gutterTextColor ?? UIColor.secondaryLabel]
            let width = value.size(withAttributes: attributes).width
            value.draw(at: CGPoint(x: max(2, bounds.width - width - 8), y: y + textView.textContainerInset.top - textView.contentOffset.y), withAttributes: attributes)
        }
    }
}

enum SQLEditorTypography {
    static func queryFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: PortbaseFonts.codeFont(TypeSize.code + 1),
            compatibleWith: traits
        )
    }

    static func clauseFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: PortbaseFonts.codeFont(TypeSize.code),
            compatibleWith: traits
        )
    }
}

struct HighlightedQueryEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int
    @Binding var selectionLength: Int
    var colorScheme: ColorScheme = .light
    var isJSON = false
    var allowsSQLComments = true
    var fitsContent = false
    /// Completions at the caret, shown in the keyboard bar.
    var completion: SQLCompletionResult?
    var errorRange: NSRange?
    @AppStorage(EditorTheme.storageKey) private var themeName = EditorTheme.portbase.rawValue

    private var palette: EditorPalette { (EditorTheme(rawValue: themeName) ?? .portbase).palette(for: colorScheme) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, cursorOffset: $cursorOffset, selectionLength: $selectionLength, colorScheme: colorScheme, isJSON: isJSON)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = QueryTextView()
        textView.allowsSQLComments = allowsSQLComments && !isJSON
        textView.showsLineNumbers = !fitsContent
        textView.isFindInteractionEnabled = true
        textView.installEditingToolbar()
        textView.delegate = context.coordinator
        let coordinator = context.coordinator
        textView.onAcceptCompletion = { [weak coordinator, weak textView] item in
            guard let coordinator, let textView else { return }
            coordinator.accept(item, in: textView)
        }
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        // SQL isn't prose: no spelling or word predictions competing with the completions bar.
        textView.spellCheckingType = .no
        textView.inlinePredictionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.font = Self.font
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: Spacing.l, left: fitsContent ? Spacing.l : Sizes.editorGutter + Spacing.s, bottom: Spacing.l, right: Spacing.l)
        textView.textContainer.lineFragmentPadding = 0
        context.coordinator.palette = palette
        textView.palette = palette
        textView.tintColor = palette.caretColor
        textView.keyboardAppearance = palette.isDark ? .dark : .light
        textView.accessibilityLabel = L10n.text(isJSON ? "JSON Editor" : "SQL query editor")
        textView.accessibilityHint = isJSON ? L10n.text("Enter a MongoDB Extended JSON command") : L10n.text("Enter the SQL statement to run against the selected database")
        context.coordinator.applyHighlight(to: textView, text: text)
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard fitsContent, let width = proposal.width, width > 0 else { return nil }
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(220, max(64, height)))
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.updateBindings(text: $text, cursorOffset: $cursorOffset, selectionLength: $selectionLength)
        context.coordinator.colorScheme = colorScheme
        context.coordinator.palette = palette
        context.coordinator.isJSON = isJSON
        uiView.tintColor = palette.caretColor
        let diagnosticChanged = context.coordinator.errorRange != errorRange
        context.coordinator.errorRange = errorRange
        uiView.accessibilityLabel = L10n.text(isJSON ? "JSON Editor" : "SQL query editor")
        uiView.accessibilityHint = isJSON ? L10n.text("Enter a MongoDB Extended JSON command") : L10n.text("Enter the SQL statement to run against the selected database")
        uiView.keyboardAppearance = palette.isDark ? .dark : .light
        if let queryView = uiView as? QueryTextView {
            queryView.palette = palette
            let allowsComments = allowsSQLComments && !isJSON
            if queryView.allowsSQLComments != allowsComments {
                queryView.allowsSQLComments = allowsComments
                queryView.installEditingToolbar()
            }
            queryView.refreshLineNumbers()
        }
        guard uiView.markedTextRange == nil else { return }
        context.coordinator.font = SQLEditorTypography.queryFont(compatibleWith: uiView.traitCollection)
        if diagnosticChanged || uiView.text != text || context.coordinator.lastAppliedColorScheme != colorScheme
            || context.coordinator.lastAppliedPalette != palette
            || context.coordinator.lastAppliedJSON != isJSON
            || context.coordinator.lastAppliedFontSize != context.coordinator.font.pointSize {
            context.coordinator.applyHighlight(to: uiView, text: text)
        }
        let offset = max(0, min(cursorOffset, uiView.textStorage.length))
        let range = NSRange(location: offset, length: max(0, min(selectionLength, uiView.textStorage.length - offset)))
        if uiView.selectedRange != range {
            context.coordinator.setSelection(range, in: uiView)
        }
        if let queryView = uiView as? QueryTextView { context.coordinator.updateCompletion(completion, in: queryView) }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var cursorOffset: Int
        @Binding private var selectionLength: Int
        var colorScheme: ColorScheme
        var isJSON: Bool
        var palette = EditorTheme.current.palette(for: .light)
        var lastAppliedColorScheme: ColorScheme?
        var lastAppliedPalette: EditorPalette?
        var lastAppliedJSON: Bool?
        var errorRange: NSRange?
        var font = SQLEditorTypography.queryFont()
        var lastAppliedFontSize: CGFloat?
        private var isApplyingHighlight = false
        private var pendingHighlightWorkItem: DispatchWorkItem?

        init(text: Binding<String>, cursorOffset: Binding<Int>, selectionLength: Binding<Int>, colorScheme: ColorScheme, isJSON: Bool) {
            self._text = text
            self._cursorOffset = cursorOffset
            self._selectionLength = selectionLength
            self.colorScheme = colorScheme
            self.isJSON = isJSON
        }

        func updateBindings(text: Binding<String>, cursorOffset: Binding<Int>, selectionLength: Binding<Int>) {
            // Reordering aggregation stages keeps the view's identity but changes its collection binding.
            self._text = text
            self._cursorOffset = cursorOffset
            self._selectionLength = selectionLength
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            text = textView.text
            let selectedRange = textView.selectedRange
            cursorOffset = selectedRange.location
            selectionLength = selectedRange.length
            scheduleHighlight(for: textView, preserving: selectedRange)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            cursorOffset = min(textView.selectedRange.location, textView.textStorage.length)
            selectionLength = textView.selectedRange.length
        }

        private var completion = SQLCompletionResult.empty

        /// Shows a completion in the keyboard bar if it's for the text and caret as they are now.
        fileprivate func updateCompletion(_ result: SQLCompletionResult?, in textView: QueryTextView) {
            guard let result else { textView.setCompletions([]); return }
            let source = (textView.text ?? "") as NSString
            let caret = textView.selectedRange
            guard caret.length == 0, NSMaxRange(result.fragmentRange) == caret.location, NSMaxRange(result.fragmentRange) <= source.length,
                  source.substring(with: result.fragmentRange) == result.fragment else { return }
            completion = result
            textView.setCompletions(result.opensAutomatically || !result.fragment.isEmpty ? result.items : [], signature: result.signature)
        }

        /// Inserts a completion as ordinary edits, so Undo takes it back.
        fileprivate func accept(_ item: SQLCompletionItem, in textView: QueryTextView) {
            guard let plan = SQLCompletionEngine.edits(for: item, in: textView.text ?? "", result: completion) else { return }
            for edit in plan.edits {
                guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                      let end = textView.position(from: start, offset: edit.range.length),
                      let range = textView.textRange(from: start, to: end) else { continue }
                textView.replace(range, withText: edit.text)
            }
            textView.selectedRange = NSRange(location: min(plan.cursor, textView.textStorage.length), length: 0)
            textView.setCompletions([])
            SQLCompletionUsage.record(item)
            completion = .empty
            textViewDidChange(textView)
        }

        func setSelection(_ range: NSRange, in textView: UITextView) {
            isApplyingHighlight = true
            textView.selectedRange = range
            isApplyingHighlight = false
        }

        func applyHighlight(to textView: UITextView, text: String) {
            guard textView.markedTextRange == nil else { return }
            pendingHighlightWorkItem?.cancel()
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }
            lastAppliedColorScheme = colorScheme
            lastAppliedPalette = palette
            lastAppliedJSON = isJSON
            lastAppliedFontSize = font.pointSize

            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            let selectedRange = textView.selectedRange
            let storage = textView.textStorage
            storage.beginEditing()
            if storage.string != text { storage.replaceCharacters(in: fullRange, with: text) }
            let updatedRange = NSRange(location: 0, length: storage.length)
            storage.setAttributes(baseAttributes, range: updatedRange)

            for token in isJSON ? JSONSyntaxHighlighter.tokens(in: text) : SQLSyntaxHighlighter.tokens(in: text) {
                storage.addAttributes(attributes(for: token.kind), range: token.range)
            }
            if let errorRange, errorRange.location <= storage.length, NSMaxRange(errorRange) <= storage.length {
                storage.addAttributes([.backgroundColor: UIColor.systemRed.withAlphaComponent(0.18),
                                       .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: UIColor.systemRed], range: errorRange)
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
            textView.selectedRange = Self.clampedRange(selectedRange, length: storage.length)
        }

        private func scheduleHighlight(for textView: UITextView, preserving selectedRange: NSRange) {
            pendingHighlightWorkItem?.cancel()

            let currentText = textView.text ?? ""
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, textView.text == currentText, textView.markedTextRange == nil else { return }
                self.applyHighlight(to: textView, text: currentText)
            }

            pendingHighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
        }

        private static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            return style
        }()

        private static func clampedRange(_ range: NSRange, length: Int) -> NSRange {
            let location = min(range.location, length)
            let availableLength = max(0, length - location)
            return NSRange(location: location, length: min(range.length, availableLength))
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: palette.plainColor,
                .paragraphStyle: Self.paragraphStyle
            ]
        }

        private func attributes(for kind: SQLTokenKind) -> [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: palette.color(for: kind),
                .paragraphStyle: Self.paragraphStyle
            ]
        }
    }

    private static var font: UIFont {
        SQLEditorTypography.queryFont()
    }
}

struct HighlightedClauseEditor: UIViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme = .light
    var accessibilityLabel = "SQL clause editor"
    var onFocusChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, colorScheme: colorScheme, onFocusChanged: onFocusChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        // SQL isn't prose: no spelling or word predictions competing with the completions bar.
        textView.spellCheckingType = .no
        textView.inlinePredictionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.font = Self.font
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.maximumNumberOfLines = 1
        textView.isScrollEnabled = true
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.tintColor = UIColor(red: 0.12, green: 0.46, blue: 0.95, alpha: 1.0)
        textView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        textView.accessibilityLabel = accessibilityLabel
        context.coordinator.applyHighlight(to: textView, text: text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.colorScheme = colorScheme
        uiView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        uiView.font = Self.font
        uiView.accessibilityLabel = accessibilityLabel
        guard uiView.markedTextRange == nil else { return }
        guard uiView.text != text || context.coordinator.lastAppliedColorScheme != colorScheme else { return }
        let selectedRange = uiView.selectedRange
        context.coordinator.applyHighlight(to: uiView, text: text)
        uiView.selectedRange = context.coordinator.clampedRange(selectedRange, length: uiView.attributedText.length)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        var colorScheme: ColorScheme
        var lastAppliedColorScheme: ColorScheme?
        private let onFocusChanged: (Bool) -> Void
        private var isApplyingHighlight = false
        private var pendingHighlightWorkItem: DispatchWorkItem?

        init(text: Binding<String>, colorScheme: ColorScheme, onFocusChanged: @escaping (Bool) -> Void) {
            self._text = text
            self.colorScheme = colorScheme
            self.onFocusChanged = onFocusChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            text = textView.text
            let selectedRange = textView.selectedRange
            scheduleHighlight(for: textView, preserving: selectedRange)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onFocusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onFocusChanged(false)
        }

        func applyHighlight(to textView: UITextView, text: String) {
            guard textView.markedTextRange == nil else { return }
            pendingHighlightWorkItem?.cancel()
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }
            lastAppliedColorScheme = colorScheme

            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            let selectedRange = textView.selectedRange
            let storage = textView.textStorage
            storage.beginEditing()
            if storage.string != text { storage.replaceCharacters(in: fullRange, with: text) }
            let updatedRange = NSRange(location: 0, length: storage.length)
            storage.setAttributes(baseAttributes, range: updatedRange)

            for token in SQLSyntaxHighlighter.tokens(in: text) {
                storage.addAttributes(attributes(for: token.kind), range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
            textView.selectedRange = clampedRange(selectedRange, length: storage.length)
        }

        private func scheduleHighlight(for textView: UITextView, preserving selectedRange: NSRange) {
            pendingHighlightWorkItem?.cancel()

            let currentText = textView.text ?? ""
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, textView.text == currentText, textView.markedTextRange == nil else { return }
                self.applyHighlight(to: textView, text: currentText)
            }

            pendingHighlightWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
        }

        func clampedRange(_ range: NSRange, length: Int) -> NSRange {
            let location = min(range.location, length)
            let availableLength = max(0, length - location)
            return NSRange(location: location, length: min(range.length, availableLength))
        }

        private static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byClipping
            return style
        }()

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: HighlightedClauseEditor.font,
                .foregroundColor: colorScheme == .dark
                    ? UIColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1.0)
                    : UIColor(red: 0.16, green: 0.20, blue: 0.26, alpha: 1.0),
                .paragraphStyle: Self.paragraphStyle
            ]
        }

        private func attributes(for kind: SQLTokenKind) -> [NSAttributedString.Key: Any] {
            let color: UIColor
            if colorScheme == .dark {
                switch kind {
                case .keyword:
                    color = UIColor(red: 0.48, green: 0.83, blue: 1.0, alpha: 1.0)
                case .stringLiteral:
                    color = UIColor(red: 0.99, green: 0.78, blue: 0.5, alpha: 1.0)
                case .numberLiteral:
                    color = UIColor(red: 0.6, green: 0.97, blue: 0.77, alpha: 1.0)
                case .comment:
                    color = UIColor(red: 0.57, green: 0.63, blue: 0.72, alpha: 1.0)
                case .identifier:
                    color = UIColor(red: 0.89, green: 0.92, blue: 0.96, alpha: 1.0)
                case .symbol:
                    color = UIColor(red: 0.94, green: 0.67, blue: 0.78, alpha: 1.0)
                }
            } else {
                switch kind {
                case .keyword:
                    color = UIColor(red: 0.1, green: 0.42, blue: 0.88, alpha: 1.0)
                case .stringLiteral:
                    color = UIColor(red: 0.72, green: 0.38, blue: 0.08, alpha: 1.0)
                case .numberLiteral:
                    color = UIColor(red: 0.12, green: 0.58, blue: 0.34, alpha: 1.0)
                case .comment:
                    color = UIColor(red: 0.48, green: 0.54, blue: 0.62, alpha: 1.0)
                case .identifier:
                    color = UIColor(red: 0.16, green: 0.2, blue: 0.26, alpha: 1.0)
                case .symbol:
                    color = UIColor(red: 0.69, green: 0.21, blue: 0.43, alpha: 1.0)
                }
            }

            return [
                .font: HighlightedClauseEditor.font,
                .foregroundColor: color,
                .paragraphStyle: Self.paragraphStyle
            ]
        }
    }

    private static var font: UIFont {
        SQLEditorTypography.clauseFont()
    }
}

#endif
