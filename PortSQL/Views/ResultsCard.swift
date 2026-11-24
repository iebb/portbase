import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

struct ResultsCard: View {
    @EnvironmentObject private var libraryStore: WorkspaceLibraryStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.workspaceFillsHeight) private var fillsHeight
    @State private var isShowingSchemaSheet = false
    @State private var composerPreset: SavedVisualizationPreset?
    @State private var schemaColumnDraft: SchemaColumnDraft?
    @State private var pendingSchemaColumnDeletion: SchemaColumnDeletionTarget?
    @State private var mongoResultView = "documents"
    @State private var tableResultView = "table"
    @State private var selectedDocument: MongoDocumentSelection?

    private var hasTabularResult: Bool { !workspace.result.columns.isEmpty }
    private var queryPlan: QueryPlan? {
        guard QueryPlanService.isExplainResult(workspace.result) else { return nil }
        return QueryPlanService.plan(from: workspace.result, engine: workspace.selectedBookmark?.engine ?? .postgresql)
    }

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // The view switcher leads the header, as on the Mac, instead of a separate full-width row.
                // Where the results fill a wide screen, counts and paging join this row too.
                let showsPager = !workspace.isRunning && workspace.isShowingExplorerResult
                let showsCounts = hasTabularResult || workspace.result.documents != nil
                HStack(alignment: .center, spacing: Spacing.m) {
                    resultModeSwitcher
                    if fillsHeight {
                        if showsCounts { resultChips.fixedSize() }
                        Spacer(minLength: 0)
                        if showsPager { pager.fixedSize() }
                    } else {
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Spacing.s) {
                        if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
                        if !workspace.isRunning && workspace.selectedBookmark?.isReadOnly != true && workspace.canInsertIntoCurrentTable {
                            Button {
                                workspace.prepareInsert()
                            } label: {
                                Image(systemName: "plus").toolIconChrome()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert row")
                            .help(L10n.text("Insert row"))
                        }
                        if canCreateVisualization {
                            visualizerButton
                        }
                        if workspace.selectedExplorerTable != nil && workspace.selectedBookmark?.engine.supportsSchemaEditing == true {
                            schemaButton
                        }
                    }
                }

                // Counts on the left and paging on the right share one row.
                if !fillsHeight, showsCounts || showsPager {
                    HStack(spacing: Spacing.s) {
                        if showsCounts { resultChips }
                        if showsPager {
                            Spacer(minLength: Spacing.s)
                            pager
                        }
                    }
                }

                if ResultSetTabs.isVisible(workspace) {
                    ResultSetTabs()
                }

                if let errorMessage = workspace.errorMessage {
                    if ConnectionIssue.isConnectionProblem(errorMessage) {
                        ConnectionIssueBanner(message: errorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                    } else {
                        ExecutionErrorLine(message: errorMessage)
                    }
                }

                if workspace.result.documents != nil || workspace.result.affectedRowCount != nil || workspace.result.isTruncated == true {
                    Text(workspace.result.executionSummary)
                        .font(.captionText)
                        .foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                        .textSelection(.enabled)
                }

                if workspace.isRunning {
                    ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.l)
                } else if workspace.result.documents != nil && mongoResultView == "chart" {
                    if canCreateVisualization {
                        VisualizationChartPreview(preset: resultChartPreset, result: workspace.result, compact: false)
                        Button("Configure Chart") { composerPreset = resultChartPreset }.frame(minHeight: Sizes.touchTarget)
                    } else {
                        Text("Run a query with numeric fields to create a chart.").foregroundStyle(.secondary)
                    }
                } else if workspace.result.documents != nil && mongoResultView == "insights" {
                    ResultInsightsView(result: workspace.result)
                } else if let documents = workspace.result.documents, mongoResultView == "documents" || workspace.result.columns.isEmpty {
                    MongoDocumentResults(documents: documents, context: MongoDocumentMutationContext.from(workspace: workspace))
                } else if workspace.result.columns.isEmpty {
                    PortbaseEmptyState(
                        title: L10n.text("No live rows yet"),
                        message: workspace.result.affectedRowCount == nil ? nil : workspace.result.executionSummary,
                        systemImage: "tablecells"
                    )
                } else if workspace.result.documents == nil && tableResultView == "insights" {
                    ResultInsightsView(result: workspace.result)
                } else if workspace.result.documents == nil && tableResultView == "plan", let queryPlan {
                    QueryPlanView(plan: queryPlan)
                } else {
                    resultTable
                }
            }
        }
        .onChange(of: queryPlan != nil, initial: true) { _, hasPlan in
            // Explain results open on their plan; other results return to the table.
            if hasPlan { tableResultView = "plan" } else if tableResultView == "plan" { tableResultView = "table" }
        }
        .sheet(isPresented: $isShowingSchemaSheet) {
            schemaSheet
        }
        .sheet(item: $schemaColumnDraft) { draft in
            SchemaColumnEditorSheet(draft: draft)
        }
        .sheet(item: $composerPreset) { preset in
            VisualizerComposerSheet(initialPreset: preset)
        }
        // A chart the assistant proposed opens in the chart editor once its query has run.
        .onChange(of: workspace.isRunning) { _, running in
            if !running, let preset = workspace.consumeAssistantChart() { composerPreset = preset }
        }
        .sheet(item: $selectedDocument) { selection in
            MongoDocumentInspector(selection: selection)
        }
        .alert(item: $pendingSchemaColumnDeletion) { target in
            let engine = workspace.selectedBookmark?.engine ?? .postgresql
            let plan = DatabaseService.dropColumnPlan(target.column, from: target.table, engine: engine)
            return Alert(
                title: Text("Delete Column"),
                message: Text(
                    L10n.format("Delete `%@` from `%@`? This will alter the live schema.", target.column.name, target.table.name)
                    + "\n\n" + plan.previewSQL
                ),
                primaryButton: .destructive(Text("Delete")) {
                    Task {
                        do {
                            try await workspace.deleteSchemaColumn(target.column, from: target.table)
                        } catch {
                            await MainActor.run {
                                workspace.errorMessage = error.localizedDescription
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// The page size menu and previous/next buttons for an Explorer browse.
    private var pager: some View {
        HStack(spacing: 0) {
            pageStatusMenu
            Button {
                workspace.goToPreviousExplorerPage()
            } label: {
                Image(systemName: "chevron.left").toolIconChrome()
            }
            .buttonStyle(.plain)
            .disabled(!workspace.canGoToPreviousExplorerPage)
            .accessibilityLabel("Previous results page")
            .accessibilityHint("Loads the preceding page of rows")
            Button {
                workspace.goToNextExplorerPage()
            } label: {
                Image(systemName: "chevron.right").toolIconChrome()
            }
            .buttonStyle(.plain)
            .disabled(!workspace.canGoToNextExplorerPage)
            .accessibilityLabel("Next results page")
            .accessibilityHint("Loads the following page of rows")
        }
        .fixedSize()
    }

    @ViewBuilder private var resultModeSwitcher: some View {
        if workspace.result.documents != nil {
            PortbaseSegmentedPicker(selection: $mongoResultView, options: [
                PortbaseChoice(value: "documents", title: L10n.text("Documents")),
                PortbaseChoice(value: "table", title: L10n.text("Table")),
                PortbaseChoice(value: "chart", title: L10n.text("Chart")),
                PortbaseChoice(value: "insights", title: L10n.text("Insights")),
            ])
            .accessibilityLabel("Results")
        } else if hasTabularResult && !workspace.isRunning {
            PortbaseSegmentedPicker(selection: $tableResultView, options:
                (queryPlan != nil ? [PortbaseChoice(value: "plan", title: L10n.text("Plan"), systemImage: "list.bullet.indent")] : [])
                + [PortbaseChoice(value: "table", title: L10n.text("Table"), systemImage: "tablecells"),
                   PortbaseChoice(value: "insights", title: L10n.text("Insights"), systemImage: "sparkles")])
            .accessibilityLabel("Results")
        } else {
            // A heading over the results says nothing the panel doesn't; it stays for VoiceOver only.
            Color.clear.frame(width: 0, height: 0)
                .accessibilityLabel("Results")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var resultChips: some View {
        ResultFactsLine()
    }

    private var resultTable: some View {
        ResultGridView(
            result: workspace.result,
            fillsAvailableSpace: fillsHeight,
            primaryKeys: workspace.resultKeyColumnNames,
            sortedColumn: workspace.isShowingExplorerResult ? workspace.explorerSortColumn : nil,
            sortDirection: workspace.explorerSortDirection,
            persistenceKey: [workspace.selectedBookmark?.id.uuidString ?? "", workspace.activeDatabaseName ?? "", workspace.result.sourceTableReference ?? "console"].joined(separator: "."),
            onSort: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0) } : nil,
            onOpenRow: { offset in
                if let documents = workspace.result.documents, documents.indices.contains(offset) {
                    selectedDocument = MongoDocumentSelection(index: offset, json: documents[offset], context: MongoDocumentMutationContext.from(workspace: workspace))
                } else if workspace.result.rows.indices.contains(offset) {
                    workspace.prepareEdit(row: workspace.result.rows[offset])
                }
            },
            actionsForCell: { workspace.gridRowActions(rowIndex: $0, columnIndex: $1) },
            copyEngine: workspace.selectedBookmark?.engine,
            copyTableName: workspace.result.sourceTableReference ?? workspace.selectedExplorerTable?.displayName,
            onSortDirection: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0, descending: $1) } : nil,
            editCell: { workspace.cellEdit(rowIndex: $0, columnIndex: $1) },
            editCells: { workspace.cellsEdit(cells: $0) },
            pendingCells: workspace.pendingGridCells,
            deletedRows: workspace.pendingDeletedGridRows,
            onEditCellText: { workspace.stageCellText(rowIndex: $0, columnIndex: $1, text: $2) },
            onStageCells: { workspace.stageGridValues($0) },
            onRevertCells: { workspace.revertGridCells($0, rows: $1) },
            onToggleRowsDeletion: { workspace.toggleRowsDeletion($0) },
            canToggleRowsDeletion: { workspace.canToggleRowsDeletion($0) },
            areRowsDeleted: { rows in rows.allSatisfy { workspace.isRowMarkedForDeletion(rowIndex: $0) } },
            editsBar: AnyView(PendingEditsBar())
        )
    }

    private var pageStatusMenu: some View {
        Menu {
            ForEach(WorkspaceViewModel.explorerPageSizes, id: \.self) { size in
                Button {
                    workspace.setExplorerPageSize(size)
                } label: {
                    Label(
                        L10n.plural("row_count", count: size),
                        systemImage: workspace.explorerPageSize == size ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(workspace.explorerPageLabel)
                    .font(.captionStrong)
                    .foregroundStyle(PortSQLPalette.ink)
                Text(workspace.explorerResultRangeLabel)
                    .font(.captionText.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.microText)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: Sizes.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Chooses how many rows each page loads")
    }

    private var schemaButton: some View {
        Button {
            isShowingSchemaSheet = true
        } label: {
            Image(systemName: "list.bullet.rectangle").toolIconChrome()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show schema")
    }

    private var resultChartPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result,
            connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"),
            databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }

    private var visualizerButton: some View {
        Button {
            composerPreset = VisualizationService.reconciledPreset(
                nil,
                for: workspace.result,
                connectionProfileID: workspace.selectedBookmark?.id,
                connectionName: workspace.selectedBookmark?.name ?? "Current Result",
                databaseName: workspace.activeDatabaseName,
                sourceTableReference: workspace.result.sourceTableReference
            )
        } label: {
            Image(systemName: "chart.bar.xaxis").toolIconChrome()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to visualizer")
        .accessibilityHint("Opens chart configuration for these results")
    }

    private var canCreateVisualization: Bool {
        !workspace.result.columns.isEmpty
            && VisualizationService.hasNumericField(workspace.result)
    }

    private var rowInteractionLabel: String {
        workspace.canEditCurrentRows ? L10n.text("Tap a row to view or edit") : L10n.text("Tap a row to view")
    }

    private var schemaSheet: some View {
        PortbaseSheet(workspace.selectedExplorerTable?.name ?? L10n.text("Structure"), onClose: { isShowingSchemaSheet = false }) {
            Group {
                if let selectedTable = workspace.selectedExplorerTable {
                    List(selectedTable.columns) { column in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                HStack(spacing: Spacing.xs) {
                                    Text(column.name)
                                        .font(.bodyText.weight(.semibold))
                                    if column.isPrimaryKey {
                                        Image(systemName: "key.fill")
                                            .font(.captionStrong)
                                            .foregroundStyle(PortSQLPalette.accent)
                                    }
                                }
                                Text(column.type)
                                    .font(.captionText)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(column.isNullable ? "NULL" : "NOT NULL")
                                .font(.badgeText)
                                .foregroundStyle(column.isNullable ? .secondary : PortSQLPalette.ink)
                                .padding(.horizontal, Spacing.s)
                                .padding(.vertical, Spacing.xxs)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))

                            Button {
                                schemaColumnDraft = .edit(column, in: selectedTable)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.captionStrong)
                                    .foregroundStyle(PortSQLPalette.muted)
                                    .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                            }
                            .buttonStyle(.portbaseToolbar)
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                            .accessibilityLabel(L10n.format("Edit column %@", column.name))
                        }
                        .padding(.vertical, Spacing.xxxs)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingSchemaColumnDeletion = SchemaColumnDeletionTarget(table: selectedTable, column: column)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
                        }
                    }
                    .listStyle(.portbaseGrouped)
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("No table selected", systemImage: "tablecells")
                }
            }
        } footer: {
            if let selectedTable = workspace.selectedExplorerTable {
                Button { schemaColumnDraft = .add(to: selectedTable) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.portbaseSecondary)
                    .disabled(workspace.selectedBookmark?.isReadOnly == true || workspace.selectedBookmark?.engine.supportsSchemaEditing != true)
            }
            Spacer(minLength: 0)
            Button("Done") { isShowingSchemaSheet = false }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
        .presentationDetents([.medium, .large])
    }

    private var controlBackground: Color {
        PortSQLPalette.surface
    }
}

private struct SchemaColumnEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var draft: SchemaColumnDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var pendingPlan: SchemaMutationPlan?
    @State private var isConfirmingSchemaChange = false

    init(draft: SchemaColumnDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        PortbaseSheet(draft.mode.title, subtitle: draft.table.displayName) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        if let originalName = draft.originalName, draft.mode == .edit {
                            Text(L10n.format("Editing `%@`", originalName))
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }

                Section("Column") {
                    TextField("Column name", text: $draft.name)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()

                    // An example type as the placeholder rather than a line of examples.
                    TextField("Column type", text: $draft.type, prompt: Text(verbatim: "VARCHAR(255)"))
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()

                    Toggle("Nullable", isOn: $draft.isNullable)
                }

                Section("SQL Preview") {
                    if let plan = try? currentPlan() {
                        Text(plan.previewSQL)
                            .font(.codeCaption)
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage {
                    Section {
                        StatusBanner(
                            title: L10n.text("Schema change failed"),
                            message: errorMessage,
                            tint: .red
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.portbaseGrouped)
            .scrollContentBackground(.hidden)
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button(draft.mode.confirmationTitle) { reviewSchemaChange() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
        .presentationDetents([.medium, .large])
        .alert("Apply schema change?", isPresented: $isConfirmingSchemaChange, presenting: pendingPlan) { _ in
            Button("Apply Change", role: .destructive) {
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.previewSQL)
        }
    }

    private func currentPlan() throws -> SchemaMutationPlan {
        guard let engine = workspace.selectedBookmark?.engine else {
            throw DatabaseServiceError.notConfigured
        }
        var normalized = draft
        normalized.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.type = draft.type.trimmingCharacters(in: .whitespacesAndNewlines)
        return try DatabaseService.schemaColumnChangePlan(for: normalized, engine: engine)
    }

    private func reviewSchemaChange() {
        errorMessage = nil
        do {
            pendingPlan = try currentPlan()
            isConfirmingSchemaChange = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            try await workspace.saveSchemaColumn(draft)
            await MainActor.run {
                isSaving = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
