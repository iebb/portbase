import SwiftUI

/// Places the shell can navigate to from Home and the command palette.
enum PortbaseDestination: Hashable {
    case home, explorer, console, charts, servers, settings, library
}

struct CommandPaletteItem: Identifiable {
    enum Group: Int, CaseIterable {
        case actions, navigation, connections, databases, tables, savedQueries, history

        var title: String {
            switch self {
            case .actions: L10n.text("Actions")
            case .navigation: L10n.text("Go To")
            case .connections: L10n.text("Connections")
            case .databases: L10n.text("Databases")
            case .tables: L10n.text("Tables")
            case .savedQueries: L10n.text("Saved Queries")
            case .history: L10n.text("History")
            }
        }
    }

    let id: String
    let group: Group
    let title: String
    var subtitle: String?
    let systemImage: String
    var shortcut: String?
    var isEnabled = true
    var keywords = ""
    let perform: () -> Void
}

enum CommandPaletteSearch {
    /// Scores a candidate against a query: prefix > word prefix > substring > in-order characters.
    static func score(_ candidate: String, query: String) -> Int? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        let haystack = candidate.lowercased()
        if haystack.hasPrefix(needle) { return 1_000 - haystack.count }
        if haystack.contains(" " + needle) || haystack.contains("." + needle) || haystack.contains("_" + needle) { return 800 - haystack.count }
        if let range = haystack.range(of: needle) { return 600 - haystack.distance(from: haystack.startIndex, to: range.lowerBound) }
        var index = haystack.startIndex
        var gaps = 0
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            gaps += haystack.distance(from: index, to: found)
            index = haystack.index(after: found)
        }
        return max(1, 300 - gaps * 4)
    }
}

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    let onNavigate: (PortbaseDestination) -> Void
    var onCreateSQLite: () -> Void = {}

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] {
        let items = allItems.filter(\.isEnabled)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return items.filter { [.actions, .navigation, .connections].contains($0.group) }
                + items.filter { $0.group == .history }.prefix(5)
        }
        return items
            .compactMap { item -> (CommandPaletteItem, Int)? in
                let fields = [item.title, item.subtitle ?? "", item.keywords]
                guard let best = fields.compactMap({ CommandPaletteSearch.score($0, query: query) }).max() else { return nil }
                return (item, best)
            }
            .sorted { $0.1 == $1.1 ? $0.0.group.rawValue < $1.0.group.rawValue : $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .font(.sectionTitle)
                    .foregroundStyle(PortSQLPalette.accent)
                TextField("Search actions, tables, and queries", text: $query)
                    .textFieldStyle(.plain)
                    .font(.sectionTitle)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .portbaseTextCapitalization(.never)
                    .onSubmit { run(results.indices.contains(highlighted) ? results[highlighted] : nil) }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(minWidth: Sizes.control, minHeight: Sizes.control)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
#if !os(macOS)
                Button("Done") { dismiss() }
                    .font(.bodyText.weight(.semibold))
                    .frame(minHeight: Sizes.touchTarget)
#endif
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.m)

            Divider()

            if results.isEmpty {
                PortbaseEmptyState(title: L10n.text("No matches"),
                                   message: L10n.text("Try a table name, a saved query, or an action such as Format."),
                                   systemImage: "sparkle.magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.xxxs, pinnedViews: [.sectionHeaders]) {
                            if isSearching {
                                // Ranked results keep the best match first so Return opens it.
                                Section {
                                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                        row(item, isHighlighted: index == highlighted, showsGroup: true)
                                            .id(item.id)
                                    }
                                } header: {
                                    sectionHeader(L10n.text("Best Matches"))
                                }
                            } else {
                                ForEach(CommandPaletteItem.Group.allCases, id: \.self) { group in
                                    let members = results.enumerated().filter { $0.element.group == group }
                                    if !members.isEmpty {
                                        Section {
                                            ForEach(members, id: \.element.id) { index, item in
                                                row(item, isHighlighted: index == highlighted)
                                                    .id(item.id)
                                            }
                                        } header: {
                                            sectionHeader(group.title)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(Spacing.s)
                    }
                    .onChange(of: highlighted) { _, value in
                        guard results.indices.contains(value) else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(results[value].id, anchor: .center) }
                    }
                }
            }

#if os(macOS)
            Divider()
            HStack(spacing: Spacing.l) {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                Label("Open", systemImage: "return")
                Label("Close", systemImage: "escape")
                Spacer()
            }
            .font(.captionText)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.l)
            .frame(height: Sizes.statusBar)
#endif
        }
        .background(PortSQLPalette.surface)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
#if os(macOS)
        .frame(width: 640, height: 480)
#else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
#endif
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.badgeText)
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xxs)
            .background(PortSQLPalette.surface)
    }

    private func row(_ item: CommandPaletteItem, isHighlighted: Bool, showsGroup: Bool = false) -> some View {
        Button { run(item) } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: item.systemImage)
                    .font(.bodyText)
                    .foregroundStyle(isHighlighted ? PortSQLPalette.accent : .secondary)
                    .frame(width: Sizes.symbolColumn)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(item.title).font(.bodyText.weight(.medium)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.s)
                if showsGroup {
                    Text(item.group.title)
                        .font(.badgeText)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let shortcut = item.shortcut {
                    Text(verbatim: shortcut)
                        .font(.codeCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                        .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                }
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.control + 10)
            .background(isHighlighted ? PortSQLPalette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(item.subtitle ?? "")
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    private func run(_ item: CommandPaletteItem?) {
        guard let item else { return }
        dismiss()
        // Let the sheet finish dismissing before presenting or switching anything else.
        DispatchQueue.main.async { item.perform() }
    }

    // MARK: Catalog

    private var allItems: [CommandPaletteItem] {
        let hasConnection = workspace.selectedBookmark != nil
        let hasQuery = !workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(id: "run", group: .actions, title: L10n.text("Run Query"), subtitle: workspace.selectedBookmark?.displayTitle,
                               systemImage: "play.fill", shortcut: "⌘↩", isEnabled: hasConnection && hasQuery && !workspace.isRunning) {
                onNavigate(.console); workspace.runQuery()
            },
            CommandPaletteItem(id: "run-all", group: .actions, title: L10n.text("Run All"), systemImage: "play.rectangle.fill", shortcut: "⇧⌘↩",
                               isEnabled: hasConnection && hasQuery && workspace.isSQLDatabase && !workspace.isRunning) {
                onNavigate(.console); workspace.runQuery(entireBuffer: true)
            },
            CommandPaletteItem(id: "cancel", group: .actions, title: L10n.text("Cancel Query"), systemImage: "stop.fill", shortcut: "⌘.",
                               isEnabled: workspace.isRunning) { workspace.cancelQuery() },
            CommandPaletteItem(id: "format", group: .actions, title: L10n.text("Format Query"), systemImage: "text.alignleft",
                               isEnabled: hasQuery, keywords: "beautify pretty") { workspace.formatQuery() },
            CommandPaletteItem(id: "explain", group: .actions, title: L10n.text("Explain"), systemImage: "waveform.path.ecg",
                               isEnabled: hasConnection && hasQuery && (workspace.isSQLDatabase || workspace.isDocumentDatabase), keywords: "plan") {
                onNavigate(.console); workspace.runExplain()
            },
            CommandPaletteItem(id: "save", group: .actions, title: L10n.text("Save Query"), systemImage: "bookmark.fill", shortcut: "⇧⌘S",
                               isEnabled: hasQuery, keywords: "snippet") { workspace.saveSnippet() },
            CommandPaletteItem(id: "new-console", group: .actions, title: L10n.text("New Console"), systemImage: "plus.rectangle.on.rectangle", shortcut: "⌘T",
                               keywords: "tab") { consoles.add(); onNavigate(.console) },
            CommandPaletteItem(id: "add-connection", group: .actions, title: L10n.text("Add Connection"), systemImage: "plus.circle.fill",
                               keywords: "server bookmark") { workspace.createBookmark() },
            CommandPaletteItem(id: "import-string", group: .actions, title: L10n.text("Import Connection String"), systemImage: "link",
                               keywords: "url uri dsn jdbc postgres mysql redis mongodb") { workspace.createBookmark() },
            CommandPaletteItem(id: "new-sqlite", group: .actions, title: L10n.text("New SQLite Database"), systemImage: "internaldrive.fill",
                               keywords: "local file create") { onCreateSQLite() },
            CommandPaletteItem(id: "refresh-schema", group: .actions, title: L10n.text("Refresh Schema"), systemImage: "arrow.clockwise",
                               isEnabled: hasConnection && workspace.activeDatabaseName != nil && !workspace.isLoadingSchema, keywords: "reload tables") {
                workspace.refreshSchemaCatalog()
            },
            CommandPaletteItem(id: "library", group: .actions, title: L10n.text("Query Library"), systemImage: "books.vertical.fill",
                               keywords: "history saved") { onNavigate(.library) },
        ]

        let destinations: [(PortbaseDestination, String, String)] = [
            (.home, L10n.text("Home"), "house.fill"),
            (.explorer, L10n.text("Explorer"), "square.stack.3d.up.fill"),
            (.console, L10n.text("Console"), "terminal.fill"),
            (.charts, L10n.text("Charts"), "chart.bar.xaxis"),
            (.servers, L10n.text("Servers"), "server.rack"),
            (.settings, L10n.text("Settings"), "gearshape.fill"),
        ]
        items += destinations.map { destination, title, symbol in
            CommandPaletteItem(id: "go-\(title)", group: .navigation, title: title, systemImage: symbol) { onNavigate(destination) }
        }

        items += bookmarks.bookmarks.map { profile in
            CommandPaletteItem(id: "connection-\(profile.id)", group: .connections, title: profile.displayTitle, subtitle: profile.endpointSummary,
                               systemImage: profile.engine.symbolName, keywords: profile.engine.rawValue + " " + profile.notes) {
                if workspace.selectedBookmarkID != profile.id { workspace.selectBookmark(profile.id) }
                onNavigate(.console)
            }
        }

        if hasConnection {
            items += workspace.availableDatabases.map { database in
                CommandPaletteItem(id: "database-\(database)", group: .databases, title: database,
                                   subtitle: workspace.activeDatabaseName == database ? L10n.text("Current database") : workspace.selectedBookmark?.displayTitle,
                                   systemImage: "externaldrive.fill") { workspace.selectDatabase(database) }
            }
            items += workspace.schemaCatalog.map { table in
                CommandPaletteItem(id: "table-\(table.displayName)", group: .tables, title: table.displayName,
                                   subtitle: L10n.plural("column_count_short", count: table.columns.count),
                                   systemImage: workspace.isDocumentDatabase ? "doc.on.doc.fill" : (table.objectKind?.symbol ?? "tablecells"),
                                   keywords: table.columns.map(\.name).joined(separator: " ")) {
                    workspace.selectExplorerTable(table)
                    onNavigate(.explorer)
                }
            }
        }

        items += library.snippets.map { snippet in
            CommandPaletteItem(id: "snippet-\(snippet.id)", group: .savedQueries, title: snippet.title,
                               subtitle: snippet.sql.replacingOccurrences(of: "\n", with: " "), systemImage: "bookmark.fill",
                               keywords: snippet.note) {
                if workspace.apply(snippet: snippet) { onNavigate(.console) }
            }
        }
        items += library.history.prefix(30).map { entry in
            CommandPaletteItem(id: "history-\(entry.id)", group: .history, title: entry.title,
                               subtitle: [entry.connectionName, entry.database].compactMap { $0 }.joined(separator: " · "),
                               systemImage: entry.outcome == .failed ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath",
                               keywords: entry.sql) {
                if workspace.apply(history: entry) { onNavigate(.console) }
            }
        }
        return items
    }
}
