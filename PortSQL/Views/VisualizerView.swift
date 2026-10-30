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
    @State private var isConfirmingDiscard = false
    /// The chart as it opened, to tell whether closing would lose edits.
    @State private var baseline: SavedVisualizationPreset

    init(initialPreset: SavedVisualizationPreset) {
        var preset = initialPreset
        // A stale generated title from an earlier version is replaced by one for the current setup.
        preset.title = initialPreset.displayTitle
        _draft = State(initialValue: preset)
        _baseline = State(initialValue: preset)
        initialQuery = initialPreset.sourceQuery
        initialTableReference = initialPreset.sourceTableReference
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
    private let initialQuery: String?
    private let initialTableReference: String?
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
        PortbaseSheet(L10n.text("Chart Config"), onClose: requestClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChartEditorSection(isFirst: true) {
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
                    }

                    ChartEditorSection(title: L10n.text("Query")) {
                        queryTools
                    } content: {
                        queryEditor

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

                    ChartEditorSection(title: L10n.text("X Axis")) {
                        VisualizationControlMenu(title: L10n.text("Field"), value: draft.xField) {
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

                        VisualizationControlMenu(title: L10n.text("Mode"), value: draft.xAxisMode.title) {
                            ForEach(VisualizationService.supportedXModes(for: selectedXFieldDescriptor)) { mode in
                                Button(mode.title) {
                                    draft.xAxisMode = mode
                                }
                            }
                        }

                        LabeledVisualizerTextField(
                            label: L10n.text("X Label"),
                            placeholder: L10n.text("XAxis title"),
                            text: $draft.xAxisTitle
                        )
                    }

                    ChartEditorSection(title: L10n.text("Y Axis")) {
                        VisualizationControlMenu(title: L10n.text("Field"), value: selectedYFieldsSummary) {
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

                    ChartEditorSection(title: L10n.text("Display")) {
                        displayControls
                            .font(.rowTitle)
                            .foregroundStyle(PortSQLPalette.ink)
                    }

                    ChartEditorSection(title: previewTitle) {
                        if !previewSubtitle.isEmpty {
                            Text(previewSubtitle)
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let expandedPreviewError {
                            ExecutionErrorLine(message: expandedPreviewError)
                        } else {
                            VisualizationChartPreview(
                                preset: draft,
                                result: previewResult,
                                compact: false
                            )
                        }
                    }

                    if isStoredPreset {
                        ChartEditorSection {
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
            .alert("Delete Chart", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    libraryStore.deleteVisualization(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Move this chart to Recently Deleted?")
            }
            .alert("Discard changes to this chart?", isPresented: $isConfirmingDiscard) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        } footer: {
            Button("Close") { requestClose() }
                .buttonStyle(.portbaseSecondary)
            Button("Save") { saveChart() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
                // A table shows rows as they are; plots and numbers need a numeric metric.
                .disabled(draft.presentation == .table ? fields.isEmpty : (draft.xField.isEmpty || draft.resolvedYFields.isEmpty || numericFields.isEmpty))
        }
        .portbaseSheetNavigation()
        // Swiping the sheet away would discard edits without asking.
        .interactiveDismissDisabled(hasChanges)
        .task {
            // A new chart drops the 100-row limit Explorer adds; a saved chart keeps its choice.
            if !isStoredPreset, !draft.usesUnlimitedRows, ChartQueryRunner.defaultUsesAllRows(for: draft.sourceQuery ?? workspace.result.sourceQuery) {
                draft.usesUnlimitedRows = true
                baseline.usesUnlimitedRows = true
            }
            if isStoredPreset, expandedPreviewResult == nil { cachedPreview = await ChartResultCache.shared.entry(for: draft.id)?.result }
        }
    }

    @ViewBuilder private var queryTools: some View {
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
            .portbaseToolbarMenu()
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

    private var queryEditor: some View {
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
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(PortSQLPalette.editorBackground(for: colorScheme))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
        }
    }

    @ViewBuilder private var displayControls: some View {
        VisualizationControlMenu(title: L10n.text("Chart"), value: draft.displayKindTitle) {
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

        VisualizationControlMenu(title: L10n.text("Group"), value: draft.groupField ?? L10n.text("None")) {
            Button("None") {
                draft.groupField = nil
            }
            ForEach(fields) { field in
                Button(field.name) {
                    draft.groupField = field.name
                }
            }
        }

        VisualizationControlMenu(title: L10n.text("Labels"), value: draft.labelField ?? L10n.text("None")) {
            Button("None") {
                draft.labelField = nil
            }
            ForEach(fields) { field in
                Button(field.name) {
                    draft.labelField = field.name
                }
            }
        }

        VisualizationControlMenu(title: L10n.text("Sort"), value: draft.sortOrder?.title ?? L10n.text("Query Order")) {
            Button("Query Order") { draft.sortOrder = nil }
            ForEach(ChartSortOrder.allCases) { order in
                Button(order.title) { draft.sortOrder = order }
            }
        }

        if draft.chartType == .bar && draft.presentation == nil {
            VisualizationControlMenu(title: L10n.text("Bars"), value: (draft.barLayout ?? .stacked).title) {
                ForEach(ChartBarLayout.allCases) { layout in
                    Button(layout.title) { draft.barLayout = layout == .stacked ? nil : layout }
                }
            }
            Toggle("Horizontal Bars", isOn: $draft.isHorizontal)
        }
        Toggle("Show Values", isOn: $draft.showsValues)
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

        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle("Top K", isOn: Binding(
                get: { draft.topLimit != nil },
                set: { draft.topLimit = $0 ? (draft.topLimit ?? 10) : nil }
            ))
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

    private var hasChanges: Bool { draft != baseline }

    /// Escape, the close button, and Close ask before throwing edits away.
    private func requestClose() {
        if hasChanges { isConfirmingDiscard = true } else { dismiss() }
    }

    /// The table the chart reads. A changed query names its own table rather than keeping the one the
    /// chart was opened with.
    private var currentTableReference: String? {
        let query = (draft.sourceQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query == (initialQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
            return draft.sourceTableReference ?? (isStoredPreset ? nil : workspace.result.sourceTableReference)
        }
        guard previewBookmark?.engine.isRelational != false else { return draft.sourceTableReference }
        return VisualizationService.inferredTableReference(in: query)
    }

    /// The chart title, without one generated from a table the changed query no longer reads.
    private var effectiveChartTitle: String {
        let trimmed = draft.chartTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initialTableReference, trimmed == initialTableReference, currentTableReference != initialTableReference { return "" }
        return trimmed
    }

    private var previewTitle: String {
        var shown = draft
        shown.chartTitle = effectiveChartTitle
        shown.sourceTableReference = currentTableReference
        let title = shown.tileTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.text("Preview") : title
    }

    private func saveChart() {
        var stored = draft
        stored.title = normalizedPresetTitle
        stored.chartTitle = effectiveChartTitle
        stored.xAxisTitle = normalizedXAxisTitle
        stored.yAxisTitle = normalizedYAxisTitle
        stored.yFields = stored.resolvedYFields
        stored.yField = stored.resolvedYFields.first ?? ""
        stored.connectionName = previewBookmark?.name ?? stored.connectionName
        stored.connectionProfileID = previewBookmark?.id ?? stored.connectionProfileID
        stored.databaseName = stored.databaseName ?? workspace.activeDatabaseName
        stored.sourceTableReference = currentTableReference
        stored.sourceQuery = stored.sourceQuery ?? workspace.result.sourceQuery
        // Read before saving: once the chart is stored, `previewResult` reads the stored chart's cache instead.
        let preview = previewResult
        libraryStore.saveVisualization(stored)
        if VisualizationService.isCompatible(stored, with: preview) { libraryStore.cacheVisualizationPreview(preview, for: stored.id) }
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
            currentTableReference
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
            source: currentTableReference ?? previewBookmark?.name
        )
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
            result.sourceTableReference = currentTableReference
            result.sourceQuery = sourceQuery
            await MainActor.run {
                // Fields the new result lacks are dropped, and labels nobody edited follow the new fields.
                draft = VisualizationService.adaptedPreset(draft, to: result)
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

/// A flat editor section: a heading, then its controls, with a hairline above every section but the first.
private struct ChartEditorSection<Trailing: View, Content: View>: View {
    var title: String?
    var isFirst = false
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let title {
                PortbaseSectionHeading(title: title) { trailing }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
        }
    }
}

extension ChartEditorSection where Trailing == EmptyView {
    init(title: String? = nil, isFirst: Bool = false, @ViewBuilder content: () -> Content) {
        self.init(title: title, isFirst: isFirst, trailing: { EmptyView() }, content: content)
    }
}

private struct LabeledVisualizerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PortbaseFieldLabel(label)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.bodyText)
                .portbaseTextCapitalization(.words)
                .portbaseFieldChrome()
        }
    }
}

/// A row with its name on the left and a menu of choices showing the current one on the right.
private struct VisualizationControlMenu<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(title)
            Spacer(minLength: Spacing.s)
            Menu {
                content()
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Text(value.isEmpty ? L10n.text("Select") : value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.microText)
                        .foregroundStyle(PortSQLPalette.muted)
                }
                .foregroundStyle(PortSQLPalette.ink)
            }
            .portbaseToolbarMenu()
        }
        .font(.rowTitle)
        .foregroundStyle(PortSQLPalette.ink)
        .frame(minHeight: Sizes.control)
    }
}
