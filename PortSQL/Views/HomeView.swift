import Charts
import SwiftUI

/// The launch page: the current connection, quick actions, recent work, and activity.
struct HomeView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    let onNavigate: (PortbaseDestination) -> Void
    var onSearch: () -> Void = {}

    @State private var now = Date.now
    @State private var createsSQLite = false

    private var activity: WorkspaceActivity { WorkspaceActivityService.activity(history: library.history, now: now) }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760
            ScrollView {
                // Each section is type-erased so the page's view type stays small to lay out.
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    AnyView(connectionCard)
                    AnyView(quickActions)
                    if wide {
                        HStack(alignment: .top, spacing: Spacing.xl) {
                            AnyView(recentSection).frame(maxWidth: .infinity)
                            AnyView(activitySection(activity)).frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: Spacing.xl) {
                            AnyView(connectionsSection).frame(maxWidth: .infinity)
                            AnyView(savedSection).frame(maxWidth: .infinity)
                        }
                    } else {
                        AnyView(recentSection)
                        AnyView(activitySection(activity))
                        AnyView(connectionsSection)
                        AnyView(savedSection)
                    }
                }
                .padding(.horizontal, wide ? Spacing.xxl : Spacing.page)
                .padding(.vertical, Spacing.l)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PortSQLPalette.canvasTop.ignoresSafeArea())
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { onNavigate(.console) }
        .onAppear { now = .now }
    }

    // MARK: Connection

    @ViewBuilder private var connectionCard: some View {
        if let profile = workspace.selectedBookmark {
            let healthy = workspace.errorMessage == nil && workspace.schemaErrorMessage == nil
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(spacing: Spacing.m) {
                    BookmarkAvatar(profile: profile, size: Sizes.avatarLarge, cornerRadius: Radius.chip)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        HStack(spacing: Spacing.xs) {
                            Text(profile.displayTitle).font(.cardTitle).lineLimit(1)
                            EnvironmentBadge(environment: profile.environment)
                        }
                        Text(profile.endpointSummary).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.s)
                    Circle()
                        .fill(healthy ? Color.green : Color.orange)
                        .frame(width: Sizes.dot, height: Sizes.dot)
                        .accessibilityLabel(healthy ? L10n.text("Active connection") : L10n.text("Needs attention"))
                }

                HStack(spacing: Spacing.m) {
                    DatabasePicker()
                    if !workspace.schemaCatalog.isEmpty {
                        Text(tableCountLabel).font(.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                if let error = workspace.schemaErrorMessage {
                    ConnectionIssueBanner(message: error, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                }

                HStack(spacing: Spacing.s) {
                    Button { onNavigate(.console) } label: {
                        Label("Open Console", systemImage: "terminal").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                    }
                    .buttonStyle(.portbasePrimary)
                    Button { onNavigate(.explorer) } label: {
                        Label("Browse Data", systemImage: "tablecells").frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                    }
                    .buttonStyle(.portbaseSecondary)
                }
            }
            .padding(Spacing.l)
            .portbaseCardSurface()
        } else if !bookmarks.bookmarks.isEmpty {
            // Saved connections exist but none is active yet.
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Choose a connection").font(.cardTitle)
                Text("Pick a saved connection to browse its tables and run queries.")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(bookmarks.bookmarks.prefix(6)) { profile in
                        Button { workspace.selectBookmark(profile.id) } label: {
                            HStack(spacing: Spacing.s) {
                                BookmarkAvatar(profile: profile, size: Sizes.avatarSmall, cornerRadius: Radius.s)
                                Text(profile.displayTitle).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
                        }
                        .buttonStyle(.portbaseSecondary)
                        .tint(.secondary)
                        .foregroundStyle(PortSQLPalette.ink)
                    }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .portbaseCardSurface()
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Connect your first database").font(.cardTitle)
                Text("Portbase works with MySQL, MariaDB, PostgreSQL, SQLite, ClickHouse, MongoDB, Redis, and Elasticsearch.")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                // Side by side when both titles fit on one line; otherwise stacked at full width.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) { onboardingButtons }
                    VStack(spacing: Spacing.m) { onboardingButtons }
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .portbaseCardSurface()
        }
    }

    @ViewBuilder private var onboardingButtons: some View {
        Button { workspace.createBookmark() } label: {
            Label("Add Connection", systemImage: "plus")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.portbasePrimary)
        Button { createsSQLite = true } label: {
            Label("New SQLite Database", systemImage: "internaldrive")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.portbaseSecondary)
    }

    private var tableCountLabel: String {
        workspace.isDocumentDatabase
            ? L10n.format("Collections: %d", workspace.schemaCatalog.count)
            : L10n.format("Tables: %d", workspace.schemaCatalog.count)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.s) { quickActionButtons }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)], spacing: Spacing.s) {
                quickActionButtons
            }
        }
    }

    @ViewBuilder private var quickActionButtons: some View {
        QuickAction(title: L10n.text("New Query"), systemImage: "plus.rectangle.on.rectangle") { consoles.add(); onNavigate(.console) }
        QuickAction(title: L10n.text("Search"), systemImage: "magnifyingglass") { onSearch() }
        QuickAction(title: L10n.text("Query Library"), systemImage: "books.vertical") { onNavigate(.library) }
        QuickAction(title: L10n.text("Charts"), systemImage: "chart.bar.xaxis") { onNavigate(.charts) }
    }

    // MARK: Recent queries

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Recent Queries")) {
                if !library.history.isEmpty {
                    Button("Show All") { onNavigate(.library) }
                        .buttonStyle(.borderless)
                        .font(.rowDetail)
                        .frame(minHeight: Sizes.control)
                }
            }
            VStack(spacing: 0) {
                if library.history.isEmpty {
                    placeholder("Queries you run appear here. Loading one never runs it.")
                } else {
                    ForEach(Array(WorkspaceActivityService.recentDistinct(library.history, limit: 5).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { PortbaseRowDivider(leadingIcon: Sizes.symbolColumn) }
                        Button {
                            if workspace.apply(history: entry) { onNavigate(.console) }
                        } label: {
                            RecentQueryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this query into the console without running it")
                    }
                }
            }
            .portbaseCardSurface()
        }
    }

    // MARK: Activity

    private func activitySection(_ activity: WorkspaceActivity) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Activity")) {
                Text("Last 14 days").font(.captionText).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(spacing: 0) {
                    stat(L10n.text("Queries run"), activity.executionCount.formatted())
                    stat(L10n.text("Success rate"), activity.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    stat(L10n.text("Median time"), activity.medianDuration.map { WorkspaceActivityService.durationLabel($0) } ?? "—")
                }
                if activity.hasActivity {
                    Chart(activity.days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Queries", day.total))
                            .foregroundStyle(PortSQLPalette.accent.opacity(0.8))
                            .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 110)
                    .accessibilityLabel("Queries per day")
                }
            }
            .padding(Spacing.l)
            .portbaseCardSurface()
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(value).font(.metricValue).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Connections")) {
                if bookmarks.bookmarks.count > 6 {
                    Button("Show All") { onNavigate(.servers) }
                        .buttonStyle(.borderless)
                        .font(.rowDetail)
                        .frame(minHeight: Sizes.control)
                }
                Button { workspace.createBookmark() } label: {
                    Image(systemName: "plus")
                        .frame(width: Sizes.control, height: Sizes.control)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Connection")
            }
            VStack(spacing: 0) {
                if bookmarks.bookmarks.isEmpty {
                    placeholder("No servers saved")
                } else {
                    ForEach(Array(bookmarks.bookmarks.prefix(6).enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { PortbaseRowDivider(leadingIcon: Sizes.avatar) }
                        Button {
                            if workspace.selectedBookmarkID != profile.id { workspace.selectBookmark(profile.id) }
                        } label: {
                            HStack(spacing: Spacing.m) {
                                BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
                                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                    Text(profile.displayTitle).font(.rowDetail).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Text(profile.endpointSummary).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: Spacing.s)
                                if workspace.selectedBookmarkID == profile.id {
                                    Image(systemName: "checkmark").font(.rowTitle).foregroundStyle(PortSQLPalette.accent)
                                }
                            }
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, Spacing.xs)
                            .frame(minHeight: Sizes.row)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(workspace.selectedBookmarkID == profile.id ? [.isButton, .isSelected] : .isButton)
                    }
                    if bookmarks.bookmarks.count > 6 {
                        Divider()
                        Button("Show All") { onNavigate(.servers) }
                            .font(.rowDetail)
                            .frame(maxWidth: .infinity, minHeight: Sizes.control)
                    }
                }
            }
            .portbaseCardSurface()
        }
    }

    // MARK: Saved queries

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSectionHeading(title: L10n.text("Saved Queries")) {
                if library.snippets.count > 5 {
                    Button("Show All") { onNavigate(.library) }
                        .buttonStyle(.borderless)
                        .font(.rowDetail)
                        .frame(minHeight: Sizes.control)
                }
            }
            VStack(spacing: 0) {
                if library.snippets.isEmpty {
                    placeholder("Save a query from the console to keep it one tap away.")
                } else {
                    ForEach(Array(library.snippets.prefix(5).enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Divider().padding(.leading, Spacing.l) }
                        Button {
                            if workspace.apply(snippet: snippet) { onNavigate(.console) }
                        } label: {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(snippet.title).font(.rowDetail).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                Text(snippet.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(.codeCaption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, Spacing.l)
                            .frame(maxWidth: .infinity, minHeight: Sizes.row, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this query into the console without running it")
                    }
                }
            }
            .portbaseCardSurface()
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Sizes.row + Spacing.m)
            .padding(.horizontal, Spacing.l)
    }
}

struct RecentQueryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.captionStrong)
                .foregroundStyle(tint)
                .frame(width: Sizes.symbolColumn)
                .accessibilityLabel((entry.outcome ?? .succeeded).title)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.rowDetail).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text(entry.executedAt, format: .relative(presentation: .named))
                        .font(.microText).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Spacing.xs) {
                    Text([entry.connectionName, entry.database].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    if let duration = entry.duration {
                        Text(verbatim: "·")
                        Text(WorkspaceActivityService.durationLabel(duration)).monospacedDigit()
                    }
                }
                .font(.captionText)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: Sizes.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch entry.outcome ?? .succeeded {
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .cancelled: "stop.fill"
        }
    }

    private var tint: Color {
        switch entry.outcome ?? .succeeded {
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .gray
        }
    }
}

private struct QuickAction: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: systemImage).foregroundStyle(PortSQLPalette.accent)
                Text(title).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.rowDetail)
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: .infinity, minHeight: Sizes.control + 4)
            .portbaseCardSurface(radius: Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A native menu picker for the current connection's databases.
struct DatabasePicker: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if workspace.isLoadingSchema || workspace.isRefreshingDatabases { ProgressView().controlSize(.small) }
            Menu {
                Picker("Database", selection: Binding(
                    get: { workspace.activeDatabaseName ?? "" },
                    set: { if !$0.isEmpty { workspace.selectDatabase($0) } }
                )) {
                    if workspace.availableDatabases.isEmpty {
                        Text(workspace.activeDatabaseName ?? L10n.text("Database")).tag(workspace.activeDatabaseName ?? "")
                    }
                    ForEach(workspace.availableDatabases, id: \.self) { database in
                        Text(database).tag(database)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh Database List", systemImage: "arrow.clockwise") { workspace.refreshDatabaseList() }
                    .disabled(workspace.isRefreshingDatabases)
            } label: {
                Label(workspace.activeDatabaseName ?? L10n.text("Database"), systemImage: "externaldrive")
            }
            .fixedSize()
            .disabled(workspace.selectedBookmark == nil || workspace.isLoadingSchema)
            .accessibilityLabel("Choose database")
        }
    }
}
