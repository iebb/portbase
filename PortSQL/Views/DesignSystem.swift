import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Preferences

enum PortbaseAccent: String, CaseIterable, Identifiable {
    case jade, indigo, ocean, emerald, sunset, rose, graphite

    static let storageKey = "Portbase.accent"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .jade: L10n.text("Jade")
        case .indigo: L10n.text("Indigo")
        case .ocean: L10n.text("Ocean")
        case .emerald: L10n.text("Emerald")
        case .sunset: L10n.text("Sunset")
        case .rose: L10n.text("Rose")
        case .graphite: L10n.text("Graphite")
        }
    }

    var color: Color {
        switch self {
        // A deep jade that keeps white button labels readable in both appearances.
        case .jade: Color.adaptive(light: 0x158A4E, dark: 0x199655)
        case .indigo: Color.adaptive(light: 0x4F46E5, dark: 0x6366F1)
        case .ocean: Color.adaptive(light: 0x0A6CD6, dark: 0x2D7FE0)
        case .emerald: Color.adaptive(light: 0x0E8F6A, dark: 0x109A70)
        case .sunset: Color.adaptive(light: 0xD9480F, dark: 0xE2622A)
        case .rose: Color.adaptive(light: 0xD6336C, dark: 0xE04680)
        case .graphite: Color.adaptive(light: 0x3F4654, dark: 0x6B7588)
        }
    }

    var gradient: [Color] {
        switch self {
        case .jade: [Color(hex: 0x21B568), Color(hex: 0x0F6338)]
        case .indigo: [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)]
        case .ocean: [Color(hex: 0x0EA5E9), Color(hex: 0x2563EB)]
        case .emerald: [Color(hex: 0x10B981), Color(hex: 0x0D9488)]
        case .sunset: [Color(hex: 0xF97316), Color(hex: 0xE11D48)]
        case .rose: [Color(hex: 0xEC4899), Color(hex: 0xA855F7)]
        case .graphite: [Color(hex: 0x64748B), Color(hex: 0x334155)]
        }
    }

    static var current: PortbaseAccent {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PortbaseAccent.init(rawValue:)) ?? .jade
    }
}

enum PortbaseAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "Portbase.appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.text("Match System")
        case .light: L10n.text("Light")
        case .dark: L10n.text("Dark")
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the person's appearance and accent choices to a whole scene.
struct PortbaseThemeModifier: ViewModifier {
    @AppStorage(PortbaseAccent.storageKey) private var accent = PortbaseAccent.jade.rawValue
    @AppStorage(PortbaseAppearance.storageKey) private var appearance = PortbaseAppearance.system.rawValue
    @AppStorage(PortbaseTheme.storageKey) private var theme = PortbaseTheme.navy.rawValue
    @AppStorage(PortbaseInterfaceFont.storageKey) private var interfaceFont = PortbaseInterfaceFont.inter.rawValue
    @AppStorage(PortbaseCodeFont.storageKey) private var codeFont = PortbaseCodeFont.sourceCodePro.rawValue

    func body(content: Content) -> some View {
        let accentChoice = PortbaseAccent(rawValue: accent) ?? .jade
        content
            // The interface font for all text that doesn't pick a role, and squared-off buttons instead of capsules.
            .font(.bodyText)
            .buttonBorderShape(.roundedRectangle(radius: Radius.button))
            // Palette and font tokens read the stored preferences, so a new identity redraws views that cached them.
            .id([accent, theme, interfaceFont, codeFont].joined(separator: "/"))
            .tint(accentChoice.color)
            .preferredColorScheme((PortbaseAppearance(rawValue: appearance) ?? .system).colorScheme)
    }
}

extension View {
    func portbaseTheme() -> some View { modifier(PortbaseThemeModifier()) }
}

/// The interface palette. Each theme defines light and dark surfaces; the accent is chosen separately.
enum PortbaseTheme: String, CaseIterable, Identifiable {
    case navy, graphite, nord, paper

    static let storageKey = "Portbase.theme"
    var id: String { rawValue }

    // Theme names are product names and are not translated.
    var title: String {
        switch self {
        case .navy: "Navy"
        case .graphite: "Graphite"
        case .nord: "Nord"
        case .paper: "Paper"
        }
    }

    var subtitle: String {
        switch self {
        case .navy: L10n.text("Deep navy and slate")
        case .graphite: L10n.text("Neutral grays")
        case .nord: L10n.text("Cool blue-gray")
        case .paper: L10n.text("Warm and soft")
        }
    }

    struct Palette {
        let ink, muted, panel, surface, tertiarySurface, sunken, stroke, canvas, canvasAccent: Color
        /// Picker swatches as (canvas, surface) in light and dark.
        let lightSwatch: (UInt32, UInt32)
        let darkSwatch: (UInt32, UInt32)
    }

    var palette: Palette {
        switch self {
        case .navy:
            Palette(ink: .adaptive(light: 0x101525, dark: 0xEDF1F2), muted: .adaptive(light: 0x5A5E73, dark: 0x8D91A5),
                    panel: .adaptive(light: 0xF5F7F9, dark: 0x111729), surface: .adaptive(light: 0xFFFFFF, dark: 0x161C30),
                    tertiarySurface: .adaptive(light: 0xF7F9FA, dark: 0x1B2238), sunken: .adaptive(light: 0xEDF1F2, dark: 0x0C1223),
                    stroke: .adaptive(light: 0xDFE4E8, dark: 0x262D45), canvas: .adaptive(light: 0xF2F4F6, dark: 0x0A0F1E),
                    canvasAccent: .adaptive(light: 0xE8ECEF, dark: 0x0E1426),
                    lightSwatch: (0xF2F4F6, 0xFFFFFF), darkSwatch: (0x0A0F1E, 0x161C30))
        case .graphite:
            Palette(ink: .adaptive(light: 0x1C1C1E, dark: 0xEDEDEF), muted: .adaptive(light: 0x6B6B72, dark: 0x9A9AA2),
                    panel: .adaptive(light: 0xF6F6F7, dark: 0x1B1B1E), surface: .adaptive(light: 0xFFFFFF, dark: 0x202023),
                    tertiarySurface: .adaptive(light: 0xF8F8F9, dark: 0x26262A), sunken: .adaptive(light: 0xEEEEF0, dark: 0x141416),
                    stroke: .adaptive(light: 0xE0E0E4, dark: 0x323237), canvas: .adaptive(light: 0xF3F3F5, dark: 0x161618),
                    canvasAccent: .adaptive(light: 0xEAEAED, dark: 0x19191C),
                    lightSwatch: (0xF3F3F5, 0xFFFFFF), darkSwatch: (0x161618, 0x202023))
        case .nord:
            Palette(ink: .adaptive(light: 0x2E3440, dark: 0xECEFF4), muted: .adaptive(light: 0x5E6779, dark: 0x9AA3B5),
                    panel: .adaptive(light: 0xE9EDF3, dark: 0x2F3541), surface: .adaptive(light: 0xFFFFFF, dark: 0x343B48),
                    tertiarySurface: .adaptive(light: 0xF3F5F8, dark: 0x3A4250), sunken: .adaptive(light: 0xE5E9F0, dark: 0x282D37),
                    stroke: .adaptive(light: 0xD8DEE9, dark: 0x434C5E), canvas: .adaptive(light: 0xECEFF4, dark: 0x2B303B),
                    canvasAccent: .adaptive(light: 0xE3E8EF, dark: 0x2D323D),
                    lightSwatch: (0xECEFF4, 0xFFFFFF), darkSwatch: (0x2B303B, 0x343B48))
        case .paper:
            Palette(ink: .adaptive(light: 0x2B2722, dark: 0xF2EDE4), muted: .adaptive(light: 0x786F63, dark: 0xA79E91),
                    panel: .adaptive(light: 0xF2EDE5, dark: 0x211E1B), surface: .adaptive(light: 0xFFFDF9, dark: 0x27231F),
                    tertiarySurface: .adaptive(light: 0xF8F5F0, dark: 0x2D2924), sunken: .adaptive(light: 0xEDE7DE, dark: 0x181613),
                    stroke: .adaptive(light: 0xE3DBCF, dark: 0x3A342D), canvas: .adaptive(light: 0xF6F2EC, dark: 0x1C1A17),
                    canvasAccent: .adaptive(light: 0xEFE9E0, dark: 0x1F1C19),
                    lightSwatch: (0xF6F2EC, 0xFFFDF9), darkSwatch: (0x1C1A17, 0x27231F))
        }
    }

    static var current: PortbaseTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PortbaseTheme.init(rawValue:)) ?? .navy
    }
}

/// The interface typeface.
enum PortbaseInterfaceFont: String, CaseIterable, Identifiable {
    case googleSans, inter, system, rounded

    static let storageKey = "Portbase.interfaceFont"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .googleSans: "Google Sans"
        case .inter: "Inter"
        case .system: L10n.text("System")
        case .rounded: L10n.text("Rounded")
        }
    }

    static var current: PortbaseInterfaceFont {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PortbaseInterfaceFont.init(rawValue:)) ?? .googleSans
    }
}

/// The typeface for SQL, JSON, and values in results.
enum PortbaseCodeFont: String, CaseIterable, Identifiable {
    case googleSansCode, sourceCodePro, sfMono, menlo

    static let storageKey = "Portbase.codeFont"
    var id: String { rawValue }

    // Typeface names are product names and are not translated.
    var title: String {
        switch self {
        case .googleSansCode: "Google Sans Code"
        case .sourceCodePro: "Source Code Pro"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        }
    }

    static var current: PortbaseCodeFont {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PortbaseCodeFont.init(rawValue:)) ?? .googleSansCode
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    static func adaptive(light: UInt32, dark: UInt32, lightOpacity: CGFloat = 1, darkOpacity: CGFloat = 1) -> Color {
#if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(rgb: dark, alpha: darkOpacity)
                : UIColor(rgb: light, alpha: lightOpacity)
        })
#else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(rgb: dark, alpha: darkOpacity)
                : NSColor(rgb: light, alpha: lightOpacity)
        })
#endif
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#else
extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}
#endif

// MARK: - Engine identity

extension DatabaseEngine {
    var brandColors: [Color] {
        switch self {
        case .mysql: [Color(hex: 0x0EA5E9), Color(hex: 0x0369A1)]
        case .mariadb: [Color(hex: 0x14B8A6), Color(hex: 0x0F766E)]
        case .postgresql: [Color(hex: 0x6366F1), Color(hex: 0x1D4ED8)]
        case .sqlite: [Color(hex: 0x38BDF8), Color(hex: 0x6366F1)]
        case .clickhouse: [Color(hex: 0xFACC15), Color(hex: 0xF97316)]
        case .mongodb: [Color(hex: 0x22C55E), Color(hex: 0x047857)]
        case .redis: [Color(hex: 0xF87171), Color(hex: 0xDC2626)]
        case .elasticsearch: [Color(hex: 0x2DD4BF), Color(hex: 0x7C3AED)]
        }
    }

    var tint: Color { brandColors[1] }
}

// MARK: - Design tokens
//
// Every padding, gap, corner radius, control size, and font in the interface comes from these
// tokens so iPhone, iPad, and Mac screens share one rhythm. Values sit on a 4-point grid (with 2
// and 6 for tight inline gaps); the Mac uses slightly tighter radii and explicit point sizes,
// while iOS keeps Dynamic Type text styles.

/// The spacing scale used for stack gaps and padding.
enum Spacing {
    /// 2 pt — between stacked lines of one label.
    static let xxxs: CGFloat = 2
    /// 4 pt — icon-to-text inside chips and badges.
    static let xxs: CGFloat = 4
    /// 6 pt — tight inline groups.
    static let xs: CGFloat = 6
    /// 8 pt — default gap between related items.
    static let s: CGFloat = 8
    /// 12 pt — gap between rows and controls in a group.
    static let m: CGFloat = 12
    /// 16 pt — card padding and gap between cards.
    static let l: CGFloat = 16
    /// 20 pt — gap between page sections.
    static let xl: CGFloat = 20
    /// 24 pt — generous section and empty-state spacing.
    static let xxl: CGFloat = 24
    /// 32 pt — hero and onboarding spacing.
    static let xxxl: CGFloat = 32

    /// Inner padding of cards and panels.
    static let card: CGFloat = l
    /// Margin between a page's content and the window or screen edge.
    static let page: CGFloat = l
    /// Horizontal padding inside list and sidebar rows.
    static let rowHorizontal: CGFloat = m
    /// Vertical padding inside list and sidebar rows.
#if os(macOS)
    static let rowVertical: CGFloat = xs
#else
    static let rowVertical: CGFloat = s
#endif
    /// Horizontal padding inside chips and badges.
    static let chipHorizontal: CGFloat = s
    /// Vertical padding inside chips and badges.
    static let chipVertical: CGFloat = xxs
}

/// Corner radii, from small badges up to sheets and hero tiles.
enum Radius {
#if os(macOS)
    static let xs: CGFloat = 3
    static let s: CGFloat = 5
    static let chip: CGFloat = 4
    static let button: CGFloat = 6
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let hero: CGFloat = 14
#else
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let chip: CGFloat = 5
    static let button: CGFloat = 8
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let hero: CGFloat = 16
#endif
}

/// Fixed sizes for controls, icons, and bars.
enum Sizes {
#if os(macOS)
    /// Square tool buttons.
    static let tool: CGFloat = 30
    /// Minimum height of buttons, pickers, and tappable rows.
    static let control: CGFloat = 28
    /// Primary bars at the top of a destination.
    static let bar: CGFloat = 44
    /// Editor and result toolbars.
    static let toolbar: CGFloat = 40
    /// Console tab strips.
    static let tabStrip: CGFloat = 36
    /// Status lines, filter rows, and segmented pills.
    static let statusBar: CGFloat = 30
    /// List rows with an avatar or icon tile.
    static let row: CGFloat = 40
    /// Avatars in sidebars and menus.
    static let avatarSmall: CGFloat = 20
    /// Content height of bordered and prominent buttons.
    static let buttonContent: CGFloat = 24
    /// Fixed-width column for leading symbols so row text lines up.
    static let symbolColumn: CGFloat = 16
#else
    static let tool: CGFloat = 44
    static let control: CGFloat = 44
    static let bar: CGFloat = 52
    static let toolbar: CGFloat = 44
    static let tabStrip: CGFloat = 36
    static let statusBar: CGFloat = 36
    static let row: CGFloat = 52
    static let avatarSmall: CGFloat = 24
    static let buttonContent: CGFloat = 32
    static let symbolColumn: CGFloat = 22
#endif
    /// Small symbol badges beside text, such as insight and object-type markers.
    static let iconBadge: CGFloat = 20
    /// Avatars in lists.
    static let avatar: CGFloat = 32
    /// Avatars in connection headers.
    static let avatarLarge: CGFloat = 40
    /// Avatars in editor headers.
    static let avatarHero: CGFloat = 48
    /// Minimum interactive target on touch screens.
    static let touchTarget: CGFloat = 44
    /// Leading icon tiles in rows (connections, files, saved queries).
    static let iconTile: CGFloat = 36
    /// Small icon tiles in compact rows.
    static let iconTileSmall: CGFloat = 28
    /// Large icon tiles in headers.
    static let iconTileLarge: CGFloat = 44
    /// Width of side inspectors such as connection details.
    static let inspectorWidth: CGFloat = 300
    /// Line-number gutter of the query editor.
    static let editorGutter: CGFloat = 44
    /// Status and environment dots.
    static let dot: CGFloat = 8
    /// Symbols in empty states.
    static let emptyStateSymbol: CGFloat = 32
    /// Readable width for forms, empty states, and prose.
    static let readableWidth: CGFloat = 440
}

/// Point sizes behind the typography roles, shared with UIKit and AppKit views such as the result
/// grids and query editors so native and SwiftUI text match. iOS sizes scale with Dynamic Type.
enum TypeSize {
#if os(macOS)
    static let display: CGFloat = 26
    static let title: CGFloat = 20
    static let section: CGFloat = 15
    static let heading: CGFloat = 13
    static let body: CGFloat = 13
    static let row: CGFloat = 13
    static let detail: CGFloat = 12
    static let footnote: CGFloat = 12
    static let caption: CGFloat = 11
    static let micro: CGFloat = 10
    static let code: CGFloat = 13
#else
    static let display: CGFloat = 30
    static let title: CGFloat = 22
    static let section: CGFloat = 18
    static let heading: CGFloat = 16
    static let body: CGFloat = 16
    static let row: CGFloat = 15
    static let detail: CGFloat = 14
    static let footnote: CGFloat = 13
    static let caption: CGFloat = 12
    static let micro: CGFloat = 11
    static let code: CGFloat = 15
#endif
}

/// The bundled typefaces: Inter for the interface and Source Code Pro for SQL, JSON, and values.
/// Both are SIL Open Font License fonts shipped unmodified in `PortSQL/Fonts` (see `OFL.txt`).
enum PortbaseFonts {
    private final class BundleToken {}

    /// Registers the bundled faces for this process once; every font helper touches it first.
    static let registration: Void = {
        let bundle = Bundle(for: BundleToken.self)
        let files = [("GoogleSans-Regular", "ttf"), ("GoogleSans-Medium", "ttf"), ("GoogleSans-SemiBold", "ttf"), ("GoogleSans-Bold", "ttf"),
                     ("GoogleSansCode", "ttf"),
                     ("Inter-Regular", "otf"), ("Inter-Medium", "otf"), ("Inter-SemiBold", "otf"), ("Inter-Bold", "otf"),
                     ("SourceCodePro-Regular", "ttf"), ("SourceCodePro-Bold", "ttf")]
        let urls = files.compactMap { bundle.url(forResource: $0.0, withExtension: $0.1) }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }()

    /// An interface font in the chosen typeface; it scales with Dynamic Type relative to `style` on iOS.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        _ = registration
        switch PortbaseInterfaceFont.current {
        case .googleSans: return Font.custom("Google Sans", size: size, relativeTo: style).weight(weight)
        case .inter: return Font.custom("Inter", size: size, relativeTo: style).weight(weight)
        case .system: return Font.system(size: scaled(size, style), weight: weight)
        case .rounded: return Font.system(size: scaled(size, style), weight: weight, design: .rounded)
        }
    }

    /// A monospaced font in the chosen code typeface.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        _ = registration
        switch PortbaseCodeFont.current {
        case .googleSansCode: return Font.custom("Google Sans Code", size: size, relativeTo: style).weight(weight)
        case .sourceCodePro: return Font.custom("Source Code Pro", size: size, relativeTo: style).weight(weight)
        case .sfMono: return Font.system(size: scaled(size, style), weight: weight, design: .monospaced)
        case .menlo: return Font.custom("Menlo", size: size, relativeTo: style).weight(weight)
        }
    }

    /// The Dynamic Type size for system fonts on iOS; the Mac uses fixed sizes.
    private static func scaled(_ size: CGFloat, _ style: Font.TextStyle) -> CGFloat {
#if canImport(UIKit)
        UIFontMetrics(forTextStyle: uiTextStyle(style)).scaledValue(for: size)
#else
        size
#endif
    }

#if canImport(UIKit)
    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
#endif

    /// The PostScript name for UIKit and AppKit text, or nil when the chosen typeface is a system design.
    private static func postScriptName(code isCode: Bool, bold: Bool, weight: CGFloat) -> String? {
        if isCode {
            switch PortbaseCodeFont.current {
            case .googleSansCode: return bold ? "GoogleSansCode-Bold" : "GoogleSansCode-Regular"
            case .sourceCodePro: return bold ? "SourceCodePro-Bold" : "SourceCodePro-Regular"
            case .menlo: return bold ? "Menlo-Bold" : "Menlo-Regular"
            case .sfMono: return nil
            }
        }
        let family: String
        switch PortbaseInterfaceFont.current {
        case .googleSans: family = "GoogleSans"
        case .inter: family = "Inter"
        case .system, .rounded: return nil
        }
        if bold || weight >= 0.4 { return family + "-Bold" }
        if weight >= 0.3 { return family + "-SemiBold" }
        if weight >= 0.2 { return family + "-Medium" }
        return family + "-Regular"
    }

#if canImport(UIKit)
    static func uiFont(_ size: CGFloat, weight: UIFont.Weight = .regular, textStyle: UIFont.TextStyle? = nil) -> UIFont {
        _ = registration
        let font = postScriptName(code: false, bold: false, weight: weight.rawValue).flatMap { UIFont(name: $0, size: size) }
            ?? systemUIFont(size, weight: weight)
        return textStyle.map { UIFontMetrics(forTextStyle: $0).scaledFont(for: font) } ?? font
    }

    static func codeFont(_ size: CGFloat, bold: Bool = false, textStyle: UIFont.TextStyle? = nil) -> UIFont {
        _ = registration
        let font = postScriptName(code: true, bold: bold, weight: 0).flatMap { UIFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return textStyle.map { UIFontMetrics(forTextStyle: $0).scaledFont(for: font) } ?? font
    }

    private static func systemUIFont(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard PortbaseInterfaceFont.current == .rounded, let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    /// Applies the interface font to navigation bars and segmented controls, which UIKit draws.
    @MainActor static func applyAppearance() {
        let navigation = UINavigationBar.appearance()
        navigation.largeTitleTextAttributes = [.font: uiFont(TypeSize.display, weight: .bold, textStyle: .largeTitle)]
        navigation.titleTextAttributes = [.font: uiFont(17, weight: .semibold, textStyle: .headline)]
        UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(TypeSize.detail, weight: .medium, textStyle: .subheadline)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(TypeSize.detail, weight: .semibold, textStyle: .subheadline)], for: .selected)
    }
#else
    static func nsFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        _ = registration
        return postScriptName(code: false, bold: false, weight: weight.rawValue).flatMap { NSFont(name: $0, size: size) }
            ?? systemNSFont(size, weight: weight)
    }

    private static func systemNSFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard PortbaseInterfaceFont.current == .rounded, let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func codeFont(_ size: CGFloat, bold: Bool = false) -> NSFont {
        _ = registration
        return postScriptName(code: true, bold: bold, weight: 0).flatMap { NSFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
#endif
}

/// Typography roles, set in Google Sans with Google Sans Code for code by default. iOS sizes scale with Dynamic Type.
extension Font {
    static var displayTitle: Font { PortbaseFonts.ui(TypeSize.display, .bold, relativeTo: .largeTitle) }
    static var pageTitle: Font { PortbaseFonts.ui(TypeSize.title, .bold, relativeTo: .title2) }
    static var sectionTitle: Font { PortbaseFonts.ui(TypeSize.section, .semibold, relativeTo: .title3) }
    static var cardTitle: Font { PortbaseFonts.ui(TypeSize.heading, .semibold, relativeTo: .headline) }
    static var bodyText: Font { PortbaseFonts.ui(TypeSize.body, relativeTo: .body) }
    static var rowTitle: Font { PortbaseFonts.ui(TypeSize.row, .medium, relativeTo: .subheadline) }
    static var rowDetail: Font { PortbaseFonts.ui(TypeSize.detail, relativeTo: .subheadline) }
    static var footnoteText: Font { PortbaseFonts.ui(TypeSize.footnote, relativeTo: .footnote) }
    static var captionText: Font { PortbaseFonts.ui(TypeSize.caption, relativeTo: .caption) }
    static var captionStrong: Font { PortbaseFonts.ui(TypeSize.caption, .semibold, relativeTo: .caption) }
    static var microText: Font { PortbaseFonts.ui(TypeSize.micro, relativeTo: .caption2) }
    static var badgeText: Font { PortbaseFonts.ui(TypeSize.micro, .semibold, relativeTo: .caption2) }
    static var codeText: Font { PortbaseFonts.mono(TypeSize.code, relativeTo: .body) }
    static var codeDetail: Font { PortbaseFonts.mono(TypeSize.detail, relativeTo: .callout) }
    static var codeCaption: Font { PortbaseFonts.mono(TypeSize.caption, relativeTo: .caption) }
    static var metricValue: Font { PortbaseFonts.ui(TypeSize.title, .semibold, relativeTo: .title3).monospacedDigit() }
    static var toolSymbol: Font { Font.system(size: TypeSize.body, weight: .semibold) }
    static var tileSymbol: Font { Font.system(size: TypeSize.section, weight: .semibold) }
    /// Symbols in empty states and onboarding.
    static var emptyStateSymbol: Font { Font.system(size: Sizes.emptyStateSymbol, weight: .regular) }
}

// MARK: - Surfaces

extension View {
    /// Liquid Glass on current systems, a translucent material on earlier releases.
    @ViewBuilder func portbaseGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    func portbaseCardSurface(radius: CGFloat = Radius.card) -> some View {
        modifier(PortbaseCardSurface(radius: radius))
    }
}

private struct PortbaseCardSurface: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(PortSQLPalette.surface, in: shape)
            .overlay { shape.strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
    }
}

extension View {
    /// The sunken track behind segmented destinations and pills.
    func portbaseSegmentTrack() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return padding(Spacing.xxs)
            .background(PortSQLPalette.sunken, in: shape)
            .overlay { shape.strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
    }

    /// The raised surface behind the selected segment or console tab.
    func portbaseSelectedSegment<S: Shape>(_ isSelected: Bool, in shape: S) -> some View {
        background {
            if isSelected {
                shape.fill(PortSQLPalette.surface)
                    .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                    .overlay { shape.stroke(PortSQLPalette.stroke, lineWidth: 0.5) }
            }
        }
    }

    func portbaseSelectedSegment(_ isSelected: Bool) -> some View {
        portbaseSelectedSegment(isSelected, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }

    /// A horizontal bar (toolbar, status line, filter row) on the panel background.
    func portbaseBar(_ height: CGFloat = Sizes.toolbar) -> some View {
        padding(.horizontal, Spacing.m)
            .frame(height: height)
            .background(PortSQLPalette.panel)
    }

    /// The inset background of search and filter fields.
    func portbaseFieldChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        return padding(.horizontal, Spacing.s)
            .frame(minHeight: Sizes.statusBar)
            .background(PortSQLPalette.sunken, in: shape)
            .overlay { shape.strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
    }
}

/// A toolbar button: regular text color (not link-tinted), comfortable padding and height, and a quiet
/// background on hover and press, so tool rows read as controls rather than hyperlinks.
struct PortbaseToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PortbaseToolbarButton(configuration: configuration)
    }
}

private struct PortbaseToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? PortSQLPalette.ink : PortSQLPalette.muted.opacity(0.55))
            .padding(.horizontal, Spacing.s)
            .frame(minHeight: Sizes.control)
            .background {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(PortSQLPalette.ink.opacity(configuration.isPressed ? 0.14 : (isHovering && isEnabled ? 0.07 : 0)))
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// A secondary button: a visible surface with an outline and regular text, in place of the system
/// bordered style, whose translucent fill nearly disappears on dark themed surfaces.
struct PortbaseSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PortbaseSecondaryButton(configuration: configuration)
    }
}

private struct PortbaseSecondaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
        configuration.label
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xxs)
            .frame(minHeight: Sizes.control)
            .background(shape.fill(PortSQLPalette.sunken))
            .background(shape.fill(PortSQLPalette.ink.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.05 : 0))))
            .overlay(shape.strokeBorder(PortSQLPalette.stroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == PortbaseSecondaryButtonStyle {
    static var portbaseSecondary: PortbaseSecondaryButtonStyle { PortbaseSecondaryButtonStyle() }
}

extension ButtonStyle where Self == PortbaseToolbarButtonStyle {
    static var portbaseToolbar: PortbaseToolbarButtonStyle { PortbaseToolbarButtonStyle() }
}

/// A divider inset to line up with row text that follows a leading icon or avatar.
struct PortbaseRowDivider: View {
    var leadingIcon: CGFloat = 0

    var body: some View {
        Divider().padding(.leading, Spacing.card + (leadingIcon > 0 ? leadingIcon + Spacing.m : 0))
    }
}

/// The workspace canvas behind cards.
struct PortbaseBackdrop: View {
    var body: some View {
        PortSQLPalette.canvasTop
    }
}

// MARK: - Termius-style primitives
//
// Sheets, tabs, choices, and primary actions share these so every screen reads the same way: one
// themed surface, a title with a close button, underline tabs, a sunken segmented track, and a single
// accent-filled primary action.

/// The main action of a screen or sheet: an accent fill with white text. Used once per surface.
struct PortbasePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PortbasePrimaryButton(configuration: configuration)
    }
}

private struct PortbasePrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
        // Keeps the surrounding text size so it matches secondary buttons beside it.
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xxs)
            .frame(minHeight: Sizes.control)
            .background(shape.fill(PortSQLPalette.accent))
            .background(shape.fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)).blendMode(.multiply))
            .overlay(shape.fill(Color.white.opacity(isHovering && isEnabled && !configuration.isPressed ? 0.08 : 0)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == PortbasePrimaryButtonStyle {
    static var portbasePrimary: PortbasePrimaryButtonStyle { PortbasePrimaryButtonStyle() }
}

/// One option of a segmented choice or tab strip.
struct PortbaseChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var systemImage: String?
    /// A count shown beside the title, such as the number of items in a tab.
    var count: Int?
    var id: Value { value }
}

/// A choice among a few options: a sunken track with the selected option raised, in place of the
/// system segmented control, whose tinted fill clashes with the themes.
struct PortbaseSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PortbaseChoice<Value>]
    /// Stretch the options to fill the available width, as on phone forms.
    var fills = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    HStack(spacing: Spacing.xxs) {
                        if let symbol = option.systemImage { Image(systemName: symbol).imageScale(.small) }
                        Text(option.title).lineLimit(1)
                    }
                    .font(.captionStrong)
                    .foregroundStyle(selected ? PortSQLPalette.ink : PortSQLPalette.muted)
                    .padding(.horizontal, Spacing.s)
                    .frame(maxWidth: fills ? .infinity : nil, minHeight: Sizes.control - 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                .fill(PortSQLPalette.tertiarySurface)
                                .shadow(color: PortSQLPalette.shadow, radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
        .fixedSize(horizontal: !fills, vertical: false)
    }
}

/// Underline tabs for switching between views of one surface, with optional counts.
struct PortbaseTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PortbaseChoice<Value>]

    var body: some View {
        HStack(spacing: Spacing.xl) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    VStack(spacing: Spacing.s) {
                        HStack(spacing: Spacing.xs) {
                            if let symbol = option.systemImage { Image(systemName: symbol).imageScale(.small) }
                            Text(option.title).font(.rowTitle)
                            if let count = option.count {
                                Text(verbatim: "\(count)").font(.captionText.monospacedDigit()).foregroundStyle(PortSQLPalette.muted)
                            }
                        }
                        .foregroundStyle(selected ? PortSQLPalette.ink : PortSQLPalette.muted)
                        Rectangle().fill(selected ? PortSQLPalette.accent : Color.clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The close button at the top trailing corner of a sheet. Escape triggers it on a keyboard.
struct PortbaseCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.toolSymbol)
                .foregroundStyle(PortSQLPalette.muted)
                .frame(width: Sizes.tool, height: Sizes.tool)
                .contentShape(Rectangle())
        }
        .buttonStyle(.portbaseToolbar)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
    }
}

/// A sheet laid out like Termius's panels: a title with a close button, content on the theme canvas,
/// and an optional footer for actions. Replaces navigation bars, which render as gray system strips
/// in Mac sheets and differ between platforms.
struct PortbaseSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    /// Runs instead of dismissing, for sheets whose presenter clears its own state.
    var onClose: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(title).font(.pageTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.m)
                PortbaseCloseButton { if let onClose { onClose() } else { dismiss() } }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.l)
            .padding(.bottom, Spacing.m)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if Footer.self != EmptyView.self {
                HStack(spacing: Spacing.s) { footer() }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .overlay(alignment: .top) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
            }
        }
        .background(PortSQLPalette.canvasTop.ignoresSafeArea())
    }
}

extension PortbaseSheet where Footer == EmptyView {
    init(_ title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, onClose: onClose, content: content, footer: { EmptyView() })
    }
}

/// A search field on a sunken inset, with a clear button, shared by lists and pickers.
struct PortbaseSearchField: View {
    var prompt: String = L10n.text("Search")
    @Binding var text: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(PortSQLPalette.muted).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .portbaseTextCapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PortSQLPalette.muted) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(.bodyText)
        .portbaseFieldChrome()
    }
}

/// A small label above a field, as in Termius's host editor.
struct PortbaseFieldLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.captionStrong).foregroundStyle(PortSQLPalette.muted)
    }
}

/// Read-only code, such as a SQL preview, in a sunken box.
struct PortbaseCodeBlock: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.codeCaption)
            .foregroundStyle(PortSQLPalette.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
    }
}

extension View {
    /// A menu drawn like the toolbar buttons around it. The Mac's borderless menu style tints its label
    /// with the accent color, which made menus look like links beside ordinary tools.
    @ViewBuilder func portbaseToolbarMenu() -> some View {
#if os(macOS)
        menuStyle(.button).buttonStyle(.portbaseToolbar).menuIndicator(.hidden).fixedSize()
#else
        menuIndicator(.hidden).fixedSize()
#endif
    }

    /// A grouped form on the sheet's themed canvas instead of the system's gray form background.
    func portbaseForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // The sheet header already provides the space above the first section.
            .contentMargins(.top, Spacing.xs, for: .scrollContent)
    }
}

// MARK: - Components

/// A rounded-square tool button that keeps a 44-point target on touch devices.
struct ToolIconChrome: ViewModifier {
    var isProminent = false
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .font(.toolSymbol)
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(isEnabled ? (tint ?? PortSQLPalette.ink) : Color.secondary.opacity(0.5)))
            .frame(width: Sizes.tool, height: Sizes.tool)
            // Flat icons, as in terminal and host-manager toolbars; only the prominent action gets a fill.
            .background {
                if isProminent {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(PortSQLPalette.accent)
                }
            }
            .contentShape(Rectangle())
    }
}

extension View {
    func toolIconChrome(prominent: Bool = false, tint: Color? = nil) -> some View { modifier(ToolIconChrome(isProminent: prominent, tint: tint)) }
}

/// A compact, tinted status label.
struct PortbaseChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(.badgeText)
        .foregroundStyle(filled ? .white : tint)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxxs)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An uppercase eyebrow heading followed by optional trailing content.
struct PortbaseSectionHeading<Trailing: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(PortSQLPalette.accent)
            }
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(PortSQLPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.s)
            trailing
        }
        // A fixed height keeps headings in neighbouring columns aligned whether or not they carry a button.
        .frame(minHeight: Sizes.control)
    }
}

extension PortbaseSectionHeading where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// A headline number with a caption and optional sparkline.
struct PortbaseMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = PortSQLPalette.accent
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.rowDetail)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.metricValue)
                .foregroundStyle(PortSQLPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title).font(.captionStrong).foregroundStyle(.secondary).lineLimit(1)
                // Reserve the footnote line so tiles in a grid keep equal heights.
                Text(footnote ?? " ").font(.microText).foregroundStyle(.tertiary).lineLimit(1)
                    .accessibilityHidden(footnote == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .portbaseCardSurface(radius: Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// The Portbase mark used in headers and empty states.
struct PortbaseLogoMark: View {
    var size: CGFloat = 32

    /// The app's own icon (the duck), so About and Settings match the Dock and Home Screen.
    private static var appIcon: Image? {
#if os(macOS)
        Image(nsImage: NSApplication.shared.applicationIconImage)
#else
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let name = (primary?["CFBundleIconFiles"] as? [String])?.last
        return name.flatMap { UIImage(named: $0) }.map { Image(uiImage: $0) }
#endif
    }

    var body: some View {
        if let icon = Self.appIcon {
            icon.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
#if os(iOS)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
#endif
                .accessibilityHidden(true)
        } else {
            fallbackMark
        }
    }

    private var fallbackMark: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(PortSQLPalette.accent)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A friendly empty state with an optional call to action.
struct PortbaseEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: systemImage)
                .font(.emptyStateSymbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xs) {
                Text(title).font(.cardTitle).multilineTextAlignment(.center)
                Text(message).font(.rowDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).lineLimit(1).padding(.horizontal, Spacing.s).frame(minHeight: Sizes.buttonContent)
                }
                .buttonStyle(.portbasePrimary)
                .padding(.top, Spacing.xxs)
            }
            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryTitle).lineLimit(1).padding(.horizontal, Spacing.s).frame(minHeight: Sizes.buttonContent)
                }
                .buttonStyle(.portbaseSecondary)
            }
        }
        .frame(maxWidth: Sizes.readableWidth)
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// A connection's avatar: its chosen symbol or initials over the engine gradient.
struct BookmarkAvatar: View {
    let profile: ConnectionProfile
    var size: CGFloat = 24
    var cornerRadius: CGFloat = 8
    var foregroundStyle: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: profile.engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                if let iconName = profile.resolvedIconName {
                    Image(systemName: iconName)
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(foregroundStyle)
                } else {
                    Text(profile.initials)
                        .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(foregroundStyle)
                        .minimumScaleFactor(0.6)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Security and access chips shared by connection lists.
struct ConnectionSecurityChips: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: Spacing.xs) {
            EnvironmentBadge(environment: profile.environment)
            if profile.isReadOnly {
                PortbaseChip(title: L10n.text("Read-only"), systemImage: "lock.fill", tint: .secondary)
            }
            if !profile.engine.isLocal {
                if profile.usesSSHTunnel {
                    PortbaseChip(title: "SSH", systemImage: "point.3.connected.trianglepath.dotted", tint: .teal)
                }
                switch profile.transportSecurityMode {
                case .systemCA, .privateCA:
                    PortbaseChip(title: "TLS", systemImage: "checkmark.shield.fill", tint: .green)
                case .preferTLS:
                    PortbaseChip(title: L10n.text(profile.engine.canNegotiateTLS ? "TLS fallback allowed" : "TLS Required (System CAs)"),
                                 systemImage: "shield.lefthalf.filled", tint: .orange)
                case .plaintext:
                    PortbaseChip(title: L10n.text("Unencrypted"), systemImage: "lock.open.fill", tint: .red)
                }
            } else {
                PortbaseChip(title: L10n.text("On this device"), systemImage: "internaldrive.fill", tint: .blue)
            }
        }
    }
}

extension ConnectionProfile {
    var displayTitle: String { name.isEmpty ? host : name }

    var endpointSummary: String {
        engine.isLocal
            ? "SQLite • " + (sqliteFileName.map { SQLiteFileStore.displayName(fileName: $0).replacingOccurrences(of: "_", with: " ") } ?? L10n.text("File unavailable"))
            : "\(engine.rawValue) • \(host):\(String(port))"
    }
}

// MARK: - Environments

/// A filled label such as PRODUCTION; nothing is shown for connections without an environment.
struct EnvironmentBadge: View {
    let environment: ConnectionEnvironment
    var compact = false

    var body: some View {
        if environment != .none {
            Text(environment.title.uppercased())
                .font(.badgeText)
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? Spacing.xxs : Spacing.xs)
                .padding(.vertical, Spacing.xxxs)
                .background(environment.color, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(L10n.format("Environment: %@", environment.title))
        }
    }
}

/// A thin colored rule across the top of a workspace connected to a labeled environment.
struct EnvironmentStripe: View {
    let environment: ConnectionEnvironment

    var body: some View {
        if environment != .none {
            environment.color
                .frame(height: 3)
                .accessibilityHidden(true)
        }
    }
}

/// Environment choices as tappable capsules.
struct EnvironmentPicker: View {
    @Binding var selection: ConnectionEnvironment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(ConnectionEnvironment.allCases) { environment in
                    let selected = selection == environment
                    Button {
                        selection = environment
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Circle()
                                .fill(environment == .none ? Color.secondary.opacity(0.4) : environment.color)
                                .frame(width: Sizes.dot, height: Sizes.dot)
                            Text(environment.title).lineLimit(1)
                        }
                        .font(.rowDetail.weight(selected ? .semibold : .regular))
                        .foregroundStyle(PortSQLPalette.ink)
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: Sizes.control)
                        .background(selected ? (environment == .none ? PortSQLPalette.sunken : environment.color.opacity(0.15)) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(selected ? (environment == .none ? PortSQLPalette.stroke : environment.color) : PortSQLPalette.stroke,
                                                   lineWidth: selected ? 1.5 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Spacing.xxxs)
        }
    }
}
