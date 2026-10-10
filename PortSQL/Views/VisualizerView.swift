import Charts
import SwiftUI

struct VisualizerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @State private var editingPreset: SavedVisualizationPreset?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if libraryStore.visualizations.isEmpty {
                    PortbaseEmptyState(
                        title: L10n.text("No saved charts yet"),
                        message: L10n.text("Run a query with numeric columns, then choose the chart button in Results to design and save a chart."),
                        systemImage: "chart.bar.xaxis"
                    )
                    .padding(.top, 60)
                } else {
                    PortbaseSectionHeading(title: L10n.text("Saved Charts"), systemImage: "chart.bar.xaxis") {
                        Text(L10n.format("Saved: %d", libraryStore.visualizations.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(libraryStore.visualizations) { preset in
                            VisualizationPresetCard(
                                preset: preset,
                                result: workspace.result,
                                onEdit: { editingPreset = preset }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(PortbaseBackdrop().ignoresSafeArea())
        .navigationTitle("Charts")
        .portbaseTitleDisplayMode(.inline)
        .sheet(item: $editingPreset) { preset in
            VisualizerComposerSheet(initialPreset: reconciledPreset(for: preset))
        }
    }

    private func reconciledPreset(for preset: SavedVisualizationPreset?) -> SavedVisualizationPreset {
        if let preset { return preset }
        return VisualizationService.reconciledPreset(
            preset,
            for: workspace.result,
            connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: workspace.activeDatabaseName,
            sourceTableReference: workspace.result.sourceTableReference
        )
    }
}

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
        _draft = State(initialValue: initialPreset)
    }

    private var previewResult: QueryResultTable {
        expandedPreviewResult ?? (isStoredPreset ? libraryStore.cachedVisualizationPreview(for: draft.id) ?? .empty : workspace.result)
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

    private var previewPoints: [VisualizationPlotPoint] {
        VisualizationService.chartPoints(for: previewResult, preset: draft)
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Add to Visualizer")

                            LabeledVisualizerTextField(
                                label: "Preset Name",
                                placeholder: "Saved chart name",
                                text: $draft.title
                            )

                            LabeledVisualizerTextField(
                                label: "Chart Title",
                                placeholder: "Title shown on the chart",
                                text: $draft.chartTitle
                            )

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 10) {
                                    Text("Query")
                                        .font(.subheadline.weight(.semibold))
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
                                            .font(.caption.weight(.semibold))
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
                                    .buttonStyle(PrimaryActionButtonStyle())
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
                                        Text(verbatim: previewBookmark?.engine.queryPlaceholder ?? "SELECT …")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 18)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(PortSQLPalette.editorBackground(for: colorScheme))
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                                }
                            }

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                VisualizationControlMenu(
                                    title: "Chart",
                                    value: draft.chartType.title,
                                    systemImage: draft.chartType.symbolName
                                ) {
                                    ForEach(VisualizationChartType.allCases) { chartType in
                                        Button {
                                            draft.chartType = chartType
                                        } label: {
                                            Label(
                                                chartType.title,
                                                systemImage: chartType.symbolName
                                            )
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("X Axis")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PortSQLPalette.ink)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    VisualizationControlMenu(
                                        title: "Field",
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
                                        title: "Mode",
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
                                    label: "X Label",
                                    placeholder: "XAxis title",
                                    text: $draft.xAxisTitle
                                )
                            }
                            .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Y Axis")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PortSQLPalette.ink)

                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    VisualizationControlMenu(
                                        title: "Field",
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
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                LabeledVisualizerTextField(
                                    label: "Y Label",
                                    placeholder: "YAxis title",
                                    text: $draft.yAxisTitle
                                )
                            }
                            .padding(.top, 2)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                VisualizationControlMenu(
                                    title: "Group",
                                    value: draft.groupField ?? "None",
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
                                    title: "Labels",
                                    value: draft.labelField ?? "None",
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
                        }
                    }

                    PanelCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(
                                title: draft.chartTitle.isEmpty ? "Preview" : draft.chartTitle,
                                subtitle: previewSubtitle
                            )
                            if let expandedPreviewError {
                                StatusBanner(
                                    title: "Preview unavailable",
                                    message: expandedPreviewError,
                                    tint: .orange
                                )
                            } else if previewPoints.isEmpty {
                                ContentUnavailableView(
                                    "No plottable rows",
                                    systemImage: "chart.bar.doc.horizontal",
                                    description: Text("Adjust the X/Y fields or run a result set with numeric values for the selected metric.")
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
                            VStack(alignment: .leading, spacing: 12) {
                                Button(role: .destructive) {
                                    isConfirmingDelete = true
                                } label: {
                                    Label("Delete Chart", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(WorkbenchBackground().ignoresSafeArea())
            .navigationTitle("Chart Config")
            .portbaseTitleDisplayMode(.inline)
            .alert("Delete Chart", isPresented: $isConfirmingDelete) {
                Button("Delete", role: .destructive) {
                    libraryStore.deleteVisualization(draft)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Move this chart to Recently Deleted?")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var stored = draft
                        stored.title = normalizedPresetTitle
                        stored.chartTitle = normalizedChartTitle
                        stored.xAxisTitle = normalizedXAxisTitle
                        stored.yAxisTitle = normalizedYAxisTitle
                        stored.yFields = stored.resolvedYFields
                        stored.yField = stored.resolvedYFields.first ?? ""
                        stored.usesUnlimitedRows = false
                        stored.connectionName = previewBookmark?.name ?? stored.connectionName
                        stored.connectionProfileID = previewBookmark?.id ?? stored.connectionProfileID
                        stored.databaseName = stored.databaseName ?? workspace.activeDatabaseName
                        stored.sourceTableReference = stored.sourceTableReference ?? workspace.result.sourceTableReference
                        stored.sourceQuery = stored.sourceQuery ?? workspace.result.sourceQuery
                        libraryStore.saveVisualization(stored)
                        libraryStore.cacheVisualizationPreview(previewResult, for: stored.id)
                        dismiss()
                    }
                    .disabled(draft.xField.isEmpty || draft.resolvedYFields.isEmpty || numericFields.isEmpty)
                }
            }
        }
    }

    private var selectedXFieldDescriptor: VisualizationFieldDescriptor {
        fields.first(where: { $0.name == draft.xField }) ?? fields.first ?? VisualizationFieldDescriptor(
            name: "Value",
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
        if !trimmed.isEmpty { return trimmed }
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

private struct VisualizationPresetCard: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let preset: SavedVisualizationPreset
    let result: QueryResultTable
    let onEdit: () -> Void
    @State private var loadedResult: QueryResultTable?
    @State private var runError: String?
    @State private var isRunning = false
    @State private var hasResolvedInitialState = false

    private var compatible: Bool {
        VisualizationService.isCompatible(preset, with: result)
    }

    private var cachedResult: QueryResultTable? {
        libraryStore.cachedVisualizationPreview(for: preset.id)
    }

    private var previewResult: QueryResultTable? {
        loadedResult ?? cachedResult ?? (compatible ? result : nil)
    }

    private var runnableBookmark: ConnectionProfile? {
        if let id = preset.connectionProfileID { return bookmarks.bookmark(with: id) }
        return workspace.selectedBookmark
    }

    private var hasSourceQuery: Bool {
        preset.sourceQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var previewState: SavedChartPreviewState {
        SavedChartPreviewState.resolve(
            hasResolvedInitialState: hasResolvedInitialState,
            isRunning: isRunning,
            hasPreview: previewResult != nil,
            error: runError,
            hasSourceQuery: hasSourceQuery,
            hasConnection: runnableBookmark != nil
        )
    }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: preset.chartType.symbolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(LinearGradient(colors: (runnableBookmark?.engine ?? .postgresql).brandColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.title)
                            .font(.headline.weight(.bold))
                        Text([
                            preset.chartType.title,
                            preset.connectionName,
                            preset.databaseName,
                            preset.sourceTableReference
                        ].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await runPreset()
                            }
                        } label: {
                            Group {
                                if isRunning {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                            }
                            .toolIconChrome(prominent: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning || !hasSourceQuery || runnableBookmark == nil)
                        .opacity(isRunning || !hasSourceQuery || runnableBookmark == nil ? 0.5 : 1)
                        .accessibilityLabel(L10n.format("Run %@ chart query", preset.title))
                        .accessibilityHint("Refreshes this saved chart from its database")

                        Button(action: onEdit) {
                            Image(systemName: "slider.horizontal.3").toolIconChrome()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Edit %@ chart", preset.title))
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        VisualizerMetaChip(text: "X \(preset.xField)")
                        VisualizerMetaChip(text: "Y \(preset.yFieldsSummary)")
                        if preset.sourceQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            VisualizerMetaChip(text: runnableBookmark?.engine.queryLanguage ?? "SQL")
                        }
                        if preset.resolvedYFields.count > 1 {
                            VisualizerMetaChip(text: "Multi-metric")
                        }
                        if let groupField = preset.groupField {
                            VisualizerMetaChip(text: L10n.format("Group %@", groupField))
                        }
                        if let labelField = preset.labelField {
                            VisualizerMetaChip(text: L10n.format("Label %@", labelField))
                        }
                    }
                }

                switch previewState {
                case .failed(let message):
                    StatusBanner(
                        title: "Execution failed",
                        message: message,
                        tint: .red
                    )
                case .loading:
                    ProgressView("Loading chart preview…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .content:
                    if let previewResult {
                        VisualizationChartPreview(preset: preset, result: previewResult, compact: true)
                    }
                case .missingQuery:
                    unavailablePreview(
                        title: "Chart query missing",
                        message: "Edit this chart and save a SQL query before running it.",
                        actionTitle: "Edit Chart",
                        action: onEdit
                    )
                case .missingConnection:
                    unavailablePreview(
                        title: "Connection unavailable",
                        message: "Edit this chart and choose a saved database connection.",
                        actionTitle: "Edit Chart",
                        action: onEdit
                    )
                case .idle:
                    unavailablePreview(
                        title: "Preview not loaded",
                        message: "Run the saved query when you want to refresh this chart.",
                        actionTitle: "Run Preview"
                    ) {
                        Task {
                            await runPreset()
                        }
                    }
                }
            }
        }
        .task(id: preset.id) {
            if loadedResult == nil,
               let cached = cachedResult {
                loadedResult = cached
            }
            hasResolvedInitialState = true
        }
    }

    private func unavailablePreview(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func runPreset() async {
        guard let sourceQuery = preset.sourceQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceQuery.isEmpty else {
            runError = L10n.text("Chart query missing")
            return
        }
        guard let bookmark = runnableBookmark else {
            runError = L10n.text("The saved bookmark for this visualizer is unavailable.")
            return
        }
        isRunning = true
        hasResolvedInitialState = true
        runError = nil
        do {
            var result = try await DatabaseService.shared.execute(
                query: sourceQuery,
                profile: bookmark,
                database: preset.databaseName,
                policy: .readOnly
            )
            result.sourceQuery = sourceQuery
            result.sourceTableReference = preset.sourceTableReference
            await MainActor.run {
                loadedResult = result
                libraryStore.cacheVisualizationPreview(result, for: preset.id)
                runError = nil
                isRunning = false
            }
        } catch {
            await MainActor.run {
                loadedResult = nil
                runError = error.localizedDescription
                isRunning = false
            }
        }
    }
}

struct VisualizationChartPlot: View {
    let preset: SavedVisualizationPreset
    let points: [VisualizationPlotPoint]
    let xMode: VisualizationFieldMode
    var compact: Bool
    var selectedPointID: String?
    var onSelect: ((VisualizationPlotPoint) -> Void)?
    @State private var selectedAngle: Double?

    var body: some View {
        Group {
            switch preset.chartType {
            case .pie, .donut:
                sectorChart
            default:
                cartesianChart
            }
        }
        .frame(height: compact ? 210 : 300)
    }

    private var cartesianChart: some View {
        Chart {
            switch preset.chartType {
            case .bar:
                barMarks
            case .line:
                lineMarks
            case .area:
                areaMarks
            case .point:
                pointMarks
            case .rule:
                ruleMarks
            case .pie, .donut:
                barMarks
            }
            selectionMark
        }
        .chartXAxisLabel(preset.xAxisTitle)
        .chartYAxisLabel(preset.yAxisTitle)
        .chartLegend(compact ? .hidden : .visible)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let plotFrame = geometry[frame]
                        guard plotFrame.contains(location) else { return }
                        selectPoint(at: CGPoint(x: location.x - plotFrame.minX, y: location.y - plotFrame.minY), proxy: proxy)
                    }
                    .allowsHitTesting(onSelect != nil)
                    .accessibilityHidden(true)
            }
        }
    }

    private var sectorChart: some View {
        Chart(points.filter { $0.yValue > 0 }) { point in
            SectorMark(
                angle: .value(preset.yAxisTitle, point.yValue),
                innerRadius: .ratio(preset.chartType == .donut ? 0.56 : 0),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value(L10n.text("Category"), sectorTitle(for: point)))
            .opacity(selectedPointID == nil || selectedPointID == point.id ? 1 : 0.45)
            .annotation(position: .overlay) {
                if let annotation = annotationText(for: point), shouldAnnotate {
                    Text(annotation)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .chartLegend(compact ? .hidden : .visible)
        .chartAngleSelection(value: $selectedAngle)
        .onChange(of: selectedAngle) { _, angle in
            guard let angle else { return }
            var total: Double = 0
            for point in points where point.yValue > 0 {
                total += point.yValue
                if angle <= total { onSelect?(point); return }
            }
        }
    }

    @ChartContentBuilder
    private var selectionMark: some ChartContent {
        if let point = points.first(where: { $0.id == selectedPointID }) {
            if preset.chartType == .rule {
                RuleMark(y: .value(preset.yAxisTitle, point.yValue))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
            } else if let date = point.xDate {
                RuleMark(x: .value(preset.xAxisTitle, date))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else if let number = point.xNumber {
                RuleMark(x: .value(preset.xAxisTitle, number))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else {
                RuleMark(x: .value(preset.xAxisTitle, point.xText))
                    .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }

    private func selectPoint(at location: CGPoint, proxy: ChartProxy) {
        guard onSelect != nil else { return }
        if preset.chartType == .rule {
            if let point = points.min(by: {
                abs((proxy.position(forY: $0.yValue) ?? 0) - location.y) < abs((proxy.position(forY: $1.yValue) ?? 0) - location.y)
            }) { onSelect?(point) }
            return
        }
        let positioned = points.compactMap { point -> (VisualizationPlotPoint, CGFloat)? in
            let x: CGFloat?
            switch xMode {
            case .date: x = point.xDate.flatMap { proxy.position(forX: $0) }
            case .number: x = point.xNumber.flatMap { proxy.position(forX: $0) }
            case .category, .automatic: x = proxy.position(forX: point.xText)
            }
            return x.map { (point, $0) }
        }
        guard let nearestX = positioned.min(by: { abs($0.1 - location.x) < abs($1.1 - location.x) })?.1 else { return }
        let candidates = positioned.filter { abs($0.1 - nearestX) < 1 }.map(\.0)
        let stacked = preset.chartType == .bar || preset.chartType == .area
        var positive: Double = 0
        var negative: Double = 0
        var nearest: (VisualizationPlotPoint, CGFloat)?
        for point in candidates {
            let start = stacked ? (point.yValue >= 0 ? positive : negative) : point.yValue
            let end = stacked ? start + point.yValue : point.yValue
            if point.yValue >= 0 { positive = end } else { negative = end }
            guard let yStart = proxy.position(forY: start), let yEnd = proxy.position(forY: end) else { continue }
            let low = min(yStart, yEnd), high = max(yStart, yEnd)
            let distance = location.y < low ? low - location.y : (location.y > high ? location.y - high : 0)
            if nearest == nil || distance < nearest!.1 { nearest = (point, distance) }
        }
        if let point = nearest?.0 { onSelect?(point) }
    }

    @ChartContentBuilder
    private var barMarks: some ChartContent {
        switch xMode {
        case .date:
            ForEach(points) { point in
                if let date = point.xDate {
                    if let group = point.group {
                        BarMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        BarMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent.gradient)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .number:
            ForEach(points) { point in
                if let number = point.xNumber {
                    if let group = point.group {
                        BarMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        BarMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent.gradient)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .category, .automatic:
            ForEach(points) { point in
                if let group = point.group {
                    BarMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(by: .value(L10n.text("Group"), group))
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                } else {
                    BarMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(PortSQLPalette.accent.gradient)
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                }
            }
        }
    }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        switch xMode {
        case .date:
            ForEach(points) { point in
                if let date = point.xDate {
                    if let group = point.group {
                        LineMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        LineMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .number:
            ForEach(points) { point in
                if let number = point.xNumber {
                    if let group = point.group {
                        LineMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        LineMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .category, .automatic:
            ForEach(points) { point in
                if let group = point.group {
                    LineMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(by: .value(L10n.text("Group"), group))
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                } else {
                    LineMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(PortSQLPalette.accent)
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                }
            }
        }
    }

    @ChartContentBuilder
    private var areaMarks: some ChartContent {
        switch xMode {
        case .date:
            ForEach(points) { point in
                if let date = point.xDate {
                    if let group = point.group {
                        AreaMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        AreaMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(
                                LinearGradient(colors: [PortSQLPalette.accent.opacity(0.85), Color.cyan.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                            )
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .number:
            ForEach(points) { point in
                if let number = point.xNumber {
                    if let group = point.group {
                        AreaMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        AreaMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(
                                LinearGradient(colors: [PortSQLPalette.accent.opacity(0.85), Color.cyan.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                            )
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .category, .automatic:
            ForEach(points) { point in
                if let group = point.group {
                    AreaMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(by: .value(L10n.text("Group"), group))
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                } else {
                    AreaMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(
                            LinearGradient(colors: [PortSQLPalette.accent.opacity(0.85), Color.cyan.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                        )
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                }
            }
        }
    }

    @ChartContentBuilder
    private var pointMarks: some ChartContent {
        switch xMode {
        case .date:
            ForEach(points) { point in
                if let date = point.xDate {
                    if let group = point.group {
                        PointMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        PointMark(x: .value(preset.xAxisTitle, date), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .number:
            ForEach(points) { point in
                if let number = point.xNumber {
                    if let group = point.group {
                        PointMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(by: .value(L10n.text("Group"), group))
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    } else {
                        PointMark(x: .value(preset.xAxisTitle, number), y: .value(preset.yAxisTitle, point.yValue))
                            .foregroundStyle(PortSQLPalette.accent)
                            .annotation(position: .top) {
                                if let annotation = annotationText(for: point) {
                                    compactAnnotation(annotation)
                                }
                            }
                    }
                }
            }
        case .category, .automatic:
            ForEach(points) { point in
                if let group = point.group {
                    PointMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(by: .value(L10n.text("Group"), group))
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                } else {
                    PointMark(x: .value(preset.xAxisTitle, point.xText), y: .value(preset.yAxisTitle, point.yValue))
                        .foregroundStyle(PortSQLPalette.accent)
                        .annotation(position: .top) {
                            if let annotation = annotationText(for: point) {
                                compactAnnotation(annotation)
                            }
                        }
                }
            }
        }
    }

    @ChartContentBuilder
    private var ruleMarks: some ChartContent {
        ForEach(points) { point in
            if let group = point.group {
                RuleMark(y: .value(preset.yAxisTitle, point.yValue))
                    .foregroundStyle(by: .value(L10n.text("Group"), group))
                    .annotation(position: .trailing) {
                        compactAnnotation(point.label ?? point.xText)
                    }
            } else {
                RuleMark(y: .value(preset.yAxisTitle, point.yValue))
                    .foregroundStyle(PortSQLPalette.accent)
                    .annotation(position: .trailing) {
                        compactAnnotation(point.label ?? point.xText)
                    }
            }
        }
    }

    private var shouldAnnotate: Bool {
        preset.labelField != nil && points.count <= (compact ? 8 : 12)
    }

    private func annotationText(for point: VisualizationPlotPoint) -> String? {
        guard shouldAnnotate else { return nil }
        let text = (point.label ?? point.xText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func sectorTitle(for point: VisualizationPlotPoint) -> String {
        if let group = point.group {
            return "\(group) • \(point.xText)"
        }
        return point.xText
    }

    @ViewBuilder
    private func compactAnnotation(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PortSQLPalette.ink)
            .lineLimit(1)
    }
}

private struct LabeledVisualizerTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .portbaseTextCapitalization(.words)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "Select" : value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PortSQLPalette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(PortSQLPalette.stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VisualizerMetaChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PortSQLPalette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PortSQLPalette.accent.opacity(0.10), in: Capsule())
    }
}
