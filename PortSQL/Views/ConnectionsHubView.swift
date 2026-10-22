import SwiftUI

/// Opens a connection in its own workspace tab, as the Mac does. Where it's absent (iOS), choosing a
/// connection switches the single workspace in place. The closure runs on the tab's workspace.
struct ConnectionSessionOpener {
    let open: (_ profileID: UUID, _ then: ((WorkspaceViewModel) -> Void)?) -> Void

    func open(_ profileID: UUID) { open(profileID, nil) }
}

extension EnvironmentValues {
    @Entry var connectionSessionOpener: ConnectionSessionOpener? = nil
}

/// The connection hub: a quick-connect bar, folders, a grid of connection cards, and,
/// on wide layouts, an inspector for the selected connection.
struct ConnectionsHubView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
#endif
    /// Opens the console for the selected connection; the hub hides console actions when nil.
    var onOpenConsole: (() -> Void)?
    var onCreateSQLite: () -> Void
    var onDelete: (ConnectionProfile) -> Void

    @State private var query = ""
    /// The folder whose connections are shown; nil shows every connection.
    @State private var folderFilter: UUID?
    @State private var environmentFilter: ConnectionEnvironment?
    @State private var namingFolder: FolderNaming?
    @State private var folderName = ""
    @State private var deletingFolder: ConnectionFolder?
    @State private var engineFilter: DatabaseEngine?
    @State private var colorFilter: ConnectionColor?
    @State private var onlyReadOnly = false
    @State private var importError: String?
    @Environment(\.connectionSessionOpener) private var sessionOpener
    /// The connection shown in the inspector when connections open in tabs; clicking a card inspects it.
    @State private var inspectedID: UUID?

    private var inspectedProfile: ConnectionProfile? {
        guard sessionOpener != nil else { return workspace.selectedBookmark }
        return inspectedID.flatMap { bookmarks.bookmark(with: $0) } ?? workspace.selectedBookmark ?? bookmarks.bookmarks.first
    }

    private var showsInspector: Bool {
#if os(iOS)
        sizeClass == .regular
#else
        true
#endif
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    quickConnectBar
                    SyncConflictBanner()
                    if bookmarks.bookmarks.isEmpty {
                        PortbaseEmptyState(
                            title: L10n.text("No servers saved"),
                            systemImage: "server.rack"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xxl)
                    } else {
                        // No empty Folders heading until there's a folder; New Folder is in the list's menu too.
                        if !bookmarks.folders.isEmpty { foldersSection }
                        connectionsSection
                    }
                    Label(ConnectionSecretLocation.serverListNote, systemImage: "icloud")
                        .font(.footnoteText)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.page)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if showsInspector, let profile = inspectedProfile {
                Divider().ignoresSafeArea()
                if let sessionOpener {
                    ConnectionInspector(profile: profile, onOpenConsole: { sessionOpener.open(profile.id) }, onDelete: onDelete,
                                        onApplyHistory: { entry in sessionOpener.open(profile.id) { _ = $0.apply(history: entry) } })
                        .frame(width: Sizes.inspectorWidth)
                } else {
                    ConnectionInspector(profile: profile, onOpenConsole: onOpenConsole, onDelete: onDelete)
                        .frame(width: Sizes.inspectorWidth)
                }
            }
        }
        .background(PortSQLPalette.canvasTop.ignoresSafeArea())
        .alert(namingFolder?.title ?? "", isPresented: Binding(get: { namingFolder != nil }, set: { if !$0 { namingFolder = nil } })) {
            TextField("Name", text: $folderName)
            Button("Cancel", role: .cancel) { namingFolder = nil }
            Button(namingFolder?.isNew == true ? L10n.text("Create") : L10n.text("Rename")) { saveFolderName() }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(L10n.format("Delete “%@”?", deletingFolder?.name ?? ""),
                            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) {
                if let deletingFolder {
                    if folderFilter == deletingFolder.id { folderFilter = nil }
                    bookmarks.deleteFolder(deletingFolder.id)
                }
                deletingFolder = nil
            }
        } message: {
            Text("Its connections stay, outside any folder.")
        }
    }

    // MARK: Quick connect

    private var isConnectionString: Bool { ConnectionStringImporter.looksLikeConnectionString(query) }

    private var quickConnectBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                searchField
                newConnectionButton
            }
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill").font(.footnoteText).foregroundStyle(.red)
            }
        }
    }

    /// Creates a connection on click; its menu also imports a connection string or creates a SQLite database.
    private var newConnectionButton: some View {
        Menu {
            Button("New Connection…", systemImage: "plus") { workspace.createBookmark() }
            Button("Import Connection String…", systemImage: "link") { workspace.createBookmark() }
            Divider()
            Button("New SQLite Database…", systemImage: "externaldrive.badge.plus", action: onCreateSQLite)
        } label: {
            Label("New Connection", systemImage: "plus").frame(minHeight: Sizes.buttonContent)
        } primaryAction: {
            workspace.createBookmark()
        }
        .menuStyle(.button)
        .buttonStyle(.portbasePrimary)
        .fixedSize()
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s) {
                Image(systemName: isConnectionString ? "link" : "magnifyingglass")
                    .foregroundStyle(isConnectionString ? PortSQLPalette.accent : .secondary)
                    .frame(width: Sizes.symbolColumn)
                TextField("Search or paste a connection string", text: $query)
                    .textFieldStyle(.plain)
                    .portbaseTextCapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { if isConnectionString { importQuery() } }
                    .onChange(of: query) { _, _ in importError = nil }
                if isConnectionString {
                    Button("Import", action: importQuery)
                        .buttonStyle(.portbasePrimary)
                        .accessibilityHint("Opens the connection form with these details")
                } else if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            .frame(minWidth: Sizes.control, minHeight: Sizes.control)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.bodyText)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.toolbar)
            .portbaseCardSurface(radius: Radius.control)
        }
    }

    private func importQuery() {
        do {
            try workspace.importConnection(from: query)
            query = ""
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Folders

    private enum FolderNaming {
        case new
        case rename(ConnectionFolder)

        var isNew: Bool { if case .new = self { return true }; return false }
        var title: String { isNew ? L10n.text("New Folder") : L10n.text("Rename Folder") }
    }

    private func saveFolderName() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch namingFolder {
        case .new: bookmarks.addFolder(named: name)
        case .rename(var folder): folder.name = name; bookmarks.updateFolder(folder)
        case nil: break
        }
        namingFolder = nil
    }

    private func count(in folder: ConnectionFolder) -> Int {
        bookmarks.bookmarks.filter { $0.folderID == folder.id }.count
    }

    /// The user's folders and a tile to add one. A folder filters the list below, and connections can
    /// be dragged onto it.
    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Folders"))
            // Wraps onto more rows rather than scrolling sideways, so no folder is cut off.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(bookmarks.folders) { folder in folderTile(folder) }
                Button {
                    folderName = ""
                    namingFolder = .new
                } label: {
                    ConnectionTile {
                        Image(systemName: "folder.badge.plus")
                            .font(.tileSymbol)
                            .foregroundStyle(PortSQLPalette.accent)
                            .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                            .background(PortSQLPalette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    } title: {
                        Text("New Folder")
                    } subtitle: {
                        EmptyView()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func folderTile(_ folder: ConnectionFolder) -> some View {
        let selected = folderFilter == folder.id
        let tint = folder.colorTag?.color ?? PortSQLPalette.accent
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { folderFilter = selected ? nil : folder.id }
        } label: {
            ConnectionTile(isSelected: selected) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.tileSymbol)
                    .foregroundStyle(tint)
                    .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            } title: {
                Text(folder.name)
            } subtitle: {
                Text(L10n.plural("connection_count", count: count(in: folder)))
            }
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            ids.forEach { bookmarks.move($0, toFolder: folder.id) }
            return !ids.isEmpty
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                folderName = folder.name
                namingFolder = .rename(folder)
            }
            Menu("Color", systemImage: "paintpalette") {
                Button("None") { var updated = folder; updated.colorTag = nil; bookmarks.updateFolder(updated) }
                ForEach(ConnectionColor.allCases) { color in
                    Button {
                        var updated = folder
                        updated.colorTag = color
                        bookmarks.updateFolder(updated)
                    } label: {
                        Label { Text(color.title) } icon: { Image(systemName: folder.colorTag == color ? "checkmark.circle.fill" : "circle.fill").foregroundStyle(color.color) }
                    }
                }
            }
            Divider()
            Button("Delete Folder", systemImage: "trash", role: .destructive) { deletingFolder = folder }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Shows only connections in this folder")
    }

    // MARK: Connections

    private var filtered: [ConnectionProfile] {
        let search = isConnectionString ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        return bookmarks.bookmarks.filter { profile in
            (folderFilter == nil || profile.folderID == folderFilter)
                && (environmentFilter == nil || profile.environment == environmentFilter)
                && (engineFilter == nil || profile.engine == engineFilter)
                && (colorFilter == nil || profile.colorTag == colorFilter)
                && (!onlyReadOnly || profile.isReadOnly)
                && (search.isEmpty || [profile.name, profile.host, profile.defaultDatabase, profile.username, profile.notes, profile.engine.rawValue]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Servers")) {
                HStack(spacing: Spacing.s) {
                    if let folder = bookmarks.folder(with: folderFilter) {
                        Button { withAnimation { folderFilter = nil } } label: {
                            PortbaseChip(title: folder.name, systemImage: "xmark", tint: folder.colorTag?.color ?? PortSQLPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Clear filter %@", folder.name))
                    }
                    filterMenu
                }
            }
            if filtered.isEmpty {
                Text("No matching servers")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Sizes.row + Spacing.m)
                    .portbaseCardSurface()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.m)], spacing: Spacing.m) {
                    ForEach(filtered) { profile in
                        ConnectionCard(profile: profile, onOpenConsole: onOpenConsole, onDelete: onDelete,
                                       isInspected: sessionOpener != nil && inspectedProfile?.id == profile.id,
                                       onInspect: sessionOpener == nil ? nil : { inspectedID = profile.id })
                    }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("New Folder", systemImage: "folder.badge.plus") {
                folderName = ""
                namingFolder = .new
            }
            Divider()
            // Environments are a connection's safety setting; they filter here, and folders group.
            let environments = ConnectionEnvironment.allCases.filter { environment in
                environment != .none && bookmarks.bookmarks.contains { $0.environment == environment }
            }
            if !environments.isEmpty {
                Picker("Environment", selection: $environmentFilter) {
                    Text("All Environments").tag(Optional<ConnectionEnvironment>.none)
                    ForEach(environments, id: \.self) { environment in
                        Label { Text(environment.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(environment.color) }
                            .tag(Optional(environment))
                    }
                }
            }
            Picker("Engine", selection: $engineFilter) {
                Text("All Engines").tag(Optional<DatabaseEngine>.none)
                ForEach(DatabaseEngine.allCases) { engine in Text(engine.rawValue).tag(Optional(engine)) }
            }
            // Only the colors in use, so the menu stays short.
            let colors = ConnectionColor.allCases.filter { color in bookmarks.bookmarks.contains { $0.colorTag == color } }
            if !colors.isEmpty {
                Picker("Color Tag", selection: $colorFilter) {
                    Text("All Colors").tag(Optional<ConnectionColor>.none)
                    ForEach(colors) { color in
                        Label { Text(color.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.color) }
                            .tag(Optional(color))
                    }
                }
            }
            Toggle("Read-only connections", isOn: $onlyReadOnly)
            Button("Reset Filters") { engineFilter = nil; colorFilter = nil; environmentFilter = nil; onlyReadOnly = false; folderFilter = nil; query = "" }
        } label: {
            Image(systemName: engineFilter != nil || colorFilter != nil || environmentFilter != nil || onlyReadOnly
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.toolSymbol)
                .frame(minWidth: Sizes.control, minHeight: Sizes.control)
        }
        .portbaseToolbarMenu()
        .accessibilityLabel("Filter servers")
    }
}

// MARK: - Cards

/// The shared card layout for connections and environment groups: a leading tile, a title, and a subtitle.
private struct ConnectionTile<Icon: View, Title: View, Subtitle: View, Trailing: View>: View {
    var isSelected = false
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(spacing: Spacing.m) {
            icon
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                title.font(.rowTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                subtitle.font(.captionText).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.xxs)
            trailing
        }
        .padding(Spacing.m)
        .frame(minHeight: Sizes.row + Spacing.m)
        .background(isHovering && !isSelected ? PortSQLPalette.sunken : PortSQLPalette.surface, in: shape)
        .overlay {
            shape.strokeBorder(isSelected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(shape)
        .onHover { isHovering = $0 }
    }
}

extension ConnectionTile where Trailing == EmptyView {
    init(isSelected: Bool = false, @ViewBuilder icon: () -> Icon, @ViewBuilder title: () -> Title, @ViewBuilder subtitle: () -> Subtitle) {
        self.init(isSelected: isSelected, icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct ConnectionCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.connectionSessionOpener) private var sessionOpener
    let profile: ConnectionProfile
    var onOpenConsole: (() -> Void)?
    var onDelete: (ConnectionProfile) -> Void
    var isInspected = false
    /// Set when connections open in tabs: a click inspects the card and a double-click opens it.
    var onInspect: (() -> Void)?

    private var isActive: Bool { workspace.selectedBookmarkID == profile.id }

    var body: some View {
        Button {
            if let onInspect { onInspect() } else if !isActive { workspace.selectBookmark(profile.id) }
        } label: {
            ConnectionTile(isSelected: onInspect == nil ? isActive : isInspected) {
                BookmarkAvatar(profile: profile, size: Sizes.iconTile, cornerRadius: Radius.control)
                    .overlay(alignment: .bottomTrailing) {
                        if isActive {
                            Circle().fill(Color.green)
                                .frame(width: Sizes.dot + Spacing.xxs, height: Sizes.dot + Spacing.xxs)
                                .overlay { Circle().strokeBorder(PortSQLPalette.surface, lineWidth: 2) }
                                .offset(x: Spacing.xxs, y: Spacing.xxs)
                        }
                    }
            } title: {
                Text(profile.displayTitle)
            } subtitle: {
                Text(subtitle)
            } trailing: {
                HStack(spacing: Spacing.xs) {
                    if profile.environment != .none {
                        Circle().fill(profile.environment.color).frame(width: Sizes.dot, height: Sizes.dot)
                            .accessibilityLabel(profile.environment.title)
                    }
                    if profile.isReadOnly {
                        Image(systemName: "lock.fill").font(.captionText).foregroundStyle(.secondary)
                            .accessibilityLabel("Read-only")
                    }
                    if profile.transportSecurityMode == .plaintext && !profile.engine.isLocal {
                        Image(systemName: "lock.open.fill").font(.captionText).foregroundStyle(.red)
                            .accessibilityLabel("Unencrypted")
                    }
                    actionsMenu
                }
            }
        }
        .buttonStyle(.plain)
#if os(macOS)
        .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
#endif
        .contextMenu { menuItems }
        // Drop on a folder to file the connection there.
        .draggable(profile.id.uuidString)
        .help(profile.endpointSummary)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(sessionOpener == nil ? L10n.text("Makes this the active connection") : L10n.text("Double-click to open in a tab"))
    }

    private func open() {
        if let sessionOpener { sessionOpener.open(profile.id) } else {
            workspace.selectBookmark(profile.id)
            onOpenConsole?()
        }
    }

    /// The engine and user, like "PostgreSQL · app"; the full endpoint is in the inspector and tooltip.
    private var subtitle: String {
        if profile.engine.isLocal { return profile.endpointSummary }
        // Redis database numbers say little on their own, so Redis cards show only the user.
        let database = profile.engine == .redis ? "" : profile.trimmedDefaultDatabase
        let detail = [profile.username, database].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return [profile.engine.rawValue, detail].compactMap { $0 }.joined(separator: " · ")
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .font(.toolSymbol)
                .foregroundStyle(.secondary)
                .frame(minWidth: Sizes.control, minHeight: Sizes.control)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L10n.format("Edit %@", profile.displayTitle))
    }

    @ViewBuilder private var menuItems: some View {
        if onOpenConsole != nil || sessionOpener != nil {
            Button("Open Console", systemImage: "terminal") { open() }
        } else {
            Button("Connect", systemImage: "bolt.horizontal.fill") { workspace.selectBookmark(profile.id) }
        }
        Button("Edit", systemImage: "pencil") { workspace.selectedProfileForEdit = profile }
        Button("Duplicate Connection", systemImage: "plus.square.on.square") { workspace.selectedProfileForEdit = profile.duplicate() }
        if !bookmarks.folders.isEmpty {
            Menu("Move to Folder", systemImage: "folder") {
                Button {
                    bookmarks.move(profile.id, toFolder: nil)
                } label: {
                    Label("No Folder", systemImage: profile.folderID == nil ? "checkmark" : "tray")
                }
                Divider()
                ForEach(bookmarks.folders) { folder in
                    Button {
                        bookmarks.move(profile.id, toFolder: folder.id)
                    } label: {
                        Label(folder.name, systemImage: profile.folderID == folder.id ? "checkmark" : "folder")
                    }
                }
            }
        }
        Divider()
        Button("Delete Connection", systemImage: "trash", role: .destructive) { onDelete(profile) }
    }
}

// MARK: - Inspector

/// Details and actions for the active connection, shown beside the grid on wide layouts.
private struct ConnectionInspector: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var library: WorkspaceLibraryStore
    let profile: ConnectionProfile
    var onOpenConsole: (() -> Void)?
    var onDelete: (ConnectionProfile) -> Void
    /// Opens a recent query; by default it loads into the current workspace.
    var onApplyHistory: ((QueryHistoryEntry) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                actions
                details
                recentQueries
                Button(role: .destructive) { onDelete(profile) } label: {
                    Label("Delete Connection", systemImage: "trash").frame(minHeight: Sizes.buttonContent)
                }
                .buttonStyle(.borderless)
                .tint(.red)
                .foregroundStyle(.red)
            }
            .padding(Spacing.page)
        }
        .background(PortSQLPalette.panel.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            BookmarkAvatar(profile: profile, size: Sizes.avatarHero, cornerRadius: Radius.card)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(profile.displayTitle).font(.sectionTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(2)
                Text(profile.endpointSummary).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
            }
            ConnectionSecurityChips(profile: profile)
        }
    }

    private var actions: some View {
        VStack(spacing: Spacing.s) {
            if let onOpenConsole {
                Button(action: onOpenConsole) {
                    Label("Open Console", systemImage: "terminal").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                }
                .buttonStyle(.portbasePrimary)
            }
            HStack(spacing: Spacing.s) {
                Button { workspace.selectedProfileForEdit = profile } label: {
                    Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                }
                Button { workspace.selectedProfileForEdit = profile.duplicate() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                }
            }
            .buttonStyle(.portbaseSecondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Details").font(.cardTitle).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                row(L10n.text("Engine"), profile.engine.rawValue)
                if !profile.engine.isLocal {
                    PortbaseRowDivider()
                    row(L10n.text("Host"), profile.host)
                    PortbaseRowDivider()
                    row(L10n.text("Port"), String(profile.port))
                    if !profile.username.isEmpty {
                        PortbaseRowDivider()
                        row(L10n.text("Username"), profile.username)
                    }
                }
                if !profile.trimmedDefaultDatabase.isEmpty {
                    PortbaseRowDivider()
                    row(L10n.text("Database"), profile.trimmedDefaultDatabase)
                }
            }
            .portbaseCardSurface(radius: Radius.control)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            Text(value).foregroundStyle(PortSQLPalette.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.rowDetail)
        .padding(.horizontal, Spacing.card)
        .frame(minHeight: Sizes.statusBar + Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var recentQueries: some View {
        let history = WorkspaceActivityService.recentDistinct(library.history.filter { $0.bookmarkID == profile.id }, limit: 5)
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Recent Queries").font(.cardTitle).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { PortbaseRowDivider(leadingIcon: Sizes.symbolColumn) }
                        Button {
                            if let onApplyHistory { onApplyHistory(entry) } else if workspace.apply(history: entry) { onOpenConsole?() }
                        } label: {
                            RecentQueryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this query into the console without running it")
                    }
                }
                .portbaseCardSurface(radius: Radius.control)
            }
        }
    }
}

extension WorkspaceViewModel {
    /// Opens the connection form prefilled from a pasted connection string. Nothing is saved until
    /// the form is saved, and the transport mode follows the same explicit rules as the editor's import.
    func importConnection(from text: String) throws {
        let base = ConnectionProfile(name: "", engine: .postgresql, iconName: nil, host: "", port: 5432,
                                     username: "", password: "", defaultDatabase: "")
        selectedProfileForEdit = try ConnectionStringImporter.apply(text, to: base).profile
    }
}
