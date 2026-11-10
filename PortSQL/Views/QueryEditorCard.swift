import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

struct QueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceIsFlat) private var flat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var editorMinimumHeight: CGFloat = 160
    /// Set when there are no results yet, so the editor grows into the space they'd take.
    @Environment(\.workspaceFillsHeight) private var fillsHeight
    @State private var isShowingExpandedEditor = false
    /// Typing publishes here, not on the workspace; see `QueryEditorState`.
    @EnvironmentObject private var editor: QueryEditorState
    @State private var isShowingLibrarySheet = false

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: flat ? Spacing.s : Spacing.m) {
                if bookmarks.bookmarks.isEmpty {
                    connectionSection
                }
                actionSection
                editorSection
                statusLine
                if workspace.isDocumentDatabase {
                    Menu {
                        Button("Browse documents") { workspace.useMongoTemplate("find") }
                        Button("Aggregation") { workspace.useMongoTemplate("aggregate") }
                        Button("Indexes") { workspace.useMongoTemplate("listIndexes") }
                        if workspace.selectedBookmark?.isReadOnly != true {
                            Button("Insert document") { workspace.useMongoTemplate("insert") }
                            Button("Update documents") { workspace.useMongoTemplate("update") }
                            Button("Delete documents") { workspace.useMongoTemplate("delete") }
                        }
                    } label: {
                        Label("Query templates", systemImage: "curlybraces").frame(minHeight: Sizes.touchTarget)
                    }
                    .disabled(workspace.selectedExplorerTable == nil)
                }
                feedbackSection
            }
        }
        .portbaseEditorPresentation(isPresented: $isShowingExpandedEditor) {
            ExpandedQueryEditorSheet()
        }
        .sheet(isPresented: $isShowingLibrarySheet) {
            LibrarySheetView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Button {
            workspace.createBookmark()
        } label: {
            Label("Add Connection", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: Sizes.buttonContent)
        }
        .buttonStyle(.portbasePrimary)
    }

    /// Run, Run All, Format, and Explain stay in view; everything else is one menu away, rather than
    /// scrolling off the edge of a row where nothing says it's there.
    private var actionSection: some View {
        HStack(spacing: Spacing.s) {
            runButton
            if workspace.isSQLDatabase {
                actionButton("Run All", systemImage: "play.rectangle", labeled: true, disabled: workspace.isRunning || workspace.selectedBookmark == nil) {
                    workspace.runQuery(entireBuffer: true)
                }
            }
            actionButton("Format", systemImage: "text.alignleft", labeled: true, disabled: trimmedQuery.isEmpty) {
                workspace.formatQuery()
            }
            if workspace.isSQLDatabase || workspace.isDocumentDatabase {
                actionButton("Explain", systemImage: "waveform.path.ecg", labeled: true, disabled: workspace.selectedBookmark == nil || trimmedQuery.isEmpty) {
                    workspace.runExplain()
                }
            }
            Spacer(minLength: 0)
            ConsoleCommitControls()
            Button {
                workspace.isShowingAssistant = true
            } label: {
                Image(systemName: "sparkles").toolIconChrome()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask AI")
            ConsoleMoreMenu(openLibrary: { isShowingLibrarySheet = true }, openFullScreen: { isShowingExpandedEditor = true })
        }
    }

    private var statusLine: some View {
        HStack(spacing: Spacing.s) {
            Text(workspace.editorPositionLabel)
                .font(.codeCaption)
                .foregroundStyle(.secondary)
            if workspace.hasQuerySelection {
                PortbaseChip(title: L10n.text("Selection"), systemImage: "selection.pin.in.out", tint: PortSQLPalette.accent)
            }
            Spacer(minLength: 0)
        }
    }

    private var editorSection: some View {
        ZStack(alignment: .topLeading) {
            HighlightedQueryEditor(
                text: $workspace.queryText,
                cursorOffset: $workspace.queryCursorOffset,
                selectionLength: $workspace.querySelectionLength,
                colorScheme: colorScheme,
                isJSON: workspace.usesJSONEditor,
                allowsSQLComments: workspace.isSQLDatabase,
                completion: workspace.isSQLDatabase ? workspace.completion : nil,
                errorRange: workspace.queryErrorRange,
                engine: workspace.isSQLDatabase ? workspace.selectedBookmark?.engine : nil
            )
                .frame(minHeight: min(max(editorMinimumHeight, 160), 360), maxHeight: fillsHeight ? .infinity : nil)

            if workspace.queryText.isEmpty {
                Text(verbatim: workspace.editorPlaceholder)
                    .font(.codeText)
                    .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                    .padding(.leading, Sizes.editorGutter + Spacing.s)
                    .padding(.trailing, Spacing.l)
                    .padding(.vertical, Spacing.l)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: flat ? 0 : Radius.card, style: .continuous)
                .fill(editorBackgroundColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: flat ? 0 : Radius.card, style: .continuous))
        .overlay {
            if flat {
                // Edge to edge on phones: lines above and below, red while the query has an error.
                VStack(spacing: 0) {
                    Rectangle().fill(workspace.queryErrorRange == nil ? editorBorderColor : Color.red.opacity(0.5)).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(workspace.queryErrorRange == nil ? editorBorderColor : Color.red.opacity(0.5)).frame(height: 1)
                }
            } else {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(workspace.queryErrorRange == nil ? editorBorderColor : Color.red.opacity(0.5), lineWidth: 1)
            }
        }
        .padding(.horizontal, flat ? -Spacing.m : 0)
    }

    private var editorBackgroundColor: Color {
        PortSQLPalette.editorBackground(for: colorScheme)
    }

    private var editorBorderColor: Color {
        PortSQLPalette.editorBorder(for: colorScheme)
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if let schemaErrorMessage = workspace.schemaErrorMessage {
            ConnectionIssueBanner(message: schemaErrorMessage, onEdit: workspace.editCurrentConnection, onReconnect: workspace.reconnect,
                                  onReviewCertificate: { workspace.reviewServerCertificate() })
        }

        // One line per hint, not a banner. Once a run has failed, its error says what's wrong and the
        // advance warnings step aside rather than repeat it.
        if workspace.errorMessage == nil {
            ForEach(workspace.hints) { hint in
                Label {
                    (Text(hint.title).font(.rowDetail.weight(.semibold)) + Text(verbatim: "  ") + Text(hint.message).font(.captionText).foregroundColor(.secondary))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: hint.severity == .info ? "info.circle" : "exclamationmark.triangle.fill").foregroundStyle(hint.severity.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var trimmedQuery: String {
        workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var runButton: some View {
        Button {
            if workspace.isRunning { workspace.cancelQuery() }
            else { workspace.runQuery() }
        } label: {
            HStack(spacing: Spacing.s) {
                if workspace.isRunning {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Stop")
                } else {
                    Image(systemName: "play.fill")
                    Text(workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run"))
                }
            }
            .font(.rowDetail.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: Sizes.touchTarget)
            .background {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous).fill(workspace.isRunning ? Color.red : PortSQLPalette.accent)
            }
            .opacity(runDisabled ? 0.45 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(runDisabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(workspace.isRunning ? L10n.text("Cancel Query") : (workspace.hasQuerySelection ? L10n.text("Run Selection") : L10n.text("Run Query")))
    }

    private var runDisabled: Bool {
        !workspace.isRunning && (workspace.selectedBookmark == nil || trimmedQuery.isEmpty)
    }

    /// A console tool. The core actions show their names where there's room, as on the Mac; the rest
    /// stay icons with their name as help and accessibility label.
    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, labeled: Bool = false, disabled: Bool, action: @escaping () -> Void) -> some View {
        if labeled && horizontalSizeClass == .regular {
            Button(action: action) {
                Label(L10n.text(title), systemImage: systemImage)
                    .font(.rowDetail)
            }
            .buttonStyle(.portbaseToolbar)
            .disabled(disabled)
            .help(L10n.text(title))
        } else {
            Button(action: action) {
                Label(L10n.text(title), systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .toolIconChrome()
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(L10n.text(title))
        }
    }

}

/// The duration and outcome of the most recent console execution.
/// What a result is, in one quiet line: "100 rows · 8 columns · 86 ms · Editable". Only a truncated
/// result is colored, since that's the one fact that needs attention; a failure has its own error line.
struct ResultFactsLine: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        let result = workspace.result
        var facts: [String] = []
        if let documents = result.documents {
            facts.append(L10n.format("Documents: %d", documents.count))
        } else {
            facts.append(L10n.plural("row_count", count: result.rows.count))
        }
        if !result.columns.isEmpty { facts.append(L10n.plural("column_count", count: result.columns.count)) }
        if let execution = workspace.lastExecution, !workspace.isShowingExplorerResult {
            if execution.outcome == .cancelled { facts.append(execution.outcome?.title ?? "") }
            if execution.outcome != .failed, let duration = execution.duration { facts.append(WorkspaceActivityService.durationLabel(duration)) }
        }
        if workspace.canEditCurrentRows { facts.append(L10n.text("Editable")) }
        else if workspace.selectedBookmark?.isReadOnly == true { facts.append(L10n.text("Read-only")) }
        let line = Text(verbatim: facts.joined(separator: " · ")).foregroundColor(.secondary)
        return (result.isTruncated == true ? line + Text(verbatim: " · ") .foregroundColor(.secondary) + Text(L10n.text("Result truncated")).foregroundColor(.orange) : line)
            .font(.captionText.monospacedDigit())
            .lineLimit(1)
            // The last facts give way first, rather than a word losing its middle.
            .truncationMode(.tail)
    }
}

/// A failed run's error as one compact line, selectable so it can be copied into a search.
struct ExecutionErrorLine: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.captionText)
                .foregroundStyle(PortSQLPalette.ink)
                .lineLimit(4)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L10n.text("Execution failed") + ", " + message)
    }
}

struct ExecutionStatusChip: View {
    let entry: QueryHistoryEntry

    var body: some View {
        let outcome = entry.outcome ?? .succeeded
        PortbaseChip(
            title: [outcome.title, entry.duration.map { WorkspaceActivityService.durationLabel($0) }].compactMap { $0 }.joined(separator: " · "),
            systemImage: outcome == .succeeded ? "checkmark.circle.fill" : outcome == .failed ? "xmark.octagon.fill" : "stop.circle.fill",
            tint: outcome == .succeeded ? .green : outcome == .failed ? .red : .secondary
        )
        .accessibilityLabel(L10n.format("Last run: %@", outcome.title))
    }
}

private struct ExpandedQueryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    /// Typing publishes here, not on the workspace; see `QueryEditorState`.
    @EnvironmentObject private var editor: QueryEditorState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                WorkbenchBackground()
                    .ignoresSafeArea()

                ZStack(alignment: .topLeading) {
                    HighlightedQueryEditor(
                        text: $workspace.queryText,
                        cursorOffset: $workspace.queryCursorOffset,
                        selectionLength: $workspace.querySelectionLength,
                        colorScheme: colorScheme,
                        isJSON: workspace.usesJSONEditor,
                        allowsSQLComments: workspace.isSQLDatabase,
                        completion: workspace.isSQLDatabase ? workspace.completion : nil,
                        errorRange: workspace.queryErrorRange
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if workspace.queryText.isEmpty {
                        Text(verbatim: workspace.editorPlaceholder)
                            .font(.codeText)
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.leading, Sizes.editorGutter + Spacing.s)
                            .padding(.trailing, Spacing.l)
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
                .padding(Spacing.l)
            }
            .navigationTitle(workspace.usesJSONEditor ? L10n.text("JSON Editor") : workspace.isSQLDatabase ? L10n.text("SQL Editor") : L10n.text("Command Editor"))
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionStatusLine() }
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: PortbaseToolbar.leading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: PortbaseToolbar.trailing) {
                    Button {
                        if workspace.isRunning { workspace.cancelQuery() }
                        else { workspace.runQuery() }
                    } label: {
                        if workspace.isRunning {
                            Label("Cancel Query", systemImage: "stop.fill")
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .disabled(!workspace.isRunning && (workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil || workspace.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
    }
}
