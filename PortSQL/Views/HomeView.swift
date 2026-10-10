import Charts
import SwiftUI

/// The launch dashboard: active connection, quick actions, activity, and recent work.
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
                // Each section is type-erased so the dashboard's view type stays small to lay out.
                VStack(alignment: .leading, spacing: 22) {
                    AnyView(header)
                    AnyView(activeConnectionCard)
                    AnyView(quickActions)
                    let activity = activity
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            AnyView(activitySection(activity)).frame(maxWidth: .infinity)
                            AnyView(connectionsSection).frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 18) {
                            AnyView(recentSection).frame(maxWidth: .infinity)
                            AnyView(savedSection).frame(maxWidth: .infinity)
                        }
                    } else {
                        AnyView(activitySection(activity))
                        AnyView(recentSection)
                        AnyView(connectionsSection)
                        AnyView(savedSection)
                    }
                }
                .padding(.horizontal, wide ? 28 : 16)
                .padding(.vertical, 20)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PortbaseBackdrop().ignoresSafeArea())
        .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { onNavigate(.console) }
        .onAppear { now = .now }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PortbaseLogoMark(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(PortbaseGreeting.text(for: now))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(PortSQLPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Active connection

    @ViewBuilder private var activeConnectionCard: some View {
        if let profile = workspace.selectedBookmark {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    BookmarkAvatar(profile: profile, size: 54, cornerRadius: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle().fill(workspace.errorMessage == nil && workspace.schemaErrorMessage == nil ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(workspace.errorMessage == nil && workspace.schemaErrorMessage == nil ? L10n.text("Active connection") : L10n.text("Needs attention"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(profile.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(profile.endpointSummary)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Menu {
                        ForEach(workspace.availableDatabases, id: \.self) { database in
                            Button {
                                workspace.selectDatabase(database)
                            } label: {
                                Label(database, systemImage: workspace.activeDatabaseName == database ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if workspace.isLoadingSchema { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: "externaldrive.fill") }
                            Text(workspace.activeDatabaseName ?? L10n.text("Database")).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
                        .background(.white.opacity(0.18), in: Capsule())
                    }
                    .disabled(workspace.availableDatabases.isEmpty)
                    .accessibilityLabel("Choose database")

                    if !workspace.schemaCatalog.isEmpty {
                        Text(tableCountLabel)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button { onNavigate(.console) } label: {
                        Label("Open Console", systemImage: "terminal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true))
                    Button { onNavigate(.explorer) } label: {
                        Label("Browse Data", systemImage: "tablecells.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HeroButtonStyle(prominent: false))
                }
            }
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: profile.engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RadialGradient(colors: [.white.opacity(0.28), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: profile.engine.tint.opacity(0.35), radius: 18, x: 0, y: 10)
            }
        } else {
            PortbaseEmptyState(
                title: L10n.text("Connect your first database"),
                message: L10n.text("Portbase works with MySQL, MariaDB, PostgreSQL, SQLite, ClickHouse, MongoDB, Redis, and Elasticsearch."),
                systemImage: "cylinder.split.1x2",
                actionTitle: L10n.text("Add Connection"),
                action: { workspace.createBookmark() },
                secondaryTitle: L10n.text("New SQLite Database"),
                secondaryAction: { createsSQLite = true }
            )
            .portbaseCardSurface(radius: 26)
        }
    }

    private var tableCountLabel: String {
        workspace.isDocumentDatabase
            ? L10n.format("Collections: %d", workspace.schemaCatalog.count)
            : L10n.format("Tables: %d", workspace.schemaCatalog.count)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ViewThatFits(in: .horizontal) {
            quickActionGrid(columns: 4).frame(minWidth: 640)
            quickActionGrid(columns: 2)
        }
    }

    private func quickActionGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            QuickActionTile(title: L10n.text("New Query"), subtitle: L10n.text("Open a fresh console"), systemImage: "plus.rectangle.on.rectangle", colors: [Color(hex: 0x6366F1), Color(hex: 0x8B5CF6)]) {
                consoles.add(); onNavigate(.console)
            }
            QuickActionTile(title: L10n.text("Search"), subtitle: L10n.text("Actions, tables, queries"), systemImage: "command", colors: [Color(hex: 0x0EA5E9), Color(hex: 0x2563EB)]) {
                onSearch()
            }
            QuickActionTile(title: L10n.text("Query Library"), subtitle: L10n.text("History and saved queries"), systemImage: "books.vertical.fill", colors: [Color(hex: 0x10B981), Color(hex: 0x0D9488)]) {
                onNavigate(.library)
            }
            QuickActionTile(title: L10n.text("Charts"), subtitle: L10n.format("Saved: %d", library.visualizations.count), systemImage: "chart.bar.xaxis", colors: [Color(hex: 0xF97316), Color(hex: 0xE11D48)]) {
                onNavigate(.charts)
            }
        }
    }

    // MARK: Activity

    private func activitySection(_ activity: WorkspaceActivity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PortbaseSectionHeading(title: L10n.text("Activity"), systemImage: "waveform.path.ecg") {
                Text("Last 14 days").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                PortbaseMetricTile(title: L10n.text("Queries run"), value: activity.executionCount.formatted(), systemImage: "bolt.fill", tint: Color(hex: 0x6366F1))
                PortbaseMetricTile(title: L10n.text("Success rate"), value: activity.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—",
                                   systemImage: "checkmark.seal.fill", tint: Color(hex: 0x10B981))
                PortbaseMetricTile(title: L10n.text("Median time"), value: activity.medianDuration.map { WorkspaceActivityService.durationLabel($0) } ?? "—",
                                   systemImage: "timer", tint: Color(hex: 0x0EA5E9))
                PortbaseMetricTile(title: L10n.text("Saved Queries"), value: library.snippets.count.formatted(), systemImage: "bookmark.fill", tint: Color(hex: 0xF97316))
            }
            VStack(alignment: .leading, spacing: 8) {
                if activity.hasActivity {
                    Chart(activity.days) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Succeeded", day.succeeded))
                            .foregroundStyle(by: .value("Outcome", L10n.text("Succeeded")))
                            .cornerRadius(3)
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Failed", day.failed))
                            .foregroundStyle(by: .value("Outcome", L10n.text("Failed")))
                            .cornerRadius(3)
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Cancelled", day.cancelled))
                            .foregroundStyle(by: .value("Outcome", L10n.text("Cancelled")))
                            .cornerRadius(3)
                    }
                    .chartForegroundStyleScale([
                        L10n.text("Succeeded"): PortSQLPalette.accent,
                        L10n.text("Failed"): Color.red.opacity(0.8),
                        L10n.text("Cancelled"): Color.gray.opacity(0.6),
                    ])
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartLegend(position: .bottom, spacing: 8)
                    .frame(height: 150)
                    .accessibilityLabel("Queries per day")
                    if let busiest = activity.busiestConnection {
                        Label(L10n.format("Most active: %@", busiest), systemImage: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Run a query to see your activity here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                }
            }
            .padding(14)
            .portbaseCardSurface(radius: 18)
        }
    }

    // MARK: Recent queries

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PortbaseSectionHeading(title: L10n.text("Recent Queries"), systemImage: "clock.arrow.circlepath") {
                if !library.history.isEmpty {
                    Button("Show All") { onNavigate(.library) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
                }
            }
            VStack(spacing: 0) {
                if library.history.isEmpty {
                    Text("Queries you run appear here. Loading one never runs it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .padding(.horizontal, 14)
                } else {
                    ForEach(Array(library.history.prefix(5).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 52) }
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
            .portbaseCardSurface(radius: 18)
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PortbaseSectionHeading(title: L10n.text("Connections"), systemImage: "server.rack") {
                Button { workspace.createBookmark() } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .frame(width: PortbaseControlSize.minimumHeight, height: PortbaseControlSize.minimumHeight)
                }
                .accessibilityLabel("Add Connection")
            }
            VStack(spacing: 0) {
                if bookmarks.bookmarks.isEmpty {
                    Text("No servers saved")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(Array(bookmarks.bookmarks.prefix(6).enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider().padding(.leading, 64) }
                        Button {
                            if workspace.selectedBookmarkID != profile.id { workspace.selectBookmark(profile.id) }
                        } label: {
                            HStack(spacing: 12) {
                                BookmarkAvatar(profile: profile, size: 38, cornerRadius: 11)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Text(profile.endpointSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if workspace.selectedBookmarkID == profile.id {
                                    PortbaseChip(title: L10n.text("Active"), systemImage: "checkmark", tint: .green)
                                } else {
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(workspace.selectedBookmarkID == profile.id ? L10n.text("Active") : "")
                    }
                    if bookmarks.bookmarks.count > 6 {
                        Divider()
                        Button("Show All") { onNavigate(.servers) }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: PortbaseControlSize.minimumHeight)
                    }
                }
            }
            .portbaseCardSurface(radius: 18)
        }
    }

    // MARK: Saved queries

    @ViewBuilder private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PortbaseSectionHeading(title: L10n.text("Saved Queries"), systemImage: "bookmark.fill")
            if library.snippets.isEmpty {
                Text("Save a query from the console to keep it one tap away.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .portbaseCardSurface(radius: 18)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(library.snippets.prefix(4)) { snippet in
                        Button {
                            if workspace.apply(snippet: snippet) { onNavigate(.console) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "bookmark.fill").foregroundStyle(PortSQLPalette.accent)
                                    Text(snippet.title).font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                Text(snippet.sql)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let engine = snippet.engine {
                                    PortbaseChip(title: [engine.rawValue, snippet.database].compactMap { $0 }.joined(separator: " · "), tint: engine.tint)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                            .portbaseCardSurface(radius: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Loads this query into the console without running it")
                    }
                }
            }
        }
    }
}

struct RecentQueryRow: View {
    let entry: QueryHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(entry.executedAt, format: .relative(presentation: .named))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(entry.sql.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text([entry.connectionName, entry.database].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    if let duration = entry.duration {
                        Text(verbatim: "·")
                        Text(WorkspaceActivityService.durationLabel(duration)).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
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

private struct QuickActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let colors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: colors[1].opacity(0.35), radius: 8, x: 0, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .portbaseCardSurface(radius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct HeroButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
            .padding(.horizontal, 14)
            .frame(minHeight: PortbaseControlSize.minimumHeight)
            .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
