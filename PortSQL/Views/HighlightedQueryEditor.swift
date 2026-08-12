import SwiftUI
import UIKit

enum SQLEditorTypography {
    static func queryFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 16, weight: .regular),
            compatibleWith: traits
        )
    }

    static func clauseFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular),
            compatibleWith: traits
        )
    }
}

struct HighlightedQueryEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursorOffset: Int
    var colorScheme: ColorScheme = .light

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, cursorOffset: $cursorOffset, colorScheme: colorScheme)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.font = Self.font
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.tintColor = UIColor(red: 0.38, green: 0.78, blue: 1.0, alpha: 1.0)
        textView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        textView.accessibilityLabel = "SQL query editor"
        textView.accessibilityHint = "Enter the SQL statement to run against the selected database"
        context.coordinator.applyHighlight(to: textView, text: text)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.colorScheme = colorScheme
        uiView.keyboardAppearance = colorScheme == .dark ? .dark : .light
        uiView.font = Self.font
        let desiredOffset = min(cursorOffset, uiView.attributedText.length)
        if uiView.text != text || context.coordinator.lastAppliedColorScheme != colorScheme {
            context.coordinator.applyHighlight(to: uiView, text: text)
        }
        if uiView.selectedRange.length == 0 && uiView.selectedRange.location != desiredOffset {
            uiView.selectedRange = NSRange(location: desiredOffset, length: 0)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        @Binding private var cursorOffset: Int
        var colorScheme: ColorScheme
        var lastAppliedColorScheme: ColorScheme?
        private var isApplyingHighlight = false
        private weak var pendingTextView: UITextView?
        private var pendingHighlightWorkItem: DispatchWorkItem?

        init(text: Binding<String>, cursorOffset: Binding<Int>, colorScheme: ColorScheme) {
            self._text = text
            self._cursorOffset = cursorOffset
            self.colorScheme = colorScheme
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            text = textView.text
            let selectedRange = textView.selectedRange
            cursorOffset = selectedRange.location
            scheduleHighlight(for: textView, preserving: selectedRange)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            cursorOffset = min(textView.selectedRange.location, textView.text.count)
        }

        func applyHighlight(to textView: UITextView, text: String) {
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }
            lastAppliedColorScheme = colorScheme

            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            let selectedRange = textView.selectedRange
            let storage = textView.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: fullRange, with: text)
            let updatedRange = NSRange(location: 0, length: storage.length)
            storage.setAttributes(baseAttributes, range: updatedRange)

            for token in SQLSyntaxHighlighter.tokens(in: text) {
                storage.addAttributes(attributes(for: token.kind), range: token.range)
            }
            storage.endEditing()
            textView.typingAttributes = baseAttributes
            textView.selectedRange = Self.clampedRange(selectedRange, length: storage.length)
        }

        private func scheduleHighlight(for textView: UITextView, preserving selectedRange: NSRange) {
            pendingHighlightWorkItem?.cancel()
            pendingTextView = textView

            let currentText = textView.text ?? ""
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlight(to: textView, text: currentText)
                textView.selectedRange = Self.clampedRange(selectedRange, length: textView.textStorage.length)
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
                .font: HighlightedQueryEditor.font,
                .foregroundColor: colorScheme == .dark
                    ? UIColor(red: 0.84, green: 0.95, blue: 0.9, alpha: 1.0)
                    : UIColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1.0),
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
                    color = UIColor(red: 0.10, green: 0.43, blue: 0.90, alpha: 1.0)
                case .stringLiteral:
                    color = UIColor(red: 0.73, green: 0.39, blue: 0.09, alpha: 1.0)
                case .numberLiteral:
                    color = UIColor(red: 0.13, green: 0.57, blue: 0.35, alpha: 1.0)
                case .comment:
                    color = UIColor(red: 0.47, green: 0.53, blue: 0.61, alpha: 1.0)
                case .identifier:
                    color = UIColor(red: 0.16, green: 0.20, blue: 0.26, alpha: 1.0)
                case .symbol:
                    color = UIColor(red: 0.69, green: 0.21, blue: 0.43, alpha: 1.0)
                }
            }

            return [
                .font: HighlightedQueryEditor.font,
                .foregroundColor: color,
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
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }
            lastAppliedColorScheme = colorScheme

            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            let selectedRange = textView.selectedRange
            let storage = textView.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: fullRange, with: text)
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
                guard let self, let textView else { return }
                self.applyHighlight(to: textView, text: currentText)
                textView.selectedRange = self.clampedRange(selectedRange, length: textView.textStorage.length)
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
