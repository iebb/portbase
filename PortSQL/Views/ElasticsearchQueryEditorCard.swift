import SwiftUI

struct ElasticsearchQueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var rawCommand = false
    @State private var method = "POST"
    @State private var path = "/_search"
    @State private var requestBody = "{\n  \"query\": {\"match_all\": {}},\n  \"size\": 100\n}"
    @State private var cursorOffset = 0
    @State private var selectionLength = 0
    @State private var lastWrittenCommand = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
            Picker("Query", selection: $rawCommand) {
                Text("Request").tag(false)
                Text("Command").tag(true)
            }
            .pickerStyle(.segmented)
            if !rawCommand { QueryLibraryButton() }
            }
            if rawCommand { QueryEditorCard() }
            else {
                PanelCard {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        ViewThatFits(in: .horizontal) {
                            HStack { methodPicker; pathField }
                            VStack(alignment: .leading) { methodPicker; pathField }
                        }
                        actions
                        if method != "DELETE" {
                            Text("Request Body").font(.rowTitle)
                            HighlightedQueryEditor(text: $requestBody, cursorOffset: $cursorOffset, selectionLength: $selectionLength,
                                colorScheme: colorScheme, isJSON: true, fitsContent: true)
                                .frame(minHeight: 200)
                                .accessibilityLabel("Request Body")
                        }
                        if let validationMessage {
                            Text(validationMessage).font(.captionText).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .onAppear { load(workspace.queryText) }
        .onChange(of: workspace.queryText) { _, value in if value != lastWrittenCommand { load(value) } }
        .onChange(of: method) { _, _ in sync() }
        .onChange(of: path) { _, _ in sync() }
        .onChange(of: requestBody) { _, _ in sync() }
    }

    private var methodPicker: some View {
        Picker("HTTP Method", selection: $method) {
            ForEach(["GET", "POST", "PUT", "DELETE"], id: \.self) { Text(verbatim: $0).tag($0) }
        }
        .frame(minHeight: Sizes.touchTarget).fixedSize(horizontal: true, vertical: false)
    }

    private var pathField: some View {
        TextField("Request Path", text: $path)
            .font(.codeText)
            .portbaseTextCapitalization(.never).autocorrectionDisabled()
            .frame(minHeight: Sizes.touchTarget).accessibilityLabel("Request Path")
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xxs) {
                Button {
                    if workspace.isRunning { workspace.cancelQuery() }
                    else if validate() { workspace.runQuery() }
                } label: {
                    Label(workspace.isRunning ? L10n.text("Cancel Query") : L10n.text("Run Query"),
                        systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                        .labelStyle(.iconOnly).frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                .disabled(!workspace.isRunning && workspace.selectedBookmark == nil)
                Button {
                    guard let body = try? HTTPJSONValue.parse(requestBody) else { validationMessage = L10n.text("Invalid JSON"); return }
                    requestBody = body.json(pretty: true)
                } label: { Label("Format", systemImage: "text.alignleft").labelStyle(.iconOnly).frame(width: Sizes.touchTarget, height: Sizes.touchTarget) }
                Button { if validate() { workspace.saveSnippet() } } label: {
                    Label("SAVE", systemImage: "bookmark").labelStyle(.iconOnly).frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                }
                Menu {
                    Button("Search") { workspace.queryText = ElasticsearchQueryService.browse(index: selectedIndex, limit: 100, offset: 0) }
                    Button("Count") { workspace.queryText = ElasticsearchCommand(method: "POST", path: "/\(selectedIndex)/_count", body: .object(["query": .object(["match_all": .object([:])])]), isReadOnly: true).preview }
                    Button("Aggregations") {
                        let field = workspace.selectedExplorerTable?.columns.first(where: { $0.type == "keyword" })?.name ?? "_index"
                        workspace.queryText = ElasticsearchCommand(method: "POST", path: "/\(selectedIndex)/_search", body: .object([
                            "size": .number("0"), "aggs": .object(["values": .object(["terms": .object(["field": .string(field), "size": .number("100")])])])
                        ]), isReadOnly: true).preview
                    }
                } label: { Label("Query Templates", systemImage: "text.badge.plus").labelStyle(.iconOnly).frame(width: Sizes.touchTarget, height: Sizes.touchTarget) }
                Menu {
                    if let url = workspace.exportResultURL(format: .json) { ShareLink("JSON", item: url) }
                    if let url = workspace.exportResultURL(format: .csv) { ShareLink("CSV", item: url) }
                } label: { Label("EXPORT", systemImage: "square.and.arrow.up").labelStyle(.iconOnly).frame(width: Sizes.touchTarget, height: Sizes.touchTarget) }
                .disabled(workspace.result.columns.isEmpty && workspace.result.documents == nil)
            }
        }
    }

    private var selectedIndex: String { workspace.selectedExplorerTable?.name ?? "_all" }

    private func sync() {
        let body = requestBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyField = method == "DELETE" || body.isEmpty ? "" : ",\n  \"body\": " + body
        let command = "{\n  \"method\": " + DataTransferCodec.jsonString(method) + ",\n  \"path\": " + DataTransferCodec.jsonString(path) + bodyField + "\n}"
        lastWrittenCommand = command
        workspace.queryText = command
        validationMessage = nil
    }

    private func load(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let command = try? ElasticsearchQueryService.parse(text) else { rawCommand = true; return }
        method = command.method; path = command.path; requestBody = command.body?.json(pretty: true) ?? ""
        validationMessage = nil
    }

    private func validate() -> Bool {
        sync()
        do { _ = try ElasticsearchQueryService.parse(workspace.queryText); return true }
        catch { validationMessage = error.localizedDescription; return false }
    }
}
