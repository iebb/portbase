import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Preferences

enum PortbaseAccent: String, CaseIterable, Identifiable {
    case indigo, ocean, emerald, sunset, rose, graphite

    static let storageKey = "Portbase.accent"
    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .indigo: [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)]
        case .ocean: [Color(hex: 0x0EA5E9), Color(hex: 0x2563EB)]
        case .emerald: [Color(hex: 0x10B981), Color(hex: 0x0D9488)]
        case .sunset: [Color(hex: 0xF97316), Color(hex: 0xE11D48)]
        case .rose: [Color(hex: 0xEC4899), Color(hex: 0xA855F7)]
        case .graphite: [Color(hex: 0x64748B), Color(hex: 0x334155)]
        }
    }

    static var current: PortbaseAccent {
        UserDefaults.standard.string(forKey: storageKey).flatMap(PortbaseAccent.init(rawValue:)) ?? .indigo
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
    @AppStorage(PortbaseAccent.storageKey) private var accent = PortbaseAccent.indigo.rawValue
    @AppStorage(PortbaseAppearance.storageKey) private var appearance = PortbaseAppearance.system.rawValue

    func body(content: Content) -> some View {
        let accentChoice = PortbaseAccent(rawValue: accent) ?? .indigo
        content
            // Palette tokens read the stored accent, so a new identity redraws views that cached it.
            .id(accentChoice)
            .tint(accentChoice.color)
            .preferredColorScheme((PortbaseAppearance(rawValue: appearance) ?? .system).colorScheme)
    }
}

extension View {
    func portbaseTheme() -> some View { modifier(PortbaseThemeModifier()) }
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
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let chip: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let hero: CGFloat = 18
#else
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let chip: CGFloat = 8
    static let control: CGFloat = 12
    static let card: CGFloat = 16
    static let hero: CGFloat = 22
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

#if os(macOS)
/// Point sizes behind the Mac typography roles, shared with AppKit views such as the result grid
/// and query editor so native and SwiftUI text match.
enum TypeSize {
    static let display: CGFloat = 26
    static let title: CGFloat = 20
    static let section: CGFloat = 15
    static let body: CGFloat = 13
    static let detail: CGFloat = 12
    static let caption: CGFloat = 11
    static let micro: CGFloat = 10
}
#endif

/// Typography roles. iOS uses Dynamic Type text styles; the Mac uses explicit point sizes so
/// shared views read at desktop sizes instead of the Mac's smaller text-style defaults.
extension Font {
#if os(macOS)
    static let displayTitle = Font.system(size: TypeSize.display, weight: .bold)
    static let pageTitle = Font.system(size: TypeSize.title, weight: .bold)
    static let sectionTitle = Font.system(size: TypeSize.section, weight: .semibold)
    static let cardTitle = Font.system(size: TypeSize.body, weight: .semibold)
    static let bodyText = Font.system(size: TypeSize.body)
    static let rowTitle = Font.system(size: TypeSize.body, weight: .medium)
    static let rowDetail = Font.system(size: TypeSize.detail)
    static let footnoteText = Font.system(size: TypeSize.detail)
    static let captionText = Font.system(size: TypeSize.caption)
    static let captionStrong = Font.system(size: TypeSize.caption, weight: .semibold)
    static let microText = Font.system(size: TypeSize.micro)
    static let badgeText = Font.system(size: TypeSize.micro, weight: .semibold)
    static let codeText = Font.system(size: TypeSize.body, design: .monospaced)
    static let codeDetail = Font.system(size: TypeSize.detail, design: .monospaced)
    static let codeCaption = Font.system(size: TypeSize.caption, design: .monospaced)
    static let metricValue = Font.system(size: TypeSize.title, weight: .semibold).monospacedDigit()
    static let toolSymbol = Font.system(size: TypeSize.body, weight: .semibold)
    static let tileSymbol = Font.system(size: TypeSize.section, weight: .semibold)
#else
    static let displayTitle = Font.largeTitle.weight(.bold)
    static let pageTitle = Font.title2.weight(.bold)
    static let sectionTitle = Font.title3.weight(.semibold)
    static let cardTitle = Font.headline
    static let bodyText = Font.body
    static let rowTitle = Font.subheadline.weight(.semibold)
    static let rowDetail = Font.subheadline
    static let footnoteText = Font.footnote
    static let captionText = Font.caption
    static let captionStrong = Font.caption.weight(.semibold)
    static let microText = Font.caption2
    static let badgeText = Font.caption2.weight(.semibold)
    static let codeText = Font.system(.body, design: .monospaced)
    static let codeDetail = Font.system(.callout, design: .monospaced)
    static let codeCaption = Font.system(.caption, design: .monospaced)
    static let metricValue = Font.title3.weight(.semibold).monospacedDigit()
    static let toolSymbol = Font.system(size: 16, weight: .semibold)
    static let tileSymbol = Font.system(size: 17, weight: .semibold)
#endif
    /// Symbols in empty states and onboarding.
    static let emptyStateSymbol = Font.system(size: Sizes.emptyStateSymbol, weight: .regular)
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
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isProminent ? AnyShapeStyle(PortSQLPalette.accent) : AnyShapeStyle(PortSQLPalette.sunken))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(isProminent ? Color.clear : PortSQLPalette.stroke, lineWidth: 1)
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
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)), in: Capsule())
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

    var body: some View {
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
                .buttonStyle(.borderedProminent)
                .padding(.top, Spacing.xxs)
            }
            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryTitle).lineLimit(1).padding(.horizontal, Spacing.s).frame(minHeight: Sizes.buttonContent)
                }
                .buttonStyle(.bordered)
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
                .background(environment.color, in: Capsule())
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
                        .background(selected ? (environment == .none ? PortSQLPalette.sunken : environment.color.opacity(0.15)) : Color.clear, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(selected ? (environment == .none ? PortSQLPalette.stroke : environment.color) : PortSQLPalette.stroke,
                                                   lineWidth: selected ? 1.5 : 1)
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Spacing.xxxs)
        }
    }
}
