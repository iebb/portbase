import Combine
import Foundation

struct ConsoleDraft: Identifiable, Codable {
    var id = UUID()
    var title = L10n.text("Console")
    var bookmarkID: UUID?
    var database = ""
    var query = ""
    var cursor = 0
    var mongo = MongoQueryDraft()
    var closedAt: Date?
    var boundQuery: BoundQuery?
    /// Set once the user names the console; until then tabs show its connection's name.
    /// Optional so archives written before it existed still decode.
    var hasCustomTitle: Bool?
}

@MainActor
final class QueryConsole: Identifiable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    let workspace: WorkspaceViewModel

    init(draft: ConsoleDraft) {
        id = draft.id
        title = draft.title
        hasCustomTitle = draft.hasCustomTitle ?? false
        workspace = WorkspaceViewModel()
        workspace.selectedBookmarkID = draft.bookmarkID
        workspace.selectedDatabaseName = draft.database
        workspace.queryText = draft.query
        workspace.queryCursorOffset = min(draft.cursor, draft.query.utf16.count)
        workspace.mongoDraft = draft.mongo
        workspace.activeBoundQuery = draft.boundQuery
    }

    var draft: ConsoleDraft {
        ConsoleDraft(id: id, title: title, bookmarkID: workspace.selectedBookmarkID,
                     database: workspace.selectedDatabaseName, query: workspace.queryText,
                     cursor: workspace.queryCursorOffset, mongo: workspace.mongoDraft,
                     boundQuery: workspace.activeBoundQuery?.sql == workspace.queryText ? workspace.activeBoundQuery : nil,
                     hasCustomTitle: hasCustomTitle ? true : nil)
    }
}

@MainActor
final class ConsoleStore: ObservableObject {
    private struct Archive: Codable {
        var selectedID: UUID
        var consoles: [ConsoleDraft]
        var closed: [ConsoleDraft]
    }
    @Published private(set) var consoles: [QueryConsole]
    @Published var selectedID: UUID
    @Published private(set) var closed: [ConsoleDraft] = []
    @Published private(set) var storageError: String?
    private let url: URL
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?
    private weak var bookmarks: BookmarkStore?
    private weak var library: WorkspaceLibraryStore?
    private var canSave = true

    init(directory: URL = WorkspaceFileStore.directory) {
        url = directory.appendingPathComponent("consoles.json")
        let initial = QueryConsole(draft: ConsoleDraft())
        consoles = [initial]
        selectedID = initial.id
        do {
            if let archive = try WorkspaceFileStore.read(Archive.self, from: url), !archive.consoles.isEmpty {
                consoles = archive.consoles.map(QueryConsole.init)
                selectedID = consoles.contains(where: { $0.id == archive.selectedID }) ? archive.selectedID : consoles[0].id
                closed = archive.closed
            }
        } catch {
            canSave = false
            storageError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
        }
    }

    var active: QueryConsole { consoles.first(where: { $0.id == selectedID }) ?? consoles[0] }

    func configure(bookmarks: BookmarkStore, library: WorkspaceLibraryStore) {
        self.bookmarks = bookmarks; self.library = library
        for console in consoles { configure(console) }
    }

    private func configure(_ console: QueryConsole) {
        guard let bookmarks, let library else { return }
        console.workspace.configure(bookmarkStore: bookmarks, libraryStore: library)
        if subscriptions[console.id] == nil {
            subscriptions[console.id] = console.workspace.objectWillChange.sink { [weak self] _ in
                self?.scheduleSave()
            }
        }
    }

    func select(_ id: UUID) { selectedID = id; save() }

    func add(restoring draft: ConsoleDraft? = nil) {
        var next = draft ?? ConsoleDraft(bookmarkID: active.workspace.selectedBookmarkID,
                                         database: active.workspace.selectedDatabaseName)
        next.closedAt = nil
        if draft == nil { next.title = L10n.format("Console %d", consoles.count + 1); next.hasCustomTitle = nil }
        let console = QueryConsole(draft: next)
        consoles.append(console); configure(console); selectedID = console.id
        closed.removeAll { $0.id == console.id }
        save()
    }

    func rename(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        objectWillChange.send()
        if let console = consoles.first(where: { $0.id == id }) {
            console.title = trimmed
            console.hasCustomTitle = true
        }
        save()
    }

    func close(_ id: UUID, rollback: Bool = false) {
        guard let console = consoles.first(where: { $0.id == id }) else { return }
        guard !console.workspace.hasOpenTransaction || rollback else { return }
        console.workspace.disconnectConsole()
        var draft = console.draft; draft.closedAt = .now
        closed.removeAll { $0.id == id }; closed.insert(draft, at: 0)
        subscriptions.removeValue(forKey: id)
        consoles.removeAll { $0.id == id }
        if consoles.isEmpty {
            let fresh = QueryConsole(draft: ConsoleDraft())
            consoles = [fresh]; configure(fresh)
        }
        if selectedID == id { selectedID = consoles[0].id }
        save()
    }

    func suspend() {
        save()
        for console in consoles {
            if console.workspace.hasOpenTransaction {
                console.workspace.errorMessage = L10n.text("The session closed in the background. Its pending transaction was not committed.")
            }
            console.workspace.disconnectConsole()
        }
    }

    func deleteClosed(_ id: UUID) { closed.removeAll { $0.id == id }; save() }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard canSave else { return }
        do {
            let archive = Archive(selectedID: selectedID, consoles: consoles.map(\.draft), closed: closed)
            try WorkspaceFileStore.write(JSONEncoder().encode(archive), to: url)
            storageError = nil
        } catch { storageError = L10n.text("Saved work could not be written. Free some device storage and try again.") }
    }
}
