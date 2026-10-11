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

// MARK: - Layout tokens

enum PortbaseMetrics {
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let chipRadius: CGFloat = 8
#if os(macOS)
    static let cardPadding: CGFloat = 14
    static let toolSize: CGFloat = 30
#else
    static let cardPadding: CGFloat = 16
    static let toolSize: CGFloat = 44
#endif
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

    func portbaseCardSurface(radius: CGFloat = PortbaseMetrics.cardRadius) -> some View {
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
            .font(.system(size: PortbaseMetrics.toolSize > 30 ? 16 : 12, weight: .semibold))
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(isEnabled ? (tint ?? PortSQLPalette.ink) : Color.secondary.opacity(0.5)))
            .frame(width: PortbaseMetrics.toolSize, height: PortbaseMetrics.toolSize)
            .background {
                RoundedRectangle(cornerRadius: PortbaseMetrics.controlRadius, style: .continuous)
                    .fill(isProminent ? AnyShapeStyle(PortSQLPalette.accent) : AnyShapeStyle(PortSQLPalette.sunken))
            }
            .overlay {
                RoundedRectangle(cornerRadius: PortbaseMetrics.controlRadius, style: .continuous)
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
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(filled ? .white : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(PortSQLPalette.accent)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(PortSQLPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
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
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(PortSQLPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                // Reserve the footnote line so tiles in a grid keep equal heights.
                Text(footnote ?? " ").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .accessibilityHidden(footnote == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .portbaseCardSurface(radius: 12)
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
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            if let secondaryTitle, let secondaryAction {
                Button(action: secondaryAction) {
                    Text(secondaryTitle).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 32)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 420)
        .padding(24)
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
        HStack(spacing: 6) {
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
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 2 : 3)
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
            HStack(spacing: 8) {
                ForEach(ConnectionEnvironment.allCases) { environment in
                    let selected = selection == environment
                    Button {
                        selection = environment
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(environment == .none ? Color.secondary.opacity(0.4) : environment.color)
                                .frame(width: 8, height: 8)
                            Text(environment.title).lineLimit(1)
                        }
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(PortSQLPalette.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
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
            .padding(.vertical, 2)
        }
    }
}
