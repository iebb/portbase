import Combine
import Foundation

/// Tables pinned to the top of the table list, per connection and database, on this device.
@MainActor
final class PinnedTableStore: ObservableObject {
    static let shared = PinnedTableStore()
    static let storageKey = "Portbase.pinnedTables"

    @Published private(set) var pins: [String: [String]]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    }

    static func scope(profileID: UUID?, database: String?) -> String {
        (profileID?.uuidString ?? "none") + "/" + (database ?? "")
    }

    func isPinned(_ table: String, in scope: String) -> Bool {
        pins[scope]?.contains(table) == true
    }

    func toggle(_ table: String, in scope: String) {
        var list = pins[scope] ?? []
        if let index = list.firstIndex(of: table) { list.remove(at: index) } else { list.append(table) }
        pins[scope] = list.isEmpty ? nil : list
        defaults.set(pins, forKey: Self.storageKey)
    }

    /// Splits tables into pinned (in pin order) and the rest (in their original order).
    func partition(_ tables: [SchemaTableDescriptor], in scope: String) -> (pinned: [SchemaTableDescriptor], others: [SchemaTableDescriptor]) {
        let order = pins[scope] ?? []
        guard !order.isEmpty else { return ([], tables) }
        let pinned = order.compactMap { name in tables.first { $0.displayName == name } }
        return (pinned, tables.filter { !order.contains($0.displayName) })
    }

    /// Removes pins for a deleted connection.
    func removeAll(for profileID: UUID) {
        pins = pins.filter { !$0.key.hasPrefix(profileID.uuidString + "/") }
        defaults.set(pins, forKey: Self.storageKey)
    }
}
