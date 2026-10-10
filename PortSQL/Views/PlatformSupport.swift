import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PortbaseKeyboardType = UIKeyboardType
#else
import AppKit
enum PortbaseKeyboardType { case `default`, numberPad, decimalPad, numbersAndPunctuation, URL, emailAddress, asciiCapable }
#endif

enum PortbaseControlSize {
    static var minimumHeight: CGFloat {
#if os(macOS)
        24
#else
        44
#endif
    }
}

enum PortbaseTitleMode { case inline, large, automatic }
enum PortbaseCapitalization { case never, words, sentences, characters }

enum PortbaseToolbar {
    static var leading: ToolbarItemPlacement {
#if os(macOS)
        .navigation
#else
        .topBarLeading
#endif
    }
    static var trailing: ToolbarItemPlacement {
#if os(macOS)
        .primaryAction
#else
        .topBarTrailing
#endif
    }
}

extension View {
    @ViewBuilder func portbaseDesktopSheetSize(width: CGFloat = 640, height: CGFloat = 480) -> some View {
#if os(macOS)
        self.frame(minWidth: width, minHeight: height)
#else
        self
#endif
    }
}

extension View {
    @ViewBuilder func portbaseTitleDisplayMode(_ mode: PortbaseTitleMode) -> some View {
#if canImport(UIKit)
        navigationBarTitleDisplayMode(mode == .inline ? .inline : mode == .large ? .large : .automatic)
#else
        self
#endif
    }
    @ViewBuilder func portbaseTextCapitalization(_ mode: PortbaseCapitalization) -> some View {
#if canImport(UIKit)
        textInputAutocapitalization(mode == .never ? .never : mode == .words ? .words : mode == .sentences ? .sentences : .characters)
#else
        self
#endif
    }
    @ViewBuilder func portbaseKeyboardType(_ type: PortbaseKeyboardType) -> some View {
#if canImport(UIKit)
        keyboardType(type)
#else
        self
#endif
    }
    @ViewBuilder func portbaseEditorPresentation<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
#if os(macOS)
        sheet(isPresented: isPresented, content: content)
#else
        fullScreenCover(isPresented: isPresented, content: content)
#endif
    }
}

#if os(macOS)
extension PickerStyle where Self == MenuPickerStyle {
    static var portbaseNavigation: MenuPickerStyle { .menu }
}
extension ListStyle where Self == InsetListStyle {
    static var portbaseGrouped: InsetListStyle { .inset }
}
#else
extension PickerStyle where Self == NavigationLinkPickerStyle {
    static var portbaseNavigation: NavigationLinkPickerStyle { .navigationLink }
}
extension ListStyle where Self == InsetGroupedListStyle {
    static var portbaseGrouped: InsetGroupedListStyle { .insetGrouped }
}
#endif

@MainActor enum PortbaseClipboard {
    static func copy(_ text: String) { copy(items: [["public.utf8-plain-text": text]]) }
    static func copy(items: [[String: Any]]) {
#if canImport(UIKit)
        UIPasteboard.general.setItems(items)
#else
        let values = items.map { value in
            let item = NSPasteboardItem()
            for (key, content) in value {
                let type = NSPasteboard.PasteboardType(key)
                if let text = content as? String { item.setString(text, forType: type) }
                else if let data = content as? Data { item.setData(data, forType: type) }
            }
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(values)
#endif
    }
}
