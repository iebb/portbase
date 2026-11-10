import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Saved charts on dashboard pages. Charts keep their last result and run only when asked; each
/// page can set a date range and parameter values that every chart on it uses.
struct VisualizerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @State private var editingPreset: SavedVisualizationPreset?

    var body: some View {
        ChartDashboard(
            fallbackBookmark: workspace.selectedBookmark,
            canChartCurrentResult: libraryStore.visualizations.isEmpty && canChartCurrentResult,
            onChartCurrentResult: { editingPreset = currentResultPreset },
            onEdit: { editingPreset = $0 }
        )
        .equatable()
        .navigationTitle("Charts")
        .portbaseTitleDisplayMode(.inline)
        .sheet(item: $editingPreset) { preset in
            VisualizerComposerSheet(initialPreset: preset)
        }
    }

    private var canChartCurrentResult: Bool {
        !workspace.result.columns.isEmpty
            && VisualizationService.fieldDescriptors(for: workspace.result).contains(where: \.supportsNumeric)
    }

    private var currentResultPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result,
            connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }
}

/// The dashboard body. Equatable on its inputs so typing elsewhere in the workspace never redraws charts.
private struct ChartDashboard: View, @MainActor Equatable {
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @EnvironmentObject private var bookmarks: BookmarkStore
    let fallbackBookmark: ConnectionProfile?
    let canChartCurrentResult: Bool
    let onChartCurrentResult: () -> Void
    let onEdit: (SavedVisualizationPreset) -> Void

    @StateObject private var refresh = ChartRefreshProgress()
    @State private var width: CGFloat = 0
    @State private var namingPage: PageNaming?
    @State private var pageName = ""
    @State private var editingFilters: ChartPage?
    @State private var deletingPage: ChartPage?
    @State private var targetedPage: UUID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fallbackBookmark?.id == rhs.fallbackBookmark?.id && lhs.canChartCurrentResult == rhs.canChartCurrentResult
    }

    private enum PageNaming: Identifiable {
        case new
        case rename(ChartPage)
        var id: String { if case .rename(let page) = self { return page.id.uuidString }; return "new" }
    }

    private var pages: [ChartPage] { libraryStore.displayedChartPages }
    private var currentPage: ChartPage {
        let id = libraryStore.resolvedCurrentChartPageID
        return pages.first { $0.id == id } ?? pages[0]
    }
    private var charts: [SavedVisualizationPreset] { libraryStore.charts(onPage: currentPage.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if libraryStore.visualizations.isEmpty {
                    PortbaseEmptyState(
                        title: L10n.text("No saved charts yet"),
                        message: L10n.text("Run a query with numeric columns, then choose the chart button in Results to design and save a chart."),
                        systemImage: "chart.bar.xaxis",
                        actionTitle: canChartCurrentResult ? L10n.text("Chart Current Result") : nil,
                        action: canChartCurrentResult ? onChartCurrentResult : nil
                    )
                    .padding(.top, Spacing.xxxl * 2)
                } else {
                    pageTabs
                    filterBar
                    if charts.isEmpty {
                        emptyPage
                    } else {
                        ChartTileLayout(spacing: Spacing.l) {
                            ForEach(charts) { preset in
                                ChartTile(
                                    preset: preset,
                                    profile: ChartQueryRunner.profile(for: preset, lookup: { bookmarks.bookmark(with: $0) }, fallback: fallbackBookmark),
                                    page: currentPage,
                                    pages: pages,
                                    refresh: refresh,
                                    pageWidth: width,
                                    onEdit: { onEdit(preset) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(Spacing.l)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - Spacing.l * 2 } action: { width = $0 }
        }
        .background(PortbaseBackdrop().ignoresSafeArea())
        .alert(namingPage.map { if case .new = $0 { return L10n.text("New Page") }; return L10n.text("Rename Page") } ?? "",
               isPresented: Binding(get: { namingPage != nil }, set: { if !$0 { namingPage = nil } })) {
            TextField("Page name", text: $pageName)
            Button("Cancel", role: .cancel) { namingPage = nil }
            Button("Save") { savePageName() }
        }
        .confirmationDialog(L10n.format("Delete %@?", deletingPage?.title ?? ""), isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } }), titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) {
                if let deletingPage { libraryStore.deleteChartPage(deletingPage.id) }
                deletingPage = nil
            }
        } message: {
            Text("Its charts move to the neighboring page.")
        }
        .sheet(item: $editingFilters) { page in
            ChartPageFiltersSheet(page: page, parameters: pageParameters(page))
        }
    }

    // MARK: Pages

    private var pageTabs: some View {
        HStack(spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(pages) { page in pageTab(page) }
                }
                .padding(.vertical, Spacing.xxxs)
            }
            Button {
                pageName = ""
                namingPage = .new
            } label: {
                Image(systemName: "plus").toolIconChrome()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Page")
        }
    }

    private func pageTab(_ page: ChartPage) -> some View {
        let selected = page.id == currentPage.id
        let targeted = targetedPage == page.id
        let count = libraryStore.charts(onPage: page.id).count
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { libraryStore.currentChartPageID = page.id }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(page.title).lineLimit(1)
                Text("\(count)")
                    .font(.microText.weight(.semibold))
                    .foregroundStyle(selected ? PortSQLPalette.accent : PortSQLPalette.muted)
                    .monospacedDigit()
            }
            .font(.rowDetail.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? PortSQLPalette.ink : PortSQLPalette.muted)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.control)
            .background(selected ? PortSQLPalette.surface : Color.clear, in: Capsule())
            .overlay {
                Capsule().strokeBorder(targeted ? PortSQLPalette.accent : (selected ? PortSQLPalette.stroke : Color.clear), lineWidth: targeted ? 2 : 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // Dropping a chart on a page tab moves it to the end of that page.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation { libraryStore.moveChart(id, toPage: page.id, before: nil) }
            return true
        } isTargeted: { targetedPage = $0 ? page.id : (targetedPage == page.id ? nil : targetedPage) }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                pageName = page.title
                namingPage = .rename(page)
            }
            Button("Filters…", systemImage: "line.3.horizontal.decrease.circle") { editingFilters = page }
            if pages.count > 1 {
                Divider()
                Button("Delete Page…", systemImage: "trash", role: .destructive) { deletingPage = page }
            }
        }
    }

    private func savePageName() {
        let name = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { namingPage = nil }
        guard !name.isEmpty, let namingPage else { return }
        switch namingPage {
        case .new: libraryStore.addChartPage(title: name)
        case .rename(let page): libraryStore.renameChartPage(page.id, to: name)
        }
    }

    // MARK: Filters

    private func pageParameters(_ page: ChartPage) -> [String] {
        var names = Set<String>()
        for chart in libraryStore.charts(onPage: page.id) {
            let engine = ChartQueryRunner.profile(for: chart, lookup: { bookmarks.bookmark(with: $0) }, fallback: fallbackBookmark)?.engine ?? .postgresql
            names.formUnion(ChartQueryRunner.parameters(for: chart, engine: engine))
        }
        return names.sorted()
    }

    private var filterBar: some View {
        let page = currentPage
        let parameters = pageParameters(page).filter { $0 != ChartPage.startParameter && $0 != ChartPage.endParameter }
        return HStack(spacing: Spacing.s) {
            Menu {
                Button { libraryStore.setChartPageFilters(page.id, dateRange: nil, values: page.parameterValues) } label: {
                    if page.dateRange == nil { Label("All Time", systemImage: "checkmark") } else { Text("All Time") }
                }
                Divider()
                ForEach(ChartDateRange.Preset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        libraryStore.setChartPageFilters(page.id, dateRange: ChartDateRange(preset: preset), values: page.parameterValues)
                    } label: {
                        if page.dateRange?.preset == preset { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                    }
                }
                Divider()
                Button("Custom Range…") { editingFilters = page }
            } label: {
                filterChip(systemImage: "calendar", text: page.dateRange?.title ?? L10n.text("All Time"), active: page.dateRange != nil)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Date Range")

            ForEach(parameters, id: \.self) { name in
                Button { editingFilters = page } label: {
                    let value = page.parameterValues?[name]
                    filterChip(systemImage: "character.cursor.ibeam", text: ":" + name + " = " + (value ?? "—"), active: value != nil, warning: value == nil)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            RefreshAllButton(progress: refresh) { refresh.start(count: charts.count) }
        }
    }

    private func filterChip(systemImage: String, text: String, active: Bool, warning: Bool = false) -> some View {
        Label(text, systemImage: systemImage)
            .font(.captionStrong)
            .lineLimit(1)
            .foregroundStyle(warning ? Color.orange : (active ? PortSQLPalette.accent : PortSQLPalette.ink))
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.control)
            .background(active ? PortSQLPalette.accent.opacity(0.1) : PortSQLPalette.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(warning ? Color.orange.opacity(0.6) : (active ? PortSQLPalette.accent.opacity(0.4) : PortSQLPalette.stroke)) }
            .contentShape(Capsule())
    }

    private var emptyPage: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "rectangle.3.group").font(.emptyStateSymbol).foregroundStyle(PortSQLPalette.muted)
            Text("No charts on this page").font(.rowTitle)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .portbaseCardSurface()
    }
}

// MARK: - Tile

private struct ChartTile: View {
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    let preset: SavedVisualizationPreset
    let profile: ConnectionProfile?
    let page: ChartPage
    let pages: [ChartPage]
    /// Shared with the page: Refresh All starts every tile, and Stop cancels them. Not observed, so the
    /// count of finished charts never redraws the tiles themselves.
    let refresh: ChartRefreshProgress
    /// The page's width, to turn a drag into 24ths of the page.
    let pageWidth: CGFloat
    let onEdit: () -> Void

    @State private var entry: CachedChartResult?
    @State private var hasLoadedCache = false
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?
    /// Set when the stored result was from an earlier query, connection or database and was set aside.
    @State private var queryChanged = false
    @State private var runError: String?
    @State private var previewAction: ChartPreviewAction?
    @State private var resize: (height: Double, span: Int)?
    private var resizeUnit: CGFloat { ChartTileLayout.unit(for: pageWidth, spacing: Spacing.l) }
    @State private var isTargeted = false
    @State private var isConfirmingDelete = false
    @State private var showsFullSize = false

    private var height: Double { resize?.height ?? preset.resolvedTileHeight }
    private var engine: DatabaseEngine { profile?.engine ?? .postgresql }
    private var hasQuery: Bool { ChartQueryRunner.query(for: preset) != nil }

    private var filterSignature: [String: String] { ChartQueryRunner.filterSignature(for: preset, engine: engine, page: page) }

    private var filtersChanged: Bool {
        guard let entry, !filterSignature.isEmpty || entry.parameterValues?.isEmpty == false else { return false }
        return (entry.parameterValues ?? [:]) != filterSignature
    }

    /// The query's own trailing LIMIT when the result stopped exactly at it.
    private var rowLimit: Int? {
        guard !preset.usesUnlimitedRows, let entry, let sql = preset.sourceQuery,
              let limit = ChartQueryRunner.trailingLimit(in: sql), entry.result.rows.count == limit else { return nil }
        return limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            content
            footer
        }
        .padding(Spacing.m)
        .frame(height: height)
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isTargeted ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: isTargeted ? 2 : 1)
        }
        .overlay(alignment: .trailing) { resizeEdge(width: true, height: false) }
        .overlay(alignment: .bottom) { resizeEdge(width: false, height: true) }
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .layoutValue(key: ChartTileSpan.self, value: resize?.span ?? preset.gridSpan)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != preset.id else { return false }
            withAnimation(.easeOut(duration: 0.2)) { libraryStore.moveChart(id, toPage: page.id, before: preset.id) }
            return true
        } isTargeted: { isTargeted = $0 }
        .task(id: ChartResultSource(preset)) {
            // A result from before the query, connection or database changed isn't this chart's data.
            let cached = await ChartResultCache.shared.entry(for: preset.id)
            entry = cached.flatMap { $0.matches(preset) ? $0 : nil }
            queryChanged = cached != nil && entry == nil
            hasLoadedCache = true
        }
        .onReceive(refresh.$generation.dropFirst()) { generation in
            guard hasQuery, profile != nil else { refresh.finish(generation); return }
            start(reportingTo: generation)
        }
        .onReceive(refresh.$cancellation.dropFirst()) { _ in runTask?.cancel() }
        .onDisappear { runTask?.cancel() }
        .sheet(isPresented: $showsFullSize) {
            if let entry {
                ChartFullSizeView(preset: preset, result: entry.result, fetchedAt: entry.fetchedAt)
            }
        }
        .alert("Delete Chart", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { libraryStore.deleteVisualization(preset) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move this chart to Recently Deleted?")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(preset.tileTitle)
                    .font(.rowTitle.weight(.semibold))
                    .foregroundStyle(PortSQLPalette.ink)
                    .lineLimit(1)
                Text([preset.connectionName, preset.databaseName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.captionText)
                    .foregroundStyle(PortSQLPalette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Drag a chart by its title to reorder it or move it to another page.
            .draggable(preset.id.uuidString) {
                Label(preset.tileTitle, systemImage: preset.chartType.symbolName)
                    .font(.rowTitle)
                    .padding(Spacing.m)
                    .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.control))
            }
            .accessibilityElement(children: .combine)

            Button {
                if isRunning { runTask?.cancel() } else { start() }
            } label: {
                Group {
                    if isRunning { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .font(.captionStrong)
                .foregroundStyle(PortSQLPalette.ink)
                .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && (!hasQuery || profile == nil))
            .accessibilityLabel(isRunning ? L10n.text("Stop") : L10n.format("Run %@ chart query", preset.tileTitle))

            menu
        }
        .padding(.top, -Spacing.xs)
        .padding(.trailing, -Spacing.s)
    }

    private var menu: some View {
        Menu {
            Button("Edit Chart…", systemImage: "slider.horizontal.3", action: onEdit)
            Button("Open Full Size", systemImage: "arrow.up.left.and.arrow.down.right") { showsFullSize = true }
                .disabled(entry == nil)
            Button("Duplicate", systemImage: "plus.square.on.square") { withAnimation { libraryStore.duplicateChart(preset.id) } }
            Button("Inspect", systemImage: "scope") { previewAction = .inspect }
                .disabled(entry == nil)
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Export PNG") { previewAction = .export(.png) }
                Button("Export PDF") { previewAction = .export(.pdf) }
            }
            .disabled(entry == nil)
            Divider()
            Menu("Display As", systemImage: preset.displayKindSymbol) {
                ForEach(VisualizationChartType.allCases) { chartType in
                    Button {
                        libraryStore.setChartDisplay(preset.id, chartType: chartType, presentation: nil)
                    } label: {
                        if preset.presentation == nil && preset.chartType == chartType { Label(chartType.title, systemImage: "checkmark") }
                        else { Label(chartType.title, systemImage: chartType.symbolName) }
                    }
                }
                Divider()
                ForEach(ChartPresentation.allCases) { presentation in
                    Button {
                        libraryStore.setChartDisplay(preset.id, chartType: nil, presentation: presentation)
                    } label: {
                        if preset.presentation == presentation { Label(presentation.title, systemImage: "checkmark") }
                        else { Label(presentation.title, systemImage: presentation.symbolName) }
                    }
                }
            }
            Menu("Show", systemImage: "line.3.horizontal.decrease") {
                Button { libraryStore.setChartTopLimit(preset.id, nil) } label: {
                    if preset.topLimit == nil { Label("All", systemImage: "checkmark") } else { Text("All") }
                }
                // The common choices, plus the chart's own value when it was set to something else in the editor.
                ForEach(Array(Set([3, 5, 10, 20, 50] + (preset.topLimit.map { [$0] } ?? []))).sorted(), id: \.self) { limit in
                    Button { libraryStore.setChartTopLimit(preset.id, limit) } label: {
                        if preset.topLimit == limit { Label(L10n.format("Top %d", limit), systemImage: "checkmark") }
                        else { Text(L10n.format("Top %d", limit)) }
                    }
                }
            }
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                Button { libraryStore.updateChart(preset.id) { $0.sortOrder = nil } } label: {
                    if preset.sortOrder == nil { Label("Query Order", systemImage: "checkmark") } else { Text("Query Order") }
                }
                ForEach(ChartSortOrder.allCases) { order in
                    Button { libraryStore.updateChart(preset.id) { $0.sortOrder = order } } label: {
                        if preset.sortOrder == order { Label(order.title, systemImage: "checkmark") } else { Text(order.title) }
                    }
                }
            }
            Toggle(isOn: Binding(get: { preset.showsValues }, set: { value in libraryStore.updateChart(preset.id) { $0.showsValues = value } })) {
                Label("Show Values", systemImage: "number")
            }
            Menu("Legend", systemImage: "list.bullet.rectangle") {
                ForEach(ChartLegendPosition.allCases) { position in
                    Button {
                        libraryStore.updateChart(preset.id) { $0.showsLegend = true; $0.legendPosition = position == .bottom ? nil : position }
                    } label: {
                        let selected = preset.showsLegend && (preset.legendPosition ?? .bottom) == position
                        if selected { Label(position.title, systemImage: "checkmark") } else { Text(position.title) }
                    }
                }
                Button {
                    libraryStore.setChartShowsLegend(preset.id, false)
                } label: {
                    if preset.showsLegend { Text("Hidden") } else { Label("Hidden", systemImage: "checkmark") }
                }
            }
            Menu("Size", systemImage: "arrow.up.left.and.arrow.down.right") {
                ForEach(ChartTileSize.allCases) { size in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { libraryStore.resizeChart(preset.id, height: size.height, span: size.span) }
                    } label: {
                        if size.matches(preset) { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                    }
                }
            }
            if pages.count > 1 {
                Menu("Move to Page", systemImage: "rectangle.portrait.and.arrow.right") {
                    ForEach(pages.filter { $0.id != page.id }) { target in
                        Button(target.title) { withAnimation { libraryStore.moveChart(preset.id, toPage: target.id, before: nil) } }
                    }
                }
            }
            Button("Move Earlier", systemImage: "arrow.left") { move(by: -1) }
                .disabled(index == 0)
            Button("Move Later", systemImage: "arrow.right") { move(by: 1) }
                .disabled(index == nil || index == libraryStore.charts(onPage: page.id).count - 1)
            Divider()
            Button("Delete Chart…", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.captionStrong)
                .foregroundStyle(PortSQLPalette.ink)
                .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L10n.format("Edit %@ chart", preset.tileTitle))
    }

    private var index: Int? { libraryStore.charts(onPage: page.id).firstIndex { $0.id == preset.id } }

    private func move(by offset: Int) {
        let ordered = libraryStore.charts(onPage: page.id)
        guard let index, ordered.indices.contains(index + offset) else { return }
        // Moving later means going before the chart after the next one.
        let target = offset < 0 ? ordered[index + offset].id : (ordered.indices.contains(index + 2) ? ordered[index + 2].id : nil)
        withAnimation(.easeOut(duration: 0.2)) { libraryStore.moveChart(preset.id, toPage: page.id, before: target) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let runError {
            message(L10n.text("Execution failed"), runError, systemImage: "exclamationmark.triangle", tint: .red)
        } else if let entry {
            VisualizationChartPreview(preset: preset, result: entry.result, compact: true, action: $previewAction)
                .frame(maxHeight: .infinity)
        } else if !hasQuery {
            message(L10n.text("Chart query missing"), L10n.text("Edit this chart and save a SQL query before running it."),
                    systemImage: "chart.bar.xaxis", action: (L10n.text("Edit Chart"), onEdit))
        } else if profile == nil {
            message(L10n.text("Connection unavailable"), L10n.text("Edit this chart and choose a saved database connection."),
                    systemImage: "chart.bar.xaxis", action: (L10n.text("Edit Chart"), onEdit))
        } else if isRunning || !hasLoadedCache {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if queryChanged {
            message(L10n.text("Query changed"), L10n.text("The last result came from an earlier query or connection. Run the chart to load its current data."),
                    systemImage: "arrow.triangle.2.circlepath", action: (L10n.text("Run Preview"), { start() }))
        } else {
            message(L10n.text("Preview not loaded"), L10n.text("Run the saved query when you want to refresh this chart."),
                    systemImage: "chart.bar.xaxis", action: (L10n.text("Run Preview"), { start() }))
        }
    }

    private func message(_ title: String, _ detail: String, systemImage: String, tint: Color = PortSQLPalette.muted,
                         action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: systemImage).font(.toolSymbol).foregroundStyle(tint)
            Text(title).font(.rowTitle)
            Text(detail).font(.footnoteText).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(4)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.portbaseSecondary)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var footer: some View {
        if let entry {
            HStack(spacing: Spacing.s) {
                Text(L10n.format("Updated %@", entry.fetchedAt.formatted(.relative(presentation: .named))))
                if filtersChanged {
                    Label("Filters changed", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                if let rowLimit {
                    Button {
                        var updated = preset
                        updated.usesUnlimitedRows = true
                        libraryStore.saveVisualization(updated)
                        start(updated)
                    } label: {
                        Text(L10n.format("First %d rows · Load All", rowLimit)).foregroundStyle(PortSQLPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .font(.microText)
            .foregroundStyle(PortSQLPalette.muted)
            .lineLimit(1)
            .padding(.trailing, Spacing.xl)
        }
    }

    // MARK: Resizing

    /// Drag the corner to resize freely: height in 10-point steps, width in 24ths of the page.
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(PortSQLPalette.muted.opacity(resize == nil ? 0.7 : 1))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .gesture(resizeGesture(width: true, height: true))
            .resizePointer(.bottomTrailing)
            .accessibilityHidden(true)
    }

    /// The right edge resizes the width and the bottom edge the height.
    private func resizeEdge(width: Bool, height: Bool) -> some View {
        Color.clear
            .frame(width: width ? 8 : nil, height: height ? 8 : nil)
            .frame(maxWidth: height ? .infinity : nil, maxHeight: width ? .infinity : nil)
            .padding(width ? .vertical : .horizontal, 28)
            .contentShape(Rectangle())
            .gesture(resizeGesture(width: width, height: height))
            .resizePointer(width ? .trailing : .bottom)
            .accessibilityHidden(true)
    }

    private func resizeGesture(width: Bool, height: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { drag in
                let newHeight = height
                    ? SavedVisualizationPreset.clampedTileHeight(preset.resolvedTileHeight + drag.translation.height)
                    : resize?.height ?? preset.resolvedTileHeight
                // Start from the width the tile is drawn at, which narrow screens may have widened.
                let start = ChartTileLayout.effectiveSpan(preset.gridSpan, width: pageWidth, spacing: Spacing.l)
                let newSpan = width && resizeUnit > 0
                    ? SavedVisualizationPreset.clampedGridSpan(start + Int((drag.translation.width / resizeUnit).rounded()))
                    : resize?.span ?? preset.gridSpan
                resize = (newHeight, newSpan)
            }
            .onEnded { _ in
                guard let resize else { return }
                libraryStore.resizeChart(preset.id, height: (resize.height / 10).rounded() * 10, span: resize.span)
                self.resize = nil
            }
    }

    // MARK: Running

    /// Runs the chart's query; a Refresh All generation is reported back to the page when it ends either way.
    private func start(_ chart: SavedVisualizationPreset? = nil, reportingTo generation: Int? = nil) {
        guard !isRunning else {
            if let generation { refresh.finish(generation) }
            return
        }
        let chart = chart ?? preset
        isRunning = true
        runError = nil
        runTask = Task {
            do {
                let result = try await ChartQueryRunner.run(chart, profile: profile, pageValues: page.boundValues())
                entry = ChartResultCache.shared.store(result, for: chart.id, source: ChartResultSource(chart),
                                                      parameterValues: ChartQueryRunner.filterSignature(for: chart, engine: engine, page: page))
                queryChanged = false
            } catch is CancellationError {
                // Stopped by the person; the previous result stays.
            } catch {
                runError = Task.isCancelled ? nil : error.localizedDescription
            }
            isRunning = false
            runTask = nil
            if let generation { refresh.finish(generation) }
        }
    }
}

/// A chart at full size, with its date range, inspection, and export tools.
private struct ChartFullSizeView: View {
    @Environment(\.dismiss) private var dismiss
    let preset: SavedVisualizationPreset
    let result: QueryResultTable
    let fetchedAt: Date

    var body: some View {
        PortbaseSheet(preset.tileTitle, subtitle: [preset.connectionName, preset.databaseName,
                                                     L10n.format("Updated %@", fetchedAt.formatted(.relative(presentation: .named)))]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")) {
            ScrollView {
                VisualizationChartPreview(preset: preset, result: result, compact: false, plotHeight: 520)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.l)
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
#if os(macOS)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 680, idealHeight: 760)
#else
        .presentationDetents([.large])
#endif
    }
}

/// Preset tile sizes, also offered in the tile menu for keyboard and VoiceOver users.
private enum ChartTileSize: String, CaseIterable, Identifiable {
    case small, medium, large, wide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: L10n.text("Small")
        case .medium: L10n.text("Medium")
        case .large: L10n.text("Large")
        case .wide: L10n.text("Full Width")
        }
    }

    var height: Double {
        switch self {
        case .small: 240
        case .medium: SavedVisualizationPreset.defaultTileHeight
        case .large: 440
        case .wide: 400
        }
    }

    /// Widths in 24ths of the page: a quarter, a third, a half, and the full width.
    var span: Int {
        switch self {
        case .small: 6
        case .medium: 8
        case .large: 12
        case .wide: 24
        }
    }

    func matches(_ preset: SavedVisualizationPreset) -> Bool {
        preset.gridSpan == span && abs(preset.resolvedTileHeight - height) < 1
    }
}

// MARK: - Layout

struct ChartTileSpan: LayoutValueKey {
    static let defaultValue = 8
}

/// Rows of tiles on a 24-column grid. Each tile is as wide as its span asks, but never narrower than
/// a readable minimum, and starts a new row when it doesn't fit beside the previous one.
struct ChartTileLayout: Layout {
    var spacing: CGFloat

    static let minimumTileWidth: CGFloat = 280

    /// The width of one 24th of the page, including its share of the gaps.
    static func unit(for width: CGFloat, spacing: CGFloat) -> CGFloat {
        max(0, (width + spacing) / CGFloat(SavedVisualizationPreset.gridColumns))
    }

    /// The span a tile is drawn at: its own, widened to the minimum width on narrow pages.
    static func effectiveSpan(_ span: Int, width: CGFloat, spacing: CGFloat) -> Int {
        let unit = unit(for: width, spacing: spacing)
        guard unit > 0 else { return SavedVisualizationPreset.gridColumns }
        let columns = SavedVisualizationPreset.gridColumns
        let minimum = Int(((minimumTileWidth + spacing) / unit).rounded(.up))
        let span = min(columns, max(span, minimum))
        // A gap too narrow for another tile would stay empty, so the tile takes the whole row instead.
        return columns - span < minimum ? columns : span
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let frames = arrange(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    func arrange(width: CGFloat, spans: [Int], heights: [CGFloat]) -> [CGRect] {
        let columns = SavedVisualizationPreset.gridColumns
        let unit = Self.unit(for: width, spacing: spacing)
        var frames: [CGRect] = []
        var column = 0
        var rowY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (span, height) in zip(spans, heights) {
            let span = Self.effectiveSpan(span, width: width, spacing: spacing)
            if column + span > columns, column > 0 {
                rowY += rowHeight + spacing
                column = 0
                rowHeight = 0
            }
            frames.append(CGRect(x: CGFloat(column) * unit, y: rowY, width: max(0, CGFloat(span) * unit - spacing), height: height))
            rowHeight = max(rowHeight, height)
            column += span
        }
        return frames
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let unit = Self.unit(for: width, spacing: spacing)
        let spans = subviews.map { $0[ChartTileSpan.self] }
        let heights = subviews.indices.map { index in
            let span = Self.effectiveSpan(spans[index], width: width, spacing: spacing)
            return subviews[index].sizeThatFits(ProposedViewSize(width: CGFloat(span) * unit - spacing, height: nil)).height
        }
        return arrange(width: width, spans: spans, heights: heights)
    }
}

private enum TileResizeEdge { case trailing, bottom, bottomTrailing }

private extension View {
    /// The Mac's resize cursor over a tile's edges and corner.
    @ViewBuilder func resizePointer(_ edge: TileResizeEdge) -> some View {
#if os(macOS)
        switch edge {
        case .trailing: pointerStyle(.frameResize(position: .trailing))
        case .bottom: pointerStyle(.frameResize(position: .bottom))
        case .bottomTrailing: pointerStyle(.frameResize(position: .bottomTrailing))
        }
#else
        self
#endif
    }
}

// MARK: - Page filters

private struct ChartPageFiltersSheet: View {
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @Environment(\.dismiss) private var dismiss
    let page: ChartPage
    let parameters: [String]
    @State private var usesDateRange: Bool
    @State private var preset: ChartDateRange.Preset
    @State private var start: Date
    @State private var end: Date
    @State private var values: [String: String]

    init(page: ChartPage, parameters: [String]) {
        self.page = page
        self.parameters = parameters.filter { $0 != ChartPage.startParameter && $0 != ChartPage.endParameter }
        let range = page.dateRange ?? ChartDateRange(preset: .last30Days)
        let interval = range.interval()
        _usesDateRange = State(initialValue: page.dateRange != nil)
        _preset = State(initialValue: range.preset)
        _start = State(initialValue: interval.start)
        _end = State(initialValue: interval.end)
        _values = State(initialValue: page.parameterValues ?? [:])
    }

    var body: some View {
        PortbaseSheet(L10n.text("Page Filters"), subtitle: page.title) {
            Form {
                Section {
                    Toggle("Date range", isOn: $usesDateRange.animation())
                    if usesDateRange {
                        Picker("Range", selection: $preset) {
                            ForEach(ChartDateRange.Preset.allCases) { Text($0.title).tag($0) }
                        }
                        if preset == .custom {
                            DatePicker("From", selection: $start)
                            DatePicker("Through", selection: $end, in: start...)
                        }
                    }
                } footer: {
                    Text("Charts on this page receive the range as :start and :end, in UTC. Use them in a query, for example WHERE created_at >= :start AND created_at < :end.")
                }
                if !parameters.isEmpty {
                    Section {
                        ForEach(parameters, id: \.self) { name in
                            LabeledContent {
                                TextField("Value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                    .multilineTextAlignment(.trailing)
                                    .portbaseTextCapitalization(.never)
                                    .autocorrectionDisabled()
                            } label: {
                                Text(verbatim: ":" + name).font(.codeText)
                            }
                        }
                    } header: {
                        Text("Parameters")
                    }
                }
            }
            .portbaseForm()
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                let range = usesDateRange ? ChartDateRange(preset: preset, start: preset == .custom ? start : nil, end: preset == .custom ? end : nil) : nil
                // Empty fields clear a value rather than binding an empty string.
                let kept = values.filter { !$0.value.isEmpty }
                libraryStore.setChartPageFilters(page.id, dateRange: range, values: kept.isEmpty ? nil : kept)
                dismiss()
            }
            .buttonStyle(.portbasePrimary)
            .keyboardShortcut(.defaultAction)
        }
        .portbaseSheetNavigation()
#if os(macOS)
        .frame(width: 480)
        .frame(minHeight: 420)
#else
        .presentationDetents([.medium, .large])
#endif
    }
}

// MARK: - Refresh All

/// How far a Refresh All has got, so the page can show its progress and stop it.
@MainActor final class ChartRefreshProgress: ObservableObject {
    @Published private(set) var generation = 0
    @Published private(set) var cancellation = 0
    @Published private(set) var total = 0
    @Published private(set) var finished = 0

    var isRefreshing: Bool { finished < total }

    func start(count: Int) {
        guard count > 0 else { return }
        total = count
        finished = 0
        generation += 1
    }

    func finish(_ generation: Int) {
        guard generation == self.generation, isRefreshing else { return }
        finished += 1
    }

    func cancel() {
        cancellation += 1
        total = 0
        finished = 0
    }
}

/// Refresh All, which turns into the run's progress and a Stop button while charts are loading.
private struct RefreshAllButton: View {
    @ObservedObject var progress: ChartRefreshProgress
    let start: () -> Void

    var body: some View {
        Button {
            if progress.isRefreshing { progress.cancel() } else { start() }
        } label: {
            Group {
                if progress.isRefreshing {
                    HStack(spacing: Spacing.xs) {
                        ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text(L10n.format("%1$d of %2$d", progress.finished, progress.total)).monospacedDigit()
                        Image(systemName: "stop.fill")
                    }
                } else {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
            }
            .font(.captionStrong)
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: Sizes.control)
            .background(PortSQLPalette.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(PortSQLPalette.stroke) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(PortSQLPalette.ink)
        .accessibilityLabel(progress.isRefreshing ? L10n.text("Stop") : L10n.text("Refresh All"))
        .accessibilityValue(progress.isRefreshing ? L10n.format("%1$d of %2$d", progress.finished, progress.total) : "")
        .accessibilityHint(progress.isRefreshing ? "" : L10n.text("Runs every chart query on this page"))
    }
}
