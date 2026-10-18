import Foundation

/// The tabs inside one connection tab, like an editor's: the console, which is always there, a tab per
/// open table, any number of Ask AI chats, and the Structure, Charts, and key browser pages.
struct SessionTabSet: Equatable {
    struct Tab: Identifiable, Hashable {
        enum Kind: Hashable {
            case console
            /// A table's rows, by its schema-qualified name.
            case table(String)
            /// The key and index browser of engines without tables, such as Redis and Elasticsearch.
            case explorer
            case structure
            case chat
            case charts

            /// Only tables and chats can be open more than once.
            var isSingle: Bool {
                switch self {
                case .table, .chat: false
                default: true
                }
            }
        }

        let id: UUID
        var kind: Kind
        /// A table opened with a single click, which the next table opened replaces until it's kept.
        var isPreview = false

        init(id: UUID = UUID(), kind: Kind, isPreview: Bool = false) {
            self.id = id
            self.kind = kind
            self.isPreview = isPreview
        }
    }

    private(set) var tabs: [Tab]
    private(set) var selectedID: UUID

    init() {
        let console = Tab(kind: .console)
        tabs = [console]
        selectedID = console.id
    }

    var selected: Tab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    mutating func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Shows a table's tab, opening it when it isn't open. Unless it's kept, a new tab takes the place
    /// of the preview tab, so browsing tables one after another doesn't pile up tabs.
    mutating func openTable(_ name: String, keeps: Bool = false) {
        if let index = tabs.firstIndex(where: { $0.kind == .table(name) }) {
            if keeps { tabs[index].isPreview = false }
            selectedID = tabs[index].id
            return
        }
        let tab = Tab(kind: .table(name), isPreview: !keeps)
        if let preview = tabs.firstIndex(where: \.isPreview) {
            tabs[preview] = tab
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
    }

    /// Shows the tab of a kind that's open once, opening it when needed.
    mutating func show(_ kind: Tab.Kind) {
        precondition(kind.isSingle, "Tables and chats are opened with openTable and addChat")
        if let existing = tabs.first(where: { $0.kind == kind }) {
            selectedID = existing.id
        } else {
            let tab = Tab(kind: kind)
            tabs.append(tab)
            selectedID = tab.id
        }
    }

    @discardableResult
    mutating func addChat() -> UUID {
        let tab = Tab(kind: .chat)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    /// Shows the chat used last, starting one when there's none.
    mutating func showChat() {
        if selected.kind == .chat { return }
        if let chat = tabs.last(where: { $0.kind == .chat }) { selectedID = chat.id } else { addChat() }
    }

    var chatIDs: [UUID] { tabs.filter { $0.kind == .chat }.map(\.id) }

    mutating func keep(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPreview = false
    }

    func canClose(_ id: UUID) -> Bool { tabs.first { $0.id == id }.map { $0.kind != .console } ?? false }

    /// Closes a tab and selects its right neighbor, or its left one at the end. The console stays.
    mutating func close(_ id: UUID) {
        guard canClose(id), let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
    }

    mutating func closeOthers(than id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id != id && $0.kind != .console }
        selectedID = id
    }

    /// Closes the table tabs, which belong to the schema of the database they were opened in.
    mutating func closeTables() {
        tabs.removeAll { if case .table = $0.kind { return true }; return false }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs[0].id }
    }
}
