import AppKit
import SwiftUI

struct DesktopSQLEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme
    /// Typing publishes here, not on the workspace; see `QueryEditorState`.
    @EnvironmentObject private var editor: QueryEditorState
    @State private var showsGoToLine = false
    @State private var line = "1"
    private var isSQL: Bool { !workspace.isDocumentDatabase && workspace.selectedBookmark?.engine != .redis && workspace.selectedBookmark?.engine != .elasticsearch }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Button {
                    if workspace.isRunning { workspace.cancelQuery() } else { workspace.runQuery() }
                } label: {
                    Label(workspace.isRunning ? L10n.text("Cancel") : (workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run Query")),
                          systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                        .font(.cardTitle)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.m).frame(height: Sizes.control)
                        .background(workspace.isRunning ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(PortSQLPalette.accentGradient),
                                    in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                        .opacity(workspace.selectedBookmark == nil ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(workspace.selectedBookmark == nil)
                if isSQL {
                    Button("Run All", systemImage: "play.rectangle") { workspace.runQuery(entireBuffer: true) }.disabled(workspace.isRunning || workspace.selectedBookmark == nil)
                    Divider().frame(height: Spacing.l)
                    Button("Format", systemImage: "text.alignleft") { workspace.formatQuery() }
                    if workspace.canExplainAnalyze {
                        // Click to explain; the menu runs the query for actual times and rows.
                        Menu {
                            Button("Explain Analyze", systemImage: "stopwatch") { workspace.runExplain(analyze: true) }
                        } label: {
                            Label("Explain", systemImage: "waveform.path.ecg")
                        } primaryAction: {
                            workspace.runExplain()
                        }
                        .fixedSize()
                        .disabled(workspace.isRunning)
                    } else {
                        Button("Explain", systemImage: "waveform.path.ecg") { workspace.runExplain() }.disabled(workspace.selectedBookmark == nil || workspace.isRunning)
                    }
                    SQLTemplateMenu(compact: false).portbaseToolbarMenu()
                    Button("Ask AI", systemImage: "sparkles") { workspace.isShowingAssistant = true }
                        .help(L10n.text("Ask an AI model to write a query or design a chart"))
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Save Query") { workspace.saveSnippet() }
                    Button("Go to Line") { showsGoToLine = true }.keyboardShortcut("l")
                    if workspace.selectedBookmark?.engine == .redis {
                        Menu("Redis command reference") {
                            ForEach(RedisCommandService.help) { command in
                                Button { workspace.queryText = command.syntax } label: { Text(verbatim: command.syntax) }
                            }
                        }
                    }
                } label: { Label("Editor", systemImage: "ellipsis") }.labelStyle(.iconOnly).portbaseToolbarMenu()
                DesktopTransactions()
            }.buttonStyle(.portbaseToolbar).font(.bodyText).portbaseBar(Sizes.toolbar)
            Divider()
            HighlightedQueryEditor(text: $workspace.queryText, cursorOffset: $workspace.queryCursorOffset,
                                   selectionLength: $workspace.querySelectionLength, colorScheme: colorScheme, isJSON: workspace.usesJSONEditor,
                                   allowsSQLComments: isSQL, completion: isSQL ? workspace.completion : nil, errorRange: workspace.queryErrorRange,
                                   engine: isSQL ? workspace.selectedBookmark?.engine : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().layoutPriority(1)
            HStack(spacing: Spacing.s) {
                Text(workspace.editorPositionLabel).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                // A failed run's error shows once, above its results, rather than here as well.
                // Warnings about the text, like an unknown table, as DataGrip's inspections show; general tips stay quiet here.
                if workspace.errorMessage == nil, isSQL, let hint = workspace.hints.first(where: { $0.severity != .info }) {
                    let others = workspace.hints.filter { $0.severity != .info }.count - 1
                    Label(others > 0 ? hint.title + "  +" + String(others) : hint.title, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(hint.severity.tint).lineLimit(1).truncationMode(.tail)
                        .help(workspace.hints.filter { $0.severity != .info }.map { $0.title + " — " + $0.message }.joined(separator: "\n"))
                        .layoutPriority(-1)
                }
                if let execution = workspace.lastExecution, execution.outcome != .failed {
                    Text(verbatim: [execution.outcome == .cancelled ? execution.outcome?.title : nil,
                                    execution.duration.map { WorkspaceActivityService.durationLabel($0) }].compactMap { $0 }.joined(separator: " · "))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }.font(.rowDetail).portbaseBar(Sizes.statusBar)
        }
        .alert("Go to Line", isPresented: $showsGoToLine) {
            TextField("Line", text: $line)
            Button("Go") {
                let starts = SQLEditingService.lineStarts(in: workspace.queryText)
                if let value = Int(line), starts.indices.contains(value - 1) { workspace.queryCursorOffset = starts[value - 1]; workspace.querySelectionLength = 0 }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct DesktopTransactions: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var body: some View {
        if workspace.selectedBookmark?.engine.supportsConsoleTransactions == true {
            Menu {
                Button("Auto-commit") { workspace.setManualCommit(false) }.disabled(workspace.hasOpenTransaction)
                Button("Manual Commit") { workspace.setManualCommit(true) }
            } label: { Text(L10n.text(workspace.manualCommit ? "Manual Commit" : "Auto-commit")) }.fixedSize()
            if workspace.manualCommit {
                Button("Commit", systemImage: "checkmark") { workspace.finishTransaction(commit: true) }.disabled(!workspace.hasOpenTransaction || workspace.isRunning)
                Button("Rollback", systemImage: "arrow.uturn.backward") { workspace.finishTransaction(commit: false) }.disabled(!workspace.hasOpenTransaction || workspace.isRunning)
            }
        }
    }
}

struct DesktopTableBrowser: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    var body: some View {
        VStack(spacing: 0) {
            // One bar: the table, its filter and sort (Return applies them), and its actions.
            HStack(spacing: Spacing.s) {
                Text(workspace.selectedExplorerTable?.name ?? L10n.text("Tables")).font(.cardTitle).lineLimit(1)
                    .help(workspace.selectedExplorerTable.map { table in
                        [table.displayName, L10n.plural("column_count_short", count: table.columns.count),
                         table.rowCountEstimate.map { L10n.plural("row_count", count: $0) }].compactMap { $0 }.joined(separator: " · ")
                    } ?? "")
                    .layoutPriority(1)
                clauseField(workspace.isDocumentDatabase ? L10n.text("Filter") : "WHERE", text: $workspace.explorerWhereClause, prompt: L10n.text("Filter"), kind: .filter)
                clauseField(workspace.isDocumentDatabase ? L10n.text("Sort") : "ORDER BY", text: $workspace.explorerOrderByClause, prompt: L10n.text("Sort"), kind: .sort)
                    .frame(maxWidth: 260)
                Button("Refresh", systemImage: "arrow.clockwise") { workspace.restartBrowse() }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Refresh"))
                    .disabled(workspace.isRunning || workspace.selectedExplorerTable == nil)
                if workspace.canInsertIntoCurrentTable && workspace.selectedBookmark?.isReadOnly != true {
                    Button("Insert row", systemImage: "plus") { workspace.prepareInsert() }
                        .labelStyle(.iconOnly)
                        .help(L10n.text("Insert row"))
                }
                DataTransferMenu()
            }.font(.bodyText).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.toolbar)
            Divider()
            DesktopResultsView()
        }
        .autoBrowsesSelectedTable(workspace)
    }
}

extension DesktopTableBrowser {
    func clauseField(_ keyword: String, text: Binding<String>, prompt: String, kind: ClauseHistoryStore.Kind) -> some View {
        DesktopClauseField(keyword: keyword, text: text, prompt: prompt, kind: kind)
    }
}

/// A clause keyword and its field, styled like the sidebar's search field. Typing stays in the field
/// and reaches the workspace once it pauses, so each keystroke doesn't redraw the whole window, and
/// the completion engine's suggestions are worked out off the main thread, once per change.
struct DesktopClauseField: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let keyword: String
    @Binding var text: String
    let prompt: String
    let kind: ClauseHistoryStore.Kind

    @State private var draft = ""
    @State private var suggestions: [SQLClauseSuggestion] = []
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(keyword).font(.codeCaption.weight(.semibold)).foregroundStyle(PortSQLPalette.muted).fixedSize()
            TextField(prompt, text: $draft).textFieldStyle(.plain).font(.codeDetail)
                .focused($focused)
                .onSubmit { commit(); workspace.restartBrowse() }
                // The console's completion engine, offering columns, operators, and values as the clause is typed.
                .textInputSuggestions {
                    ForEach(suggestions) { suggestion in
                        Label {
                            Text(suggestion.label) + Text(suggestion.detail.map { "  " + $0 } ?? "").foregroundColor(.secondary)
                        } icon: {
                            Image(systemName: suggestion.kind.symbol).foregroundStyle(suggestion.kind.tint)
                        }
                        .textInputCompletion(suggestion.completedText)
                    }
                }
            ClauseHistoryMenu(kind: kind, text: $text)
        }
        .portbaseFieldChrome()
        .onAppear { draft = text }
        // A clause set elsewhere, from history or another table, replaces what's in the field.
        .onChange(of: text) { _, value in if value != draft { draft = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .task(id: draft) {
            await updateSuggestions(for: draft)
            // Written back once typing pauses; Return and leaving the field write at once.
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { commit() }
        }
    }

    private func commit() {
        if text != draft { text = draft }
    }

    private func updateSuggestions(for text: String) async {
        guard workspace.isSQLDatabase, let table = workspace.selectedExplorerTable,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { suggestions = []; return }
        let catalog = workspace.schemaCatalog, database = workspace.activeDatabaseName
        let engine = workspace.selectedBookmark?.engine ?? .postgresql
        let clause: SQLCompletionEngine.ClauseKind = kind == .filter ? .filter : .sort
        let result = await Task.detached(priority: .userInitiated) {
            SQLCompletionEngine.clauseSuggestions(text, kind: clause, table: table, catalog: catalog,
                                                  activeDatabase: database, engine: engine, limit: 10)
        }.value
        if !Task.isCancelled { suggestions = result }
    }
}

struct DesktopResultsView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var presentation = "table"
    @State private var composerPreset: SavedVisualizationPreset?
    @State private var selectedDocument: MongoDocumentSelection?
    @State private var exportURL: URL?
    @State private var tableMode = "table"
    @AppStorage("Portbase.showsRowDetails") private var showsRowDetails = false
    @State private var focusedRow: Int?
    private var queryPlan: QueryPlan? {
        guard QueryPlanService.isExplainResult(workspace.result) else { return nil }
        return QueryPlanService.plan(from: workspace.result, engine: workspace.selectedBookmark?.engine ?? .postgresql)
    }
    private var chartPreset: SavedVisualizationPreset {
        VisualizationService.reconciledPreset(nil, for: workspace.result, connectionProfileID: workspace.selectedBookmark?.id,
            connectionName: workspace.selectedBookmark?.name ?? L10n.text("Current Result"), databaseName: workspace.activeDatabaseName, sourceTableReference: workspace.result.sourceTableReference)
    }
    private var canChart: Bool { VisualizationService.hasNumericField(workspace.result) }
    /// Whether the grid is showing; its tool row then carries the result controls, so there's one bar, not two.
    private var showsGrid: Bool {
        guard !workspace.result.columns.isEmpty else { return false }
        if workspace.result.documents != nil { return presentation == "table" }
        if tableMode == "plan" && queryPlan != nil { return false }
        return tableMode != "insights"
    }

    /// Whether the bar above non-grid results has anything to offer; with no result it would hold only a
    /// disabled Export button.
    private var showsResultBar: Bool {
        !workspace.result.columns.isEmpty || workspace.result.documents != nil || workspace.isRunning
            || workspace.isDocumentDatabase
    }

    @ViewBuilder private var modeControls: some View {
        HStack(spacing: Spacing.s) {
            if !workspace.result.columns.isEmpty && workspace.result.documents == nil {
                PortbaseSegmentedPicker(selection: $tableMode, options:
                    (queryPlan != nil ? [PortbaseChoice(value: "plan", title: L10n.text("Plan"))] : [])
                    + [PortbaseChoice(value: "table", title: L10n.text("Table")), PortbaseChoice(value: "insights", title: L10n.text("Insights"))])
                    .accessibilityLabel("Results")
            }
            if workspace.result.documents != nil {
                PortbaseSegmentedPicker(selection: $presentation, options: [
                    PortbaseChoice(value: "table", title: L10n.text("Table")), PortbaseChoice(value: "documents", title: L10n.text("Documents")),
                    PortbaseChoice(value: "chart", title: L10n.text("Chart")), PortbaseChoice(value: "insights", title: L10n.text("Insights")),
                ])
                .accessibilityLabel("Results")
            }
            if workspace.isRunning { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var resultActions: some View {
        HStack(spacing: Spacing.s) {
            if workspace.isDocumentDatabase { MongoInsertDocumentButton() }
            if !workspace.result.columns.isEmpty && workspace.result.documents == nil {
                Toggle(isOn: $showsRowDetails) { Label("Row Details", systemImage: "sidebar.right") }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Show the selected row’s fields"))
            }
            if canChart {
                Button("Configure Chart", systemImage: "chart.xyaxis.line") { composerPreset = chartPreset }
                    .labelStyle(.iconOnly)
                    .help(L10n.text("Configure Chart"))
            }
            Menu {
                Button("CSV") { exportURL = workspace.exportResultURL(format: .csv) }
                Button("JSON") { exportURL = workspace.exportResultURL(format: .json) }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.text("Export"))
                .disabled(workspace.result.columns.isEmpty && workspace.result.documents == nil)
        }
        .buttonStyle(.portbaseToolbar)
    }

    var body: some View {
        VStack(spacing: 0) {
            // One tab per statement of a script, above the selected result's own bar.
            if ResultSetTabs.isVisible(workspace) {
                ResultSetTabs().padding(.horizontal, Spacing.m).portbaseBar(Sizes.toolbar)
                Divider()
            }
            if !showsGrid && showsResultBar {
                HStack(spacing: Spacing.s) {
                    modeControls
                    Spacer()
                    resultActions
                }.font(.bodyText).portbaseBar(Sizes.toolbar)
                Divider()
            }
            if let error = workspace.errorMessage {
                Group {
                    if ConnectionIssue.isConnectionProblem(error) {
                        ConnectionIssueBanner(message: error, compact: true, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
                    } else {
                        ScrollView {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .font(.captionText).foregroundStyle(.red).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Spacing.m)
            }
            Group {
                if tableMode == "plan", workspace.result.documents == nil, let queryPlan {
                    ScrollView { QueryPlanView(plan: queryPlan).padding(Spacing.l) }
                } else if (presentation == "insights" && workspace.result.documents != nil) || (tableMode == "insights" && workspace.result.documents == nil && !workspace.result.columns.isEmpty) {
                    ScrollView { ResultInsightsView(result: workspace.result).padding(Spacing.l) }
                } else if presentation == "chart" && workspace.result.documents != nil {
                    if canChart { VisualizationChartPreview(preset: chartPreset, result: workspace.result, compact: false).padding(Spacing.m) }
                    else { Text("Run a query with numeric fields to create a chart.").foregroundStyle(.secondary) }
                } else if presentation == "documents", let documents = workspace.result.documents {
                    ScrollView { MongoDocumentResults(documents: documents, context: MongoDocumentMutationContext.from(workspace: workspace)).padding(Spacing.m) }
                } else if !workspace.result.columns.isEmpty {
                    if showsRowDetails {
                        HSplitView {
                            grid.frame(minWidth: 320)
                            RowDetailsPanel(result: workspace.result, rowIndex: focusedRow)
                                .frame(minWidth: 240, idealWidth: 300, maxWidth: 480)
                        }
                    } else { grid }
                }
                else if workspace.result.affectedRowCount != nil {
                    PortbaseEmptyState(title: L10n.text("Statement executed"), message: workspace.result.executionSummary, systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // An empty work area until a query runs; nothing to explain.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Spacing.s) {
                if !workspace.result.columns.isEmpty || workspace.result.documents != nil {
                    if workspace.result.isTruncated == true { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(workspace.result.executionSummary).lineLimit(1).foregroundStyle(workspace.result.isTruncated == true ? .orange : .secondary)
                }
                Spacer()
                if workspace.isShowingExplorerResult {
                    Button("Previous results page", systemImage: "chevron.left") { workspace.goToPreviousExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToPreviousExplorerPage)
                    Menu { ForEach(WorkspaceViewModel.explorerPageSizes, id: \.self) { size in Button(L10n.plural("row_count", count: size)) { workspace.setExplorerPageSize(size) } } } label: { Text(workspace.explorerPageLabel) }
                    Button("Next results page", systemImage: "chevron.right") { workspace.goToNextExplorerPage() }.labelStyle(.iconOnly).disabled(!workspace.canGoToNextExplorerPage)
                }
            }.font(.rowDetail).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.statusBar)
        }
        .onChange(of: queryPlan != nil, initial: true) { _, hasPlan in
            if hasPlan { tableMode = "plan" } else if tableMode == "plan" { tableMode = "table" }
        }
        .sheet(item: $composerPreset) { preset in VisualizerComposerSheet(initialPreset: preset).frame(minWidth: 680, minHeight: 520) }
        // A chart the assistant proposed opens in the chart editor once its query has run.
        .onChange(of: workspace.isRunning) { _, running in
            if !running, let preset = workspace.consumeAssistantChart() { composerPreset = preset }
        }
        .sheet(item: $selectedDocument) { selection in MongoDocumentInspector(selection: selection).frame(minWidth: 600, minHeight: 480) }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) { if let url = exportURL { ScriptActivitySheet(url: url) } }
    }
    private var grid: some View {
        ResultGridView(result: workspace.result, fillsAvailableSpace: true,
            primaryKeys: workspace.resultKeyColumnNames,
            sortedColumn: workspace.isShowingExplorerResult ? workspace.explorerSortColumn : nil, sortDirection: workspace.explorerSortDirection,
            persistenceKey: [workspace.selectedBookmark?.id.uuidString ?? "", workspace.activeDatabaseName ?? "", workspace.result.sourceTableReference ?? "console"].joined(separator: "."),
            onSort: workspace.isShowingExplorerResult ? { workspace.sortExplorer(by: $0) } : nil,
            onOpenRow: workspace.canEditCurrentRows || workspace.result.documents != nil ? { index in
                if let documents = workspace.result.documents, documents.indices.contains(index) { selectedDocument = MongoDocumentSelection(index: index, json: documents[index], context: MongoDocumentMutationContext.from(workspace: workspace)) }
                else if workspace.result.rows.indices.contains(index) { workspace.prepareEdit(row: workspace.result.rows[index]) }
            } : nil,
            actionsForCell: { workspace.gridRowActions(rowIndex: $0, columnIndex: $1) },
            copyEngine: workspace.selectedBookmark?.engine,
            copyTableName: workspace.result.sourceTableReference ?? workspace.selectedExplorerTable?.displayName,
            onSelectRow: { focusedRow = $0 },
            leadingAccessory: AnyView(modeControls.font(.bodyText)),
            trailingAccessory: AnyView(resultActions.font(.bodyText)),
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
            editsBar: AnyView(PendingEditsBar()))
    }
}

struct DesktopMongoEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var validation: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Picker("Query", selection: $workspace.mongoDraft.mode) { ForEach(MongoEditorMode.allCases) { mode in Text(mode.title).tag(mode) } }.labelsHidden().frame(width: 140)
                Text("Collection").foregroundStyle(.secondary)
                TextField("Collection", text: Binding(get: { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection }, set: { workspace.mongoDraft.collection = $0 })).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button(L10n.text(workspace.isRunning ? "Cancel" : "Run Query"), systemImage: workspace.isRunning ? "stop.fill" : "play.fill") {
                    if workspace.isRunning { workspace.cancelQuery() } else { perform { try workspace.runMongoBuilder() } }
                }.disabled(workspace.selectedBookmark == nil)
                Button("Explain") { perform { try workspace.runMongoBuilder(explain: true) } }.disabled(workspace.isRunning)
            }.font(.bodyText).buttonStyle(.portbaseToolbar).portbaseBar(Sizes.toolbar)
            Divider()
            if workspace.mongoDraft.mode == .command { DesktopSQLEditor() }
            else if workspace.mongoDraft.mode == .find {
                HStack(spacing: Spacing.s) {
                    Text("Skip").foregroundStyle(.secondary); TextField("Skip", text: $workspace.mongoDraft.skip).frame(width: 70)
                    Text("Limit").foregroundStyle(.secondary); TextField("Limit", text: $workspace.mongoDraft.limit).frame(width: 70)
                    Spacer()
                    Button("Save Query") { perform { let command = try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name); workspace.queryText = command; workspace.saveSnippet() } }
                }.font(.bodyText).textFieldStyle(.roundedBorder).padding(.horizontal, Spacing.m).frame(height: Sizes.toolbar)
                HSplitView {
                    DesktopJSONField(title: "Filter (JSON)", text: $workspace.mongoDraft.filter)
                    DesktopJSONField(title: "Projection (JSON)", text: $workspace.mongoDraft.projection)
                    DesktopJSONField(title: "Sort (JSON)", text: $workspace.mongoDraft.sort)
                }
            } else {
                ScrollView {
                    VStack(spacing: Spacing.s) {
                        ForEach($workspace.mongoDraft.stages) { $stage in
                            VStack(spacing: 0) {
                                HStack {
                                    Toggle(isOn: $stage.isEnabled) { Text(verbatim: stage.operation) }.toggleStyle(.checkbox)
                                    Spacer()
                                    Button("Move Up", systemImage: "chevron.up") { move(stage.id, by: -1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.first?.id == stage.id)
                                    Button("Move Down", systemImage: "chevron.down") { move(stage.id, by: 1) }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(workspace.mongoDraft.stages.last?.id == stage.id)
                                    Button("Delete", systemImage: "xmark") { workspace.mongoDraft.stages.removeAll { $0.id == stage.id } }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                }.font(.bodyText).padding(Spacing.s)
                                DesktopJSONField(title: "Stage", text: $stage.body).frame(height: 120).disabled(!stage.isEnabled)
                            }.border(Color(nsColor: .separatorColor))
                        }
                        Menu { ForEach(MongoPipelineStage.operations, id: \.self) { operation in Button(operation) { workspace.mongoDraft.stages.append(MongoPipelineStage(operation: operation, body: MongoPipelineStage.template(for: operation))) } } } label: { Label("Add Stage", systemImage: "plus") }.disabled(workspace.mongoDraft.stages.count >= 64)
                    }.padding(Spacing.m)
                }
            }
            if let validation { Text(validation).font(.captionText).foregroundStyle(.red).padding(Spacing.xs) }
        }
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let index = workspace.mongoDraft.stages.firstIndex(where: { $0.id == id }), workspace.mongoDraft.stages.indices.contains(index + delta) else { return }
        workspace.mongoDraft.stages.swapAt(index, index + delta)
    }
    private func perform(_ action: () throws -> Void) { do { try action(); validation = nil } catch { validation = error.localizedDescription } }
}

struct DesktopJSONField: View {
    let title: String
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursor = 0
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Text(L10n.text(title)).font(.rowDetail).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).portbaseBar(Sizes.control)
            HighlightedQueryEditor(text: $text, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.frame(minWidth: 150)
    }
}

struct DesktopSettingsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @AppStorage("Portbase.editorFontSize") private var editorFontSize = 13.0
    var body: some View {
        TabView {
            Form {
                Section { AboutHeader() }
                Section("iCloud") {
                    LabeledContent("Status", value: FileManager.default.ubiquityIdentityToken == nil ? L10n.text("Sign in to iCloud in System Settings.") : L10n.text("iCloud available"))
                    ConnectionSecretSyncToggle()
                    SSHHostKeySyncToggle()
                    Text("Connections, saved queries, and chart configurations sync with iCloud. Query history, results, and SQLite files stay on this device.").font(.footnoteText).foregroundStyle(.secondary)
                    if let error = bookmarks.cloudSyncError ?? library.cloudSyncError { Text(error).foregroundStyle(.red) }
                    Button("Sync Now") { bookmarks.synchronizeCloud(); library.synchronizeCloud() }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
            .tabItem { Label("General", systemImage: "gearshape") }

            // Its own tab: pushed inside the General tab, its back button landed among the tabs.
            LibraryStorageView()
                .scrollContentBackground(.hidden)
                .background(PortSQLPalette.canvasTop)
                .tabItem { Label("Library", systemImage: "archivebox") }

            Form {
                AppearanceSettingsSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                EditorThemeSettingsSection()
                ResultHeaderStyleSettingsSection()
                Section("Text Size") {
                    Slider(value: $editorFontSize, in: 10...24, step: 1) { Text("Text Size") }
                    LabeledContent("Size", value: L10n.format("%d pt", Int(editorFontSize)))
                    Button("Reset Text Size") { editorFontSize = 13 }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(PortSQLPalette.canvasTop)
            .tabItem { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }

            AssistantSettingsView()
                .background(PortSQLPalette.canvasTop)
                .tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .frame(width: 580, height: 520)
    }
}

struct DesktopRowEditor: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    private func close() { workspace.dismissDataEditor(); dismiss() }

    var body: some View {
        PortbaseSheet(workspace.dataEditorDraft?.mode.title ?? L10n.text("Data Editor"),
                      subtitle: workspace.dataEditorDraft?.table.displayName, onClose: close) {
            ScrollView {
                if let draft = Binding($workspace.dataEditorDraft) {
                    VStack(spacing: Spacing.m) {
                        ForEach(draft.fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
                                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                    HStack(spacing: Spacing.xxs) {
                                        Text(verbatim: field.wrappedValue.column.name).font(.codeDetail).foregroundStyle(PortSQLPalette.ink)
                                        if field.wrappedValue.column.isPrimaryKey {
                                            Image(systemName: "key.fill").font(.microText).foregroundStyle(PortSQLPalette.accent).help("Primary key")
                                        }
                                    }
                                    Text(field.wrappedValue.column.type.lowercased()).font(.codeCaption).foregroundStyle(PortSQLPalette.muted)
                                }
                                .frame(width: 160, alignment: .leading)
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    DesktopRowValue(field: field)
                                    if let error = workspace.dataEditorValidation[field.wrappedValue.id] {
                                        Label(error, systemImage: "exclamationmark.circle").font(.captionText).foregroundStyle(.red)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                if field.wrappedValue.column.isNullable && field.wrappedValue.isEditable {
                                    Toggle("NULL", isOn: field.isNull).toggleStyle(.checkbox).font(.captionText).frame(width: 62)
                                        .accessibilityHint("Stores a database NULL instead of a value")
                                } else { Spacer().frame(width: 62) }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.l)
                }
            }
            .frame(maxHeight: 600)
            if let error = workspace.dataEditorErrorMessage {
                StatusBanner(title: L10n.text("Save failed"), message: error, tint: .red)
                    .padding(.horizontal, Spacing.xl).padding(.bottom, Spacing.m)
            }
        } footer: {
            if workspace.isSavingMutation { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            if workspace.dataEditorDraft?.mode == .view {
                Button("Done", action: close).buttonStyle(.portbasePrimary).keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close).buttonStyle(.portbaseSecondary).disabled(workspace.isSavingMutation)
                Button("Save") { workspace.saveDataEditor() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.isSavingMutation)
            }
        }
        .interactiveDismissDisabled(workspace.isSavingMutation)
        .onChange(of: workspace.dataEditorDraft == nil) { _, empty in if empty { dismiss() } }
    }
}

struct DesktopRowValue: View {
    @Binding var field: DataEditorField
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursor = 0
    @State private var selection = 0
    var body: some View {
        Group {
            if field.isNull { Text("NULL").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(height: Sizes.control) }
            else if !field.isEditable { Text(field.value.isEmpty ? "\"\"" : field.value).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            else if DataEditorValidationService.isJSONColumn(field.column) {
                VStack(spacing: 0) {
                    HStack {
                        Text("JSON").foregroundStyle(.secondary)
                        Spacer()
                        Button("Format") { if let formatted = DataEditorValidationService.formattedJSON(field.value) { field.value = formatted } }.buttonStyle(.borderless)
                    }.font(.rowDetail).padding(Spacing.xxs)
                    HighlightedQueryEditor(text: $field.value, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true).frame(height: 120)
                }
                .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
            } else {
                TextField(DataEditorValidationService.placeholder(for: field.column), text: $field.value).labelsHidden().textFieldStyle(.plain).autocorrectionDisabled()
                    .portbaseFieldChrome()
                    .accessibilityLabel(field.column.name)
            }
        }.font(.codeText)
    }
}

/// A one-line connection problem in the sidebar; the full explanation opens in a popover.
struct SidebarConnectionIssueRow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let message: String
    @State private var showsIssue = false

    var body: some View {
        let issue = ConnectionIssue.classify(message)
        Button { showsIssue = true } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: issue.isSecurityIssue ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.96, green: 0.62, blue: 0.04))
                Text(issue.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xxs)
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .font(.rowDetail.weight(.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue.guidance)
        .accessibilityLabel(issue.title)
        .accessibilityHint(issue.guidance)
        .popover(isPresented: $showsIssue, arrowEdge: .trailing) {
            ConnectionIssueBanner(message: message,
                                  onEdit: { showsIssue = false; workspace.editCurrentConnection() },
                                  onReconnect: { showsIssue = false; workspace.reconnect() },
                                  onReviewCertificate: { showsIssue = false; workspace.reviewServerCertificate() })
                .padding(Spacing.m)
                .frame(width: 420)
        }
    }
}

/// The fields of one loaded row, listed vertically with their types.
struct RowDetailsPanel: View {
    let result: QueryResultTable
    let rowIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Row Details").font(.cardTitle)
                Spacer()
                if let rowIndex { Text(L10n.format("Row %d", rowIndex + 1)).font(.captionText).foregroundStyle(.secondary) }
            }
            .portbaseBar()
            Divider()
            if let rowIndex, result.rows.indices.contains(rowIndex) {
                let row = result.rows[rowIndex]
                List {
                    ForEach(result.columns.indices, id: \.self) { index in
                        let cell = row.cells.indices.contains(index) ? row.cells[index] : .null
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack(spacing: Spacing.xs) {
                                Text(result.columns[index].name).font(.captionStrong).foregroundStyle(.secondary)
                                Text(result.columns[index].type.lowercased()).font(.microText).foregroundStyle(.tertiary)
                                Spacer(minLength: Spacing.xxs)
                                Button { PortbaseClipboard.copy(cell.exactValue) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .disabled(cell.isNull)
                                    .help(L10n.text("Copy"))
                            }
                            Group {
                                if cell.isNull {
                                    Text(verbatim: "NULL").italic().foregroundStyle(.tertiary)
                                } else if cell.displayValue.isEmpty {
                                    Text(verbatim: "\"\"").foregroundStyle(.tertiary).help(L10n.text("Empty text"))
                                } else {
                                    Text(cell.displayValue).textSelection(.enabled).lineLimit(12)
                                }
                            }
                            .font(.codeText)
                        }
                        .padding(.vertical, Spacing.xxxs)
                    }
                }
                .listStyle(.inset)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(PortSQLPalette.surface)
    }
}
