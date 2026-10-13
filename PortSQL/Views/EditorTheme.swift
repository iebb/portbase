import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PortbasePlatformColor = UIColor
#else
import AppKit
typealias PortbasePlatformColor = NSColor
#endif

/// Syntax colors for one editor appearance.
struct EditorPalette: Equatable {
    let background: UInt32
    let gutter: UInt32
    let plain: UInt32
    let keyword: UInt32
    let string: UInt32
    let number: UInt32
    let comment: UInt32
    let identifier: UInt32
    let symbol: UInt32
    let isDark: Bool

    func color(_ value: UInt32, alpha: CGFloat = 1) -> PortbasePlatformColor { PortbasePlatformColor(rgb: value, alpha: alpha) }

    func color(for kind: SQLTokenKind) -> PortbasePlatformColor {
        switch kind {
        case .keyword: color(keyword)
        case .stringLiteral: color(string)
        case .numberLiteral: color(number)
        case .comment: color(comment)
        case .identifier: color(identifier)
        case .symbol: color(symbol)
        }
    }

    var plainColor: PortbasePlatformColor { color(plain) }
    var backgroundColor: PortbasePlatformColor { color(background) }
    var gutterColor: PortbasePlatformColor { color(gutter) }
    var gutterTextColor: PortbasePlatformColor { color(comment, alpha: 0.85) }
    var caretColor: PortbasePlatformColor { color(keyword) }
}

enum EditorTheme: String, CaseIterable, Identifiable {
    case portbase, midnight, paper, solarized, ember

    static let storageKey = "Portbase.editorTheme"
    var id: String { rawValue }

    static var current: EditorTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(EditorTheme.init(rawValue:)) ?? .portbase
    }

    var title: String {
        switch self {
        // Theme names are product names and are not translated.
        case .portbase: "Portbase"
        case .midnight: "Midnight"
        case .paper: "Paper"
        case .solarized: "Solarized"
        case .ember: "Ember"
        }
    }

    var subtitle: String {
        switch self {
        case .portbase, .solarized: L10n.text("Follows light and dark mode")
        case .midnight, .ember: L10n.text("Always dark")
        case .paper: L10n.text("Always light")
        }
    }

    func palette(for colorScheme: ColorScheme) -> EditorPalette {
        switch self {
        case .portbase:
            colorScheme == .dark
                ? EditorPalette(background: 0x0B1020, gutter: 0x0E1427, plain: 0xC9CEDB, keyword: 0x3FC48A, string: 0xF7C14D,
                                number: 0x5AA8F8, comment: 0x5A5E73, identifier: 0xEDF1F2, symbol: 0xE0649F, isDark: true)
                : EditorPalette(background: 0xFFFFFF, gutter: 0xF3F5F7, plain: 0x101525, keyword: 0x158A4E, string: 0xA86A12,
                                number: 0x0B6BCB, comment: 0x8D91A5, identifier: 0x101525, symbol: 0xB8327C, isDark: false)
        case .midnight:
            EditorPalette(background: 0x0B1020, gutter: 0x0F1529, plain: 0xC9D1E5, keyword: 0x7AA2F7, string: 0x9ECE6A,
                          number: 0xFF9E64, comment: 0x565F89, identifier: 0xC0CAF5, symbol: 0xBB9AF7, isDark: true)
        case .paper:
            EditorPalette(background: 0xFFFDF7, gutter: 0xF6F1E4, plain: 0x2D2A26, keyword: 0x0B6BCB, string: 0xA1520F,
                          number: 0x2F7D32, comment: 0x9C9585, identifier: 0x2D2A26, symbol: 0xAD1457, isDark: false)
        case .solarized:
            colorScheme == .dark
                ? EditorPalette(background: 0x002B36, gutter: 0x073642, plain: 0x93A1A1, keyword: 0x268BD2, string: 0x2AA198,
                                number: 0xD33682, comment: 0x586E75, identifier: 0x839496, symbol: 0xCB4B16, isDark: true)
                : EditorPalette(background: 0xFDF6E3, gutter: 0xEEE8D5, plain: 0x586E75, keyword: 0x268BD2, string: 0x2AA198,
                                number: 0xD33682, comment: 0x93A1A1, identifier: 0x657B83, symbol: 0xCB4B16, isDark: false)
        case .ember:
            EditorPalette(background: 0x1A1412, gutter: 0x211916, plain: 0xEADBD0, keyword: 0xFF8A5B, string: 0xE9C46A,
                          number: 0x8BD3A3, comment: 0x8C7A6B, identifier: 0xF1E6DC, symbol: 0xF28FAD, isDark: true)
        }
    }

    func background(for colorScheme: ColorScheme) -> Color {
        Color(hex: palette(for: colorScheme).background)
    }

    func placeholder(for colorScheme: ColorScheme) -> Color {
        Color(hex: palette(for: colorScheme).comment)
    }
}

/// A short highlighted sample used to preview a theme.
struct EditorThemePreview: View {
    let theme: EditorTheme
    var isSelected = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(for: colorScheme)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            line([("SELECT", palette.keyword), (" name, ", palette.identifier), ("count", palette.keyword), ("(*)", palette.symbol)])
            line([("FROM", palette.keyword), (" orders", palette.identifier)])
            line([("WHERE", palette.keyword), (" total ", palette.identifier), (">=", palette.symbol), (" 50", palette.number)])
            line([("-- ", palette.comment), ("'", palette.string), ("paid", palette.string), ("'", palette.string)])
        }
        .font(.codeCaption)
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: palette.background), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(isSelected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityHidden(true)
    }

    private func line(_ parts: [(String, UInt32)]) -> Text {
        parts.reduce(Text(verbatim: "")) { partial, part in
            partial + Text(verbatim: part.0).foregroundColor(Color(hex: part.1))
        }
    }
}
