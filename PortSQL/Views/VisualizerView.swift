import Charts
import SwiftUI

struct VisualizerComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @EnvironmentObject private var bookmarks: BookmarkStore

    @State private var draft: SavedVisualizationPreset
    @State private var draftQueryCursorOffset = 0
    @State private var draftQuerySelectionLength = 0
    @State private var expandedPreviewResult: QueryResultTable?
    @State private var isLoadingExpandedPreview = false
    @State private var expandedPreviewError: String?
    @State private var isConfirmingDelete = false

    init(initialPreset: SavedVisualizationPreset) {
        var preset = initialPreset
        // A stale generated title from an earlier version is replaced by one for the current setup.
        preset.title = initialPreset.displayTitle
        _draft = State(initialValue: preset)
        initialGeneratedTitle = VisualizationService.generatedTitle(chartType: initialPreset.chartType, xField: initialPreset.xField,
                                                                    yFields: initialPreset.resolvedYFields, source: nil)
        // Earlier versions generated "source • Bar • total by country".
        let metrics = initialPreset.resolvedYFields
        let legacyMetric = metrics.count > 2 ? "\(metrics[0]) + \(metrics.count - 1)" : metrics.joined(separator: " + ")
        legacyGeneratedSuffix = "\(initialPreset.chartType.title) • \(legacyMetric) by \(initialPreset.xField)"
    }

    /// The titles this chart would have been given, so a title nobody edited follows the setup.
    private let initialGeneratedTitle: String
    private let legacyGeneratedSuffix: String
    @State private var cachedPreview: QueryResultTable?

    private var previewResult: QueryResultTable {
        expandedPreviewResult ?? (isStoredPreset ? cachedPreview ?? libraryStore.cachedVisualizationPreview(for: draft.id) ?? .empty : workspace.result)
    }

    private var fields: [VisualizationFieldDescriptor] {
        VisualizationService.fieldDescriptors(for: previewResult)
    }

    private var numericFields: [VisualizationFieldDescriptor] {
        fields.filter(\.supportsNumeric)
    }

    private var selectedYFieldsSummary: String {
        draft.yFieldsSummary.isEmpty ? L10n.text("Select") : draft.yFieldsSummary
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { draft.sourceQuery ?? "" },
            set: { draft.sourceQuery = $0 }
        )
    }

    private var previewBookmark: ConnectionProfile? {
        if let id = draft.connectionProfileID { return bookmarks.bookmark(with: id) }
        return workspace.selectedBookmark
    }

    private var isStoredPreset: Bool {
        libraryStore.visualizations.contains(where: { $0.id == draft.id })
    }

    var body: some View {
        PortbaseSheet(L10n.text("Chart Config")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            SectionHeader(title: L10n.text("Add to Visualizer"))

                            LabeledVisualizerTextField(
                                label: L10n.text("Preset Name"),
                                placeholder: L10n.text("Saved chart name"),
                                text: $draft.title
                            )

                            LabeledVisualizerTextField(
                                label: L10n.text("Chart Title"),
                                placeholder: L10n.text("Title shown on the chart"),
                                text: $draft.chartTitle
                            )

                            VStack(alignment: .leading, spacing: Spacing.m) {
                                HStack(alignment: .center, spacing: Spacing.s) {
                                    Text("Query")
                                        .font(.rowTitle)
                                        .foregroundStyle(PortSQLPalette.ink)
                                    Spacer()
                                    if previewBookmark?.engine.isRelational != false {
                                      Menu {
                                        Button("Remove LIMIT / OFFSET") {
                                            let cleaned = VisualizationService.queryWithoutLimitAndOffset(queryBinding.wrappedValue)
                                            queryBinding.wrappedValue = cleaned
                                        }
                                        .disabled(queryBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                        Button("Remove trailing ORDER BY") {
                                            let cleaned = VisualizationService.queryWithoutTrailingOrderBy(queryBinding.wrappedValue)
                                            queryBinding.wrappedValue = cleaned
                                        }
                                        .disabled(queryBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    } label: {
                                        Label("Clean Up", systemImage: "line.3.horizontal.decrease.circle")
                                            .font(.captionStrong)
                                            .foregroundStyle(PortSQLPalette.ink)
                                    }

                                    }
                                    Button {
                                        Task {
                                            await runPreview()
                                        }
                                    } label: {
                                        if isLoadingExpandedPreview {
                                            ProgressView()
                                                .tint(.white)
                                                .frame(minWidth: 74)
                                        } else {
                                            Label("Run Preview", systemImage: "play.fill")
                                        }
                                    }
                                    .buttonStyle(.portbasePrimary)
                                    .disabled(queryBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || previewBookmark == nil)
                                }

                                ZStack(alignment: .topLeading) {
                                    HighlightedQueryEditor(
                                        text: queryBinding,
                                        cursorOffset: $draftQueryCursorOffset,
                                        selectionLength: $draftQuerySelectionLength,
                                        colorScheme: colorScheme,
                                        isJSON: previewBookmark?.engine.usesJSONEditor == true
                                    )
                                        .frame(minHeight: 150)

                                    if queryBinding.wrappedValue.isEmpty {
                                        Text(verbatim: previewBookmark?.engine.queryPlaceholder ?? L10n.text("SQL query"))
                                            .font(.codeText)
                                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                                            .padding(.horizontal, Spacing.l)
                                            .padding(.vertical, Spacing.l)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                                        .fill(PortSQLPalette.editorBackground(for: colorScheme))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.hero, style: .continuous)
                                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                                }

                                if let limit = ChartQueryRunner.trailingLimit(in: queryBinding.wrappedValue) {
                                    Toggle(isOn: $draft.usesUnlimitedRows) {
                                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                            Text("Use All Rows")
                                            Text(L10n.format("Ignores the query's LIMIT %d when the chart runs, up to 10,000 rows.", limit))
                                                .font(.captionText)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                                VisualizationControlMenu(
                                    title: L10n.text("Chart"),
                                    value: draft.displayKindTitle,
                                    systemImage: draft.displayKindSymbol
                                ) {
                                    ForEach(VisualizationChartType.allCases) { chartType in
                                        Button {
                                            draft.chartType = chartType
                                            draft.presentation = nil
                                        } label: {
                                            Label(chartType.title, systemImage: chartType.symbolName)
                                        }
                                    }
                                    Divider()
                                    ForEach(ChartPresentation.allCases) { presentation in
                                        Button {
                                            draft.presentation = presentation
                                        } label: {
                                            Label(presentation.title, systemImage: presentation.symbolName)
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: Spacing.m) {
                                Text("X Axis")
                                    .font(.rowTitle)
                                    .foregroundStyle(PortSQLPalette.ink)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                                    VisualizationControlMenu(
                                        title: L10n.text("Field"),
                                        value: draft.xField,
                                        systemImage: "arrow.left.and.right"
                                    ) {
                                        ForEach(fields) { field in
                                            Button(field.name) {
                                                draft.xField = field.name
                                                if draft.xAxisTitle.isEmpty || draft.xAxisTitle == draft.xField {
                                                    draft.xAxisTitle = field.name
                                                }
                                                let preferredMode = VisualizationService.supportedXModes(for: field).contains(draft.xAxisMode)
                                                    ? draft.xAxisMode
                                                    : VisualizationService.resolvedXMode(for: draft, fields: [field])
                                                draft.xAxisMode = preferredMode
                                            }
                                        }
                                    }

                                    VisualizationControlMenu(
                                        title: L10n.text("Mode"),
                                        value: draft.xAxisMode.title,
                                        systemImage: "timeline.selection"
                                    ) {
                                        ForEach(VisualizationService.supportedXModes(for: selectedXFieldDescriptor)) { mode in
                                            Button(mode.title) {
                                                draft.xAxisMode = mode
                                            }
                                        }
                                    }
                                }

                                LabeledVisualizerTextField(
                                    label: L10n.text("X Label"),
                                    placeholder: L10n.text("XAxis title"),
                                    text: $draft.xAxisTitle
                                )
                            }
                            .padding(.top, Spacing.xxxs)

                            VStack(alignment: .leading, spacing: Spacing.m) {
                                Text("Y Axis")
                                    .font(.rowTitle)
                                    .foregroundStyle(PortSQLPalette.ink)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                                    VisualizationControlMenu(
                                        title: L10n.text("Field"),
                                        value: selectedYFieldsSummary,
                                        systemImage: "arrow.up.and.down"
                                    ) {
                                        ForEach(numericFields) { field in
                                            Button {
                                                toggleYField(field.name)
                                            } label: {
                                                if draft.resolvedYFields.contains(field.name) {
                                                    Label(field.name, systemImage: "checkmark")
                                                } else {
                                                    Text(field.name)
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Clear selection") {
                                            draft.yFields = []
                                            draft.yField = ""
                                        }
                                        .disabled(draft.resolvedYFields.isEmpty)
                                    }
                                }

                                if draft.resolvedYFields.count > 1 {
                                    Label("Multiple metrics stack for bar and area charts.", systemImage: "square.stack.3d.up")
                                        .font(.captionText)
                                        .foregroundStyle(.secondary)
                                }

                                LabeledVisualizerTextField(
                                    label: L10n.text("Y Label"),
                                    placeholder: L10n.text("YAxis title"),
                                    text: $draft.yAxisTitle
                                )
                            }
                            .padding(.top, Spacing.xxxs)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                                VisualizationControlMenu(
                                    title: L10n.text("Group"),
                                    value: draft.groupField ?? L10n.text("None"),
                                    systemImage: "square.3.layers.3d.top.filled"
                                ) {
                                    Button("None") {
                                        draft.groupField = nil
                                    }
                                    ForEach(fields) { field in
                                        Button(field.name) {
                                            draft.groupField = field.name
                                        }
                                    }
                                }

                                VisualizationControlMenu(
                                    title: L10n.text("Labels"),
                                    value: draft.labelField ?? L10n.text("None"),
                                    systemImage: "textformat"
                                ) {
                                    Button("None") {
                                        draft.labelField = nil
                                    }
                                    ForEach(fields) { field in
                                        Button(field.name) {
                                            draft.labelField = field.name
                                        }
                                    }
                                }
                            }

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                                VisualizationControlMenu(
                                    title: L10n.text("Sort"),
                                    value: draft.sortOrder?.title ?? L10n.text("Query Order"),
                                    systemImage: "arrow.up.arrow.down"
                                ) {
                                    Button("Query Order") { draft.sortOrder = nil }
                                    ForEach(ChartSortOrder.allCases) { order in
                                        Button(order.title) { draft.sortOrder = order }
                                    }
                                }
                                if draft.chartType == .bar && draft.presentation == nil {
                                    VisualizationControlMenu(
                                        title: L10n.text("Bars"),
                                        value: (draft.barLayout ?? .stacked).title,
                                        systemImage: "chart.bar.doc.horizontal"
                                    ) {
                                        ForEach(ChartBarLayout.allCases) { layout in
                                            Button(layout.title) { draft.barLayout = layout == .stacked ? nil : layout }
                                        }
                                    }
                                }
                            }
                            if draft.chartType == .bar && draft.presentation == nil {
                                Toggle("Horizontal Bars", isOn: $draft.isHorizontal)
                                    .font(.rowTitle)
                                    .foregroundStyle(PortSQLPalette.ink)
                            }
                            Toggle("Show Values", isOn: $draft.showsValues)
                                .font(.rowTitle)
                                .foregroundStyle(PortSQLPalette.ink)
                            LabeledContent {
                                Picker("Legend", selection: Binding(
                                    get: { draft.showsLegend ? (draft.legendPosition ?? .bottom).rawValue : "hidden" },
                                    set: { choice in
                                        draft.showsLegend = choice != "hidden"
                                        draft.legendPosition = ChartLegendPosition(rawValue: choice).flatMap { $0 == .bottom ? nil : $0 }
                                    })) {
                                    ForEach(ChartLegendPosition.allCases) { Text($0.title).tag($0.rawValue) }
                                    Text("Hidden").tag("hidden")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            } label: {
                                Text("Legend")
                            }
                            .font(.rowTitle)
                            .foregroundStyle(PortSQLPalette.ink)

                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Toggle("Top K", isOn: Binding(
                                    get: { draft.topLimit != nil },
                                    set: { draft.topLimit = $0 ? (draft.topLimit ?? 10) : nil }
                                ))
                                .font(.rowTitle)
                                .foregroundStyle(PortSQLPalette.ink)
                                if let limit = draft.topLimit {
                                    Stepper(value: Binding(get: { limit }, set: { draft.topLimit = SavedVisualizationPreset.clampedTopLimit($0) }),
                                            in: 1...1_000) {
                                        Text(L10n.format("Top %d", limit)).monospacedDigit()
                                    }
                                }
                                Text(draft.presentation == .table
                                     ? L10n.text("Shows the first K rows.")
                                     : L10n.text("Keeps the K largest categories or series; the rest are combined into Other."))
                                    .font(.captionText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            SectionHeader(
                                title: draft.chartTitle.isEmpty ? L10n.text("Preview") : draft.chartTitle,
                                subtitle: previewSubtitle
                            )
                            if let expandedPreviewError {
                                StatusBanner(
                                    title: L10n.text("Preview unavailable"),
                                    message: expandedPreviewError,
                                    tint: .orange
                                )
                            } else {
                                VisualizationChartPreview(
                                    preset: draft,
                                    result: previewResult,
                                    compact: false
                                )
                            }
                        }
                    }

                    if isStoredPreset {
                        PanelCard {
                            VStack(alignment: .leading, spacing: Spacing.m) {
                                Button(role: .destructive) {
                                    isConfirmingDelete = true
                                } label: {
                                    Label("Delete Chart", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.portbaseSecondary)
                                .tint(.red)
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.l)
            }
            .alert("Delete Chart", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    libraryStore.deleteVisualization(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Move this chart to Recently Deleted?")
            }
        } footer: {
            Button("Close") { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button("Save") { saveChart() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
                // A table shows rows as they are; plots and numbers need a numeric metric.
                .disabled(draft.presentation == .table ? fields.isEmpty : (draft.xField.isEmpty || draft.resolvedYFields.isEmpty || numericFields.isEmpty))
        }
        .portbaseSheetNavigation()
        .task {
            // A new chart drops the 100-row limit Explorer adds; a saved chart keeps its choice.
            if !isStoredPreset, !draft.usesUnlimitedRows, ChartQueryRunner.defaultUsesAllRows(for: draft.sourceQuery ?? workspace.result.sourceQuery) {
                draft.usesUnlimitedRows = true
            }
            if isStoredPreset, expandedPreviewResult == nil { cachedPreview = await ChartResultCache.shared.entry(for: draft.id)?.result }
        }
    }

    private func saveChart() {
        var stored = draft
        stored.title = normalizedPresetTitle
        stored.chartTitle = normalizedChartTitle
        stored.xAxisTitle = normalizedXAxisTitle
        stored.yAxisTitle = normalizedYAxisTitle
        stored.yFields = stored.resolvedYFields
        stored.yField = stored.resolvedYFields.first ?? ""
        stored.connectionName = previewBookmark?.name ?? stored.connectionName
        stored.connectionProfileID = previewBookmark?.id ?? stored.connectionProfileID
        stored.databaseName = stored.databaseName ?? workspace.activeDatabaseName
        stored.sourceTableReference = stored.sourceTableReference ?? workspace.result.sourceTableReference
        stored.sourceQuery = stored.sourceQuery ?? workspace.result.sourceQuery
        libraryStore.saveVisualization(stored)
        libraryStore.cacheVisualizationPreview(previewResult, for: stored.id)
        dismiss()
    }

    private var selectedXFieldDescriptor: VisualizationFieldDescriptor {
        fields.first(where: { $0.name == draft.xField }) ?? fields.first ?? VisualizationFieldDescriptor(
            name: L10n.text("Value"),
            sourceType: "",
            nonEmptyCount: 0,
            distinctCount: 0,
            sampleValue: "",
            supportsCategory: true,
            supportsNumeric: false,
            supportsDate: false
        )
    }

    private var previewSubtitle: String {
        let parts = [
            draft.chartType.title,
            draft.resolvedYFields.count > 1 ? L10n.plural("metric_count", count: draft.resolvedYFields.count) : nil,
            draft.groupField.map { L10n.format("Group %@", $0) },
            draft.labelField.map { L10n.format("Label %@", $0) },
            previewResult.sourceTableReference ?? workspace.result.sourceTableReference
        ]
        return parts.compactMap { $0 }.joined(separator: " • ")
    }

    private var normalizedPresetTitle: String {
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep a title someone typed; one generated from the old setup follows the new one.
        if !trimmed.isEmpty, trimmed != initialGeneratedTitle, !trimmed.hasSuffix(legacyGeneratedSuffix) { return trimmed }
        return VisualizationService.generatedTitle(
            chartType: draft.chartType,
            xField: draft.xField,
            yFields: draft.resolvedYFields,
            source: workspace.result.sourceTableReference ?? workspace.selectedBookmark?.name
        )
    }

    private var normalizedChartTitle: String {
        let trimmed = draft.chartTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return draft.sourceTableReference ?? workspace.result.sourceTableReference ?? L10n.text("Saved Visualization")
    }

    private var normalizedXAxisTitle: String {
        let trimmed = draft.xAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? draft.xField : trimmed
    }

    private var normalizedYAxisTitle: String {
        let trimmed = draft.yAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? draft.yFieldsSummary : trimmed
    }

    private func toggleYField(_ fieldName: String) {
        var current = draft.resolvedYFields
        if let index = current.firstIndex(of: fieldName) {
            current.remove(at: index)
        } else {
            current.append(fieldName)
        }
        draft.yFields = current
        draft.yField = current.first ?? ""
        if draft.yAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.yAxisTitle == draft.yField
            || draft.yAxisTitle == draft.yFieldsSummary {
            draft.yAxisTitle = draft.yFieldsSummary
        }
    }

    private func runPreview() async {
        let sourceQuery = queryBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceQuery.isEmpty else {
            expandedPreviewResult = nil
            expandedPreviewError = L10n.text("Chart query missing")
            isLoadingExpandedPreview = false
            return
        }
        guard let bookmark = previewBookmark else {
            expandedPreviewResult = nil
            expandedPreviewError = L10n.text("Choose or save a bookmark before running this visualizer.")
            isLoadingExpandedPreview = false
            return
        }
        isLoadingExpandedPreview = true
        expandedPreviewError = nil
        do {
            var result = try await DatabaseService.shared.execute(
                query: sourceQuery,
                profile: bookmark,
                database: draft.databaseName,
                policy: .readOnly
            )
            result.sourceTableReference = draft.sourceTableReference ?? workspace.result.sourceTableReference
            result.sourceQuery = sourceQuery
            await MainActor.run {
                expandedPreviewResult = result
                expandedPreviewError = nil
                isLoadingExpandedPreview = false
            }
        } catch {
            await MainActor.run {
                expandedPreviewResult = nil
                expandedPreviewError = error.localizedDescription
                isLoadingExpandedPreview = false
            }
        }
    }
}

private struct LabeledVisualizerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(label)
                .font(.captionStrong)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .portbaseTextCapitalization(.words)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(PortSQLPalette.stroke, lineWidth: 1)
                }
        }
    }
}

private struct VisualizationControlMenu<Content: View>: View {
    let title: String
    let value: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(title, systemImage: systemImage)
                    .font(.captionStrong)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? L10n.text("Select") : value)
                    .font(.rowTitle)
                    .foregroundStyle(PortSQLPalette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
