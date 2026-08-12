import Foundation

enum PremiumFeature: String, CaseIterable, Identifiable {
    case unlimitedBookmarks
    case advancedCharts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimitedBookmarks:
            L10n.text("Unlimited bookmarks")
        case .advancedCharts:
            L10n.text("Advanced chart styles")
        }
    }

    var subtitle: String {
        switch self {
        case .unlimitedBookmarks:
            L10n.text("Keep as many production, staging, and personal database profiles as you need.")
        case .advancedCharts:
            L10n.text("Unlock line and area charts for trend analysis beyond the default bar view.")
        }
    }

    var symbolName: String {
        switch self {
        case .unlimitedBookmarks:
            "bookmark.circle.fill"
        case .advancedCharts:
            "chart.line.uptrend.xyaxis.circle.fill"
        }
    }
}

enum PremiumPolicy {
    static let freeBookmarkLimit = 3

    static func canCreateBookmark(existingCount: Int, hasPro: Bool) -> Bool {
        hasPro || existingCount < freeBookmarkLimit
    }
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
