import SwiftUI

struct MongoQueryEditorCard: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var validationMessage: String?
    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
            Picker("Query", selection: $workspace.mongoDraft.mode) {
                ForEach(MongoEditorMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            if workspace.mongoDraft.mode != .command { QueryLibraryButton() }
            }
            if workspace.mongoDraft.mode == .command {
                QueryEditorCard()
            } else {
                PanelCard {
                    VStack(alignment: .leading, spacing: 12) {
                        collectionField
                        actions
                        if workspace.mongoDraft.mode == .find {
                            MongoJSONField(title: "Filter (JSON)", text: $workspace.mongoDraft.filter)
                            MongoJSONField(title: "Projection (JSON)", text: $workspace.mongoDraft.projection)
                            MongoJSONField(title: "Sort (JSON)", text: $workspace.mongoDraft.sort)
                            HStack(spacing: 16) {
                                numberField("Skip", text: $workspace.mongoDraft.skip)
                                numberField("Limit", text: $workspace.mongoDraft.limit)
                            }
                        } else {
                            pipeline
                        }
                        if let validationMessage {
                            Text(validationMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                        DisclosureGroup("Command", isExpanded: $showsCommand) {
                            Text(commandPreview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
        .onChange(of: workspace.mongoDraft.mode) { _, _ in validationMessage = nil }
    }

    private var collectionField: some View {
        HStack {
            Text("Collection").font(.subheadline.weight(.semibold))
            TextField("Collection", text: Binding(
                get: { workspace.mongoDraft.collection.isEmpty ? workspace.selectedExplorerTable?.name ?? "" : workspace.mongoDraft.collection },
                set: { workspace.mongoDraft.collection = $0 }
            ))
            .font(.system(.body, design: .monospaced))
            .portbaseTextCapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Collection")
            Menu {
                ForEach(workspace.schemaCatalog) { table in
                    Button(table.name) { workspace.mongoDraft.collection = table.name }
                }
            } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Collections")
            .disabled(workspace.schemaCatalog.isEmpty)
        }
        .frame(minHeight: 44)
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    if workspace.isRunning { workspace.cancelQuery() }
                    else { perform { try workspace.runMongoBuilder() } }
                } label: {
                    Label(workspace.isRunning ? L10n.text("Cancel Query") : L10n.text("Run Query"),
                          systemImage: workspace.isRunning ? "stop.fill" : "play.fill")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!workspace.isRunning && (workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil))
                DataTransferMenu()
                ScriptFilesButton()
                MongoIndexesButton()
                tool("EXPLAIN", icon: "waveform.path.ecg") { try workspace.runMongoBuilder(explain: true) }
                    .disabled(workspace.isRunning || workspace.selectedBookmark == nil || workspace.activeDatabaseName == nil)
                tool("SAVE", icon: "bookmark") {
                    workspace.queryText = try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name)
                    workspace.saveSnippet()
                }
                tool("Edit command", icon: "curlybraces") {
                    workspace.editMongoCommand(try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name))
                }
                Menu {
                    if let url = workspace.exportResultURL(format: .json) { ShareLink("JSON", item: url) }
                    if let url = workspace.exportResultURL(format: .csv) { ShareLink("CSV", item: url) }
                } label: {
                    Label("EXPORT", systemImage: "square.and.arrow.up").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                .disabled(workspace.result.documents == nil && workspace.result.columns.isEmpty)
            }
        }
    }

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($workspace.mongoDraft.stages) { $stage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle("Enable stage", isOn: $stage.isEnabled).labelsHidden()
                        Text(verbatim: stage.operation).font(.system(.body, design: .monospaced))
                        Spacer()
                        Menu {
                            Button("Move Up") { move(stage.id, by: -1) }
                                .disabled(workspace.mongoDraft.stages.first?.id == stage.id)
                            Button("Move Down") { move(stage.id, by: 1) }
                                .disabled(workspace.mongoDraft.stages.last?.id == stage.id)
                            Button("Delete", role: .destructive) { workspace.mongoDraft.stages.removeAll { $0.id == stage.id } }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.format("Stage %d", (workspace.mongoDraft.stages.firstIndex { $0.id == stage.id } ?? 0) + 1))
                    }
                    MongoJSONField(title: nil, text: $stage.body)
                        .disabled(!stage.isEnabled)
                        .opacity(stage.isEnabled ? 1 : 0.5)
                }
                Divider()
            }
            Menu {
                ForEach(MongoPipelineStage.operations, id: \.self) { operation in
                    Button(operation) {
                        workspace.mongoDraft.stages.append(MongoPipelineStage(operation: operation, body: MongoPipelineStage.template(for: operation)))
                    }
                }
            } label: { Label("Add Stage", systemImage: "plus").frame(minHeight: 44) }
            .disabled(workspace.mongoDraft.stages.count >= 64)
        }
    }

    private var commandPreview: String {
        do { return try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name) }
        catch { return error.localizedDescription }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let index = workspace.mongoDraft.stages.firstIndex(where: { $0.id == id }),
              workspace.mongoDraft.stages.indices.contains(index + delta) else { return }
        workspace.mongoDraft.stages.swapAt(index, index + delta)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); validationMessage = nil }
        catch { validationMessage = error.localizedDescription }
    }

    private func tool(_ title: String, icon: String, action: @escaping () throws -> Void) -> some View {
        Button { perform(action) } label: {
            Label(L10n.text(title), systemImage: icon).labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.buttonStyle(.borderless)
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.text(title), text: text)
                .portbaseKeyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.text(title))
        }.frame(minHeight: 44)
    }
}

private struct MongoJSONField: View {
    let title: String?
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var cursor = 0
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary) }
            HighlightedQueryEditor(text: $text, cursorOffset: $cursor, selectionLength: $selection, colorScheme: colorScheme, isJSON: true, fitsContent: true)
                .frame(minHeight: 64, maxHeight: 220)
                .background(PortSQLPalette.editorBackground(for: colorScheme))
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(PortSQLPalette.stroke, lineWidth: 1) }
                .accessibilityLabel(L10n.text(title ?? "JSON Editor"))
        }
    }
}
