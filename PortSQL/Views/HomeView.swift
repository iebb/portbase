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
                VStack(alignment: .leading, spacing: 24) {
                    AnyView(connectionCard)
                    AnyView(quickActions)
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            AnyView(recentSection).frame(maxWidth: .infinity)
                            AnyView(activitySection(activity)).frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 20) {
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
                .padding(.horizontal, wide ? 28 : 16)
                .padding(.vertical, 16)
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BookmarkAvatar(profile: profile, size: 40, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayTitle).font(.headline).lineLimit(1)
                        Text(profile.endpointSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Circle()
                        .fill(healthy ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(healthy ? L10n.text("Active connection") : L10n.text("Needs attention"))
                }

                HStack(spacing: 12) {
                    DatabasePicker()
                    if !workspace.schemaCatalog.isEmpty {
                        Text(tableCountLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                if let error = workspace.schemaErrorMessage {
                    ConnectionIssueBanner(message: error, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect)
                }

                HStack(spacing: 10) {
                    Button { onNavigate(.console) } label: {
                        Label("Open Console", systemImage: "terminal").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { onNavigate(.explorer) } label: {
                        Label("Browse Data", systemImage: "tablecells").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .portbaseCardSurface(radius: 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your first database").font(.headline)
                Text("Portbase works with MySQL, MariaDB, PostgreSQL, SQLite, ClickHouse, MongoDB, Redis, and Elasticsearch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Side by side when both titles fit on one line; otherwise stacked at full width.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { onboardingButtons }
                    VStack(spacing: 10) { onboardingButtons }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .portbaseCardSurface(radius: 16)
        }
    }

    @ViewBuilder private var onboardingButtons: some View {
        Button { workspace.createBookmark() } label: {
            Label("Add Connection", systemImage: "plus")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.borderedProminent)
        Button { createsSQLite = true } label: {
            Label("New SQLite Database", systemImage: "internaldrive")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
    }

    private var tableCountLabel: String {
        workspace.isDocumentDatabase
            ? L10n.format("Collections: %d", workspace.schemaCatalog.count)
            : L10n.format("Tables: %d", workspace.schemaCatalog.count)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { quickActionButtons }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            PortbaseSectionHeading(title: L10n.text("Recent Queries")) {
                if !library.history.isEmpty {
                    Button("Show All") { onNavigate(.library) }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
                }
            }
            VStack(spacing: 0) {
                if library.history.isEmpty {
                    placeholder("Queries you run appear here. Loading one never runs it.")
                } else {
                    ForEach(Array(library.history.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 40) }
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
            .portbaseCardSurface(radius: 16)
        }
    }

    // MARK: Activity

    private func activitySection(_ activity: WorkspaceActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PortbaseSectionHeading(title: L10n.text("Activity")) {
                Text("Last 14 days").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
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
            .padding(14)
            .portbaseCardSurface(radius: 16)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PortbaseSectionHeading(title: L10n.text("Connections")) {
                Button { workspace.createBookmark() } label: {
                    Image(systemName: "plus")
                        .frame(width: PortbaseControlSize.minimumHeight, height: PortbaseControlSize.minimumHeight)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Connection")
            }
            VStack(spacing: 0) {
                if bookmarks.bookmarks.isEmpty {
                    placeholder("No servers saved")
                } else {
                    ForEach(Array(bookmarks.bookmarks.prefix(6).enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider().padding(.leading, 56) }
                        Button {
                            if workspace.selectedBookmarkID != profile.id { workspace.selectBookmark(profile.id) }
                        } label: {
                            HStack(spacing: 12) {
                                BookmarkAvatar(profile: profile, size: 30, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayTitle).font(.subheadline).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Text(profile.endpointSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if workspace.selectedBookmarkID == profile.id {
                                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.accent)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(workspace.selectedBookmarkID == profile.id ? [.isButton, .isSelected] : .isButton)
                    }
                    if bookmarks.bookmarks.count > 6 {
                        Divider()
                        Button("Show All") { onNavigate(.servers) }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: PortbaseControlSize.minimumHeight)
                    }
                }
            }
            .portbaseCardSurface(radius: 16)
        }
    }

    // MARK: Saved queries

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PortbaseSectionHeading(title: L10n.text("Saved Queries"))
            VStack(spacing: 0) {
                if library.snippets.isEmpty {
                    placeholder("Save a query from the console to keep it one tap away.")
                } else {
                    ForEach(Array(library.snippets.prefix(5).enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 { Divider().padding(.leading, 14) }
                        Button {
                            if workspace.apply(snippet: snippet) { onNavigate(.console) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snippet.title).font(.subheadline).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                Text(snippet.sql.replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this query into the console without running it")
                    }
                }
            }
            .portbaseCardSurface(radius: 16)
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 14)
    }
}

struct RecentQueryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)
                .accessibilityLabel((entry.outcome ?? .succeeded).title)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.subheadline).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.executedAt, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text([entry.connectionName, entry.database].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    if let duration = entry.duration {
                        Text(verbatim: "·")
                        Text(WorkspaceActivityService.durationLabel(duration)).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
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
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(PortSQLPalette.accent)
                Text(title).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: PortbaseControlSize.minimumHeight + 4)
            .portbaseCardSurface(radius: 12)
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
        HStack(spacing: 6) {
            if workspace.isLoadingSchema { ProgressView().controlSize(.small) }
            Picker(selection: Binding(
                get: { workspace.activeDatabaseName ?? "" },
                set: { if !$0.isEmpty { workspace.selectDatabase($0) } }
            )) {
                if workspace.availableDatabases.isEmpty {
                    Text(workspace.activeDatabaseName ?? L10n.text("Database")).tag(workspace.activeDatabaseName ?? "")
                }
                ForEach(workspace.availableDatabases, id: \.self) { database in
                    Text(database).tag(database)
                }
            } label: {
                Label("Database", systemImage: "externaldrive")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(workspace.availableDatabases.isEmpty || workspace.isLoadingSchema)
            .accessibilityLabel("Choose database")
        }
    }
}
