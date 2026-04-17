import Foundation

enum PremiumFeature: String, CaseIterable, Identifiable {
    case unlimitedBookmarks
    case advancedCharts
    case savedWorkspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimitedBookmarks:
            "Unlimited bookmarks"
        case .advancedCharts:
            "Advanced chart styles"
        case .savedWorkspaces:
            "Saved workspaces"
        }
    }

    var subtitle: String {
        switch self {
        case .unlimitedBookmarks:
            "Keep as many production, staging, and personal database profiles as you need."
        case .advancedCharts:
            "Unlock line and area charts for trend analysis beyond the default bar view."
        case .savedWorkspaces:
            "Reserved for future query collections, pinned snippets, and dashboard presets."
        }
    }

    var symbolName: String {
        switch self {
        case .unlimitedBookmarks:
            "bookmark.circle.fill"
        case .advancedCharts:
            "chart.line.uptrend.xyaxis.circle.fill"
        case .savedWorkspaces:
            "square.stack.3d.up.fill"
        }
    }
}

enum PremiumChartStyle: String, CaseIterable, Identifiable {
    case bar
    case line
    case area

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var requiresPro: Bool {
        switch self {
        case .bar: false
        case .line, .area: true
        }
    }
}

enum PremiumPolicy {
    static let freeBookmarkLimit = 3
}

struct PurchaseCatalog {
    static let proMonthly = "ad.neko.portsql.pro.monthly"
    static let proYearly = "ad.neko.portsql.pro.yearly"
    static let proLifetime = "ad.neko.portsql.pro.lifetime"

    static let productIDs = [
        proMonthly,
        proYearly,
        proLifetime
    ]

    static func sortIndex(for productID: String) -> Int {
        switch productID {
        case proMonthly: 0
        case proYearly: 1
        case proLifetime: 2
        default: 99
        }
    }
}
