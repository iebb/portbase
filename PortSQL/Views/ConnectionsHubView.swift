import SwiftUI

/// The connection hub: a quick-connect bar, environment groups, a grid of connection cards, and,
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
    @State private var group: ConnectionEnvironment?
    @State private var engineFilter: DatabaseEngine?
    @State private var onlyReadOnly = false
    @State private var importError: String?

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
                    actionRow
                    if bookmarks.bookmarks.isEmpty {
                        PortbaseEmptyState(
                            title: L10n.text("No servers saved"),
                            message: L10n.text("Add a connection to browse tables, run queries, and build charts."),
                            systemImage: "server.rack"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.xxl)
                    } else {
                        if !groups.isEmpty { groupsSection }
                        connectionsSection
                    }
                    Label("Server settings sync through iCloud. Passwords stay in this device’s Keychain.", systemImage: "icloud")
                        .font(.footnoteText)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.page)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            if showsInspector, let profile = workspace.selectedBookmark {
                Divider().ignoresSafeArea()
                ConnectionInspector(profile: profile, onOpenConsole: onOpenConsole, onDelete: onDelete)
                    .frame(width: Sizes.inspectorWidth)
            }
        }
        .background(PortSQLPalette.canvasTop.ignoresSafeArea())
    }

    // MARK: Quick connect

    private var isConnectionString: Bool { ConnectionStringImporter.looksLikeConnectionString(query) }

    private var quickConnectBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
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
                        .buttonStyle(.borderedProminent)
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
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill").font(.footnoteText).foregroundStyle(.red)
            }
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

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { actionButtons }
            VStack(alignment: .leading, spacing: Spacing.s) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        Button { workspace.createBookmark() } label: {
            Label("New Connection", systemImage: "plus").frame(minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.borderedProminent)
        Button(action: onCreateSQLite) {
            Label("New SQLite Database", systemImage: "externaldrive.badge.plus").frame(minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.bordered)
    }

    // MARK: Groups

    private var groups: [(environment: ConnectionEnvironment, count: Int)] {
        ConnectionEnvironment.allCases.filter { $0 != .none }.compactMap { environment in
            let count = bookmarks.bookmarks.filter { $0.environment == environment }.count
            return count > 0 ? (environment, count) : nil
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Environments"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                ForEach(groups, id: \.environment) { item in
                    let selected = group == item.environment
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { group = selected ? nil : item.environment }
                    } label: {
                        ConnectionTile(isSelected: selected) {
                            Image(systemName: selected ? "folder.fill" : "folder")
                                .font(.tileSymbol)
                                .foregroundStyle(item.environment.color)
                                .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                                .background(item.environment.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        } title: {
                            Text(item.environment.title)
                        } subtitle: {
                            Text(L10n.plural("connection_count", count: item.count))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint("Shows only connections in this environment")
                    .frame(minWidth: 180)
                }
                }
                .padding(.vertical, Spacing.xxxs)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Connections

    private var filtered: [ConnectionProfile] {
        let search = isConnectionString ? "" : query.trimmingCharacters(in: .whitespacesAndNewlines)
        return bookmarks.bookmarks.filter { profile in
            (group == nil || profile.environment == group)
                && (engineFilter == nil || profile.engine == engineFilter)
                && (!onlyReadOnly || profile.isReadOnly)
                && (search.isEmpty || [profile.name, profile.host, profile.defaultDatabase, profile.username, profile.notes, profile.engine.rawValue]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Servers")) {
                HStack(spacing: Spacing.s) {
                    if let group {
                        Button { withAnimation { self.group = nil } } label: {
                            PortbaseChip(title: group.title, systemImage: "xmark", tint: group.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Clear filter %@", group.title))
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
                        ConnectionCard(profile: profile, onOpenConsole: onOpenConsole, onDelete: onDelete)
                    }
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Engine", selection: $engineFilter) {
                Text("All Engines").tag(Optional<DatabaseEngine>.none)
                ForEach(DatabaseEngine.allCases) { engine in Text(engine.rawValue).tag(Optional(engine)) }
            }
            Toggle("Read-only connections", isOn: $onlyReadOnly)
            Button("Reset Filters") { engineFilter = nil; onlyReadOnly = false; group = nil; query = "" }
        } label: {
            Image(systemName: engineFilter != nil || onlyReadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.toolSymbol)
                .frame(minWidth: Sizes.control, minHeight: Sizes.control)
        }
        .menuIndicator(.hidden)
#if os(macOS)
        .menuStyle(.borderlessButton)
#endif
        .fixedSize()
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
    let profile: ConnectionProfile
    var onOpenConsole: (() -> Void)?
    var onDelete: (ConnectionProfile) -> Void

    private var isActive: Bool { workspace.selectedBookmarkID == profile.id }

    var body: some View {
        Button {
            if !isActive { workspace.selectBookmark(profile.id) }
        } label: {
            ConnectionTile(isSelected: isActive) {
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            workspace.selectBookmark(profile.id)
            onOpenConsole?()
        })
#endif
        .contextMenu { menuItems }
        .help(profile.endpointSummary)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint("Makes this the active connection")
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
        if let onOpenConsole {
            Button("Open Console", systemImage: "terminal") {
                workspace.selectBookmark(profile.id)
                onOpenConsole()
            }
        } else {
            Button("Connect", systemImage: "bolt.horizontal.fill") { workspace.selectBookmark(profile.id) }
        }
        Button("Edit", systemImage: "pencil") { workspace.selectedProfileForEdit = profile }
        Button("Duplicate Connection", systemImage: "plus.square.on.square") { workspace.selectedProfileForEdit = profile.duplicate() }
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
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: Spacing.s) {
                Button { workspace.selectedProfileForEdit = profile } label: {
                    Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                }
                Button { workspace.selectedProfileForEdit = profile.duplicate() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                }
            }
            .buttonStyle(.bordered)
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
                            if workspace.apply(history: entry) { onOpenConsole?() }
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
