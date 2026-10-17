import Combine
import Foundation

/// Recently applied Explorer filters and sorts, per connection, database, and table, on this device.
/// Like query history, clauses can contain values, so they stay local and never sync.
@MainActor
final class ClauseHistoryStore: ObservableObject {
    enum Kind: String { case filter, sort }

    static let shared = ClauseHistoryStore()
    static let storageKey = "Portbase.clauseHistory"
    static let limit = 15

    @Published private(set) var entries: [String: [String]]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    }

    static func scope(profileID: UUID?, database: String?, table: String) -> String {
        (profileID?.uuidString ?? "none") + "/" + (database ?? "") + "/" + table
    }

    private static func key(_ kind: Kind, _ scope: String) -> String { kind.rawValue + "|" + scope }

    /// Most recent first.
    func history(_ kind: Kind, in scope: String) -> [String] {
        entries[Self.key(kind, scope)] ?? []
    }

    /// Moves a clause to the front, ignoring empty clauses and keeping at most `limit`.
    func record(_ clause: String, kind: Kind, in scope: String) {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = history(kind, in: scope).filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        entries[Self.key(kind, scope)] = Array(list.prefix(Self.limit))
        defaults.set(entries, forKey: Self.storageKey)
    }

    func clear(_ kind: Kind, in scope: String) {
        entries[Self.key(kind, scope)] = nil
        defaults.set(entries, forKey: Self.storageKey)
    }

    /// Removes history for a deleted connection.
    func removeAll(for profileID: UUID) {
        entries = entries.filter { !$0.key.contains("|" + profileID.uuidString + "/") }
        defaults.set(entries, forKey: Self.storageKey)
    }
}
