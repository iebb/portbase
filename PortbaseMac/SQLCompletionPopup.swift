import AppKit
import SwiftUI

/// The completion list's items and highlighted row, shared by the popup panel and its SwiftUI list.
@MainActor final class SQLCompletionPopupModel: ObservableObject {
    @Published var items: [SQLCompletionItem] = []
    @Published var selected = 0
    @Published var typed = ""
}

/// A completion list at the caret, as in DataGrip: it opens while typing, ↑↓ move through it, Return or
/// Tab insert the highlighted item, Esc closes it, and a click inserts an item. It never takes focus from
/// the editor.
@MainActor final class SQLCompletionPopup {
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 460

    private let panel: NSPanel
    private let model = SQLCompletionPopupModel()
    private weak var parentWindow: NSWindow?
    var onAccept: (SQLCompletionItem) -> Void = { _ in }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        let list = SQLCompletionList(model: model, onAccept: { [weak self] item in self?.onAccept(item) })
        panel.contentView = NSHostingView(rootView: list.portbaseTheme())
    }

    var isVisible: Bool { panel.isVisible }
    var selectedItem: SQLCompletionItem? { model.items.indices.contains(model.selected) ? model.items[model.selected] : nil }

    /// Shows the items under the caret rectangle (in screen coordinates), or above it near the screen's bottom.
    func show(_ items: [SQLCompletionItem], typed: String, below caret: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { hide(); return }
        let keepSelection = isVisible ? selectedItem?.id : nil
        // Only changes are assigned, so an unchanged list isn't laid out again.
        if model.items != items { model.items = items }
        if model.typed != typed { model.typed = typed }
        let selected = keepSelection.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        if model.selected != selected { model.selected = selected }
        let visibleRows = CGFloat(min(items.count, 9))
        let height = visibleRows * Self.rowHeight + 34
        var origin = NSPoint(x: caret.minX - 28, y: caret.minY - height - 4)
        if let screen = window.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(screen.minX + 4, origin.x), screen.maxX - Self.width - 4)
        }
        let frame = NSRect(origin: origin, size: NSSize(width: Self.width, height: height))
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // A floating panel takes the system's light or dark look unless told; it follows the editor's window.
        if panel.appearance?.name != window.effectiveAppearance.name { panel.appearance = window.effectiveAppearance }
        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parentWindow = window
        }
        let opening = !panel.isVisible
        if opening { panel.orderFront(nil) }
        if opening || keepSelection != selectedItem?.id { announceSelection(withCount: opening) }
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
    }

    func move(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
        announceSelection(withCount: false)
    }

    func page(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = max(0, min(model.items.count - 1, model.selected + delta * 8))
        announceSelection(withCount: false)
    }

    /// The panel never takes focus, so VoiceOver hears the highlighted item instead of reading the list.
    private func announceSelection(withCount: Bool) {
        guard let item = selectedItem else { return }
        var parts = [item.label, item.kind.title]
        if let detail = item.detail { parts.append(detail) }
        if withCount { parts.insert(L10n.format("Suggestions: %d", model.items.count), at: 0) }
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: parts.joined(separator: ", "), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

struct SQLCompletionList: View {
    @ObservedObject var model: SQLCompletionPopupModel
    let onAccept: (SQLCompletionItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == model.selected)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onAccept(item) }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.selected) { _, selected in
                    guard model.items.indices.contains(selected) else { return }
                    proxy.scrollTo(model.items[selected].id)
                }
            }
            Divider()
            HStack(spacing: Spacing.m) {
                Text("↩ ⇥ Insert")
                Text("↑↓ Choose")
                Text("esc Close")
                Spacer(minLength: 0)
                if let item = model.items.indices.contains(model.selected) ? model.items[model.selected] : nil {
                    Text(item.kind.title).foregroundStyle(PortSQLPalette.muted)
                }
            }
            .font(.microText)
            .foregroundStyle(PortSQLPalette.muted)
            .padding(.horizontal, Spacing.s)
            .frame(height: 24)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func row(_ item: SQLCompletionItem, selected: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : item.kind.tint)
                .frame(width: 18, height: 18)
                .background(selected ? Color.white.opacity(0.2) : item.kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            highlighted(item.label, selected: selected)
                .font(.codeDetail)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.s)
            if let detail = item.detail {
                Text(detail)
                    .font(.microText)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : PortSQLPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: SQLCompletionPopup.rowHeight)
        .background(selected ? PortSQLPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, 3)
    }

    /// The label with the typed letters in bold, so it's clear why the item matched. Built as one
    /// attributed string rather than a Text per character, since it's drawn for every row on each keystroke.
    private func highlighted(_ label: String, selected: Bool) -> Text {
        let color = selected ? Color.white : PortSQLPalette.ink
        let typed = model.typed.lowercased()
        guard !typed.isEmpty else { return Text(label).foregroundColor(color) }
        var result = AttributedString(label)
        result.foregroundColor = color.opacity(selected ? 0.9 : 0.75)
        var remaining = typed[...]
        var index = result.startIndex
        for character in label {
            let next = result.characters.index(after: index)
            if let wanted = remaining.first, character.lowercased() == String(wanted) {
                remaining = remaining.dropFirst()
                result[index..<next].foregroundColor = color
                result[index..<next].inlinePresentationIntent = .stronglyEmphasized
            }
            index = next
        }
        return Text(result)
    }
}

/// A parameter hint above the caret, as DataGrip shows inside a function call: the signature with the
/// current argument in bold.
@MainActor final class SQLSignaturePopup {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private weak var parentWindow: NSWindow?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 26), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host
    }

    func show(_ signature: SQLSignatureHint, above caret: NSRect, in window: NSWindow) {
        host.rootView = AnyView(SQLSignatureView(signature: signature).portbaseTheme())
        let size = host.fittingSize
        let origin = NSPoint(x: caret.minX - 12, y: caret.maxY + 6)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: max(80, size.width), height: max(24, size.height))), display: true)
        // A floating panel takes the system's light or dark look unless told; it follows the editor's window.
        panel.appearance = window.effectiveAppearance
        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parentWindow = window
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
    }
}

struct SQLSignatureView: View {
    let signature: SQLSignatureHint

    var body: some View {
        SQLSignatureText(signature: signature)
            .font(.codeDetail)
            .lineLimit(1)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
            .fixedSize()
    }
}
