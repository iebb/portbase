import SwiftUI
@preconcurrency import SwiftBSON

struct MongoExplorerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        AdaptiveWorkspaceView {
            MongoQueryEditorCard()
        } trailing: {
            ResultsCard()
        }
        .background(WorkbenchBackground().ignoresSafeArea())
        .navigationTitle("Explorer")
        .portbaseTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: PortbaseToolbar.leading) { ConnectionSwitcherButton(toolbarMode: true) }
            ToolbarItemGroup(placement: PortbaseToolbar.trailing) {
                SchemaRefreshButton()
                DatabaseSwitcherButton()
            }
        }
    }


}

struct MongoDocumentResults: View {
    let documents: [String]
    var context: MongoDocumentMutationContext? = nil
    @State private var selectedDocument: MongoDocumentSelection?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if documents.isEmpty {
                Text("No documents matched the query.").foregroundStyle(.secondary)
            }
            ForEach(Array(documents.enumerated()), id: \.offset) { index, document in
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        selectedDocument = MongoDocumentSelection(index: index, json: document, context: context)
                    } label: {
                        HStack {
                            Text(L10n.format("Document %d", index + 1))
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: PortbaseControlSize.minimumHeight)
                    }
                    .accessibilityHint("Open full document")
                    MongoDocumentTree(json: document, preview: true)
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .sheet(item: $selectedDocument) { selection in
            MongoDocumentInspector(selection: selection).portbaseDesktopSheetSize()
        }
    }
}

struct MongoDocumentSelection: Identifiable {
    let id = UUID()
    let index: Int
    let json: String
    var context: MongoDocumentMutationContext? = nil
}

struct MongoDocumentInspector: View {
    let selection: MongoDocumentSelection
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var showsJSON = false
    @State private var editing: MongoDocumentEditorSelection?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Results", selection: $showsJSON) {
                    Text("Document").tag(false)
                    Text("JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                ScrollView {
                    if showsJSON {
                        Text(MongoQueryService.formattedJSON(selection.json))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        MongoDocumentTree(json: selection.json).padding()
                    }
                }
            }
            .navigationTitle(L10n.format("Document %d", selection.index + 1))
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ShareLink(item: selection.json) { Label("JSON", systemImage: "square.and.arrow.up") }
                        if selection.context != nil, (try? MongoExtendedJSON.decode(selection.json, maximumBytes: 128 * 1_024 * 1_024)["_id"]) != nil {
                            Button("Edit Document", systemImage: "pencil") { editing = .init(mode: .edit) }
                            Button("Duplicate Document", systemImage: "plus.square.on.square") { editing = .init(mode: .duplicate) }
                            Button("Delete Document", systemImage: "trash", role: .destructive) { editing = .init(mode: .delete) }
                        }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Document Actions") }
                }
            }
            .sheet(item: $editing) { editing in
                if let context = selection.context {
                    MongoDocumentEditor(context: context, mode: editing.mode, originalJSON: selection.json) {
                        if workspace.selectedBookmark?.id == context.profile.id,
                           workspace.activeDatabaseName == context.database,
                           workspace.selectedExplorerTable?.name == context.collection { workspace.browse() }
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct MongoDocumentEditorSelection: Identifiable {
    let id = UUID()
    let mode: MongoDocumentDraft.Mode
}

private struct MongoDocumentTree: View {
    let json: String
    var preview = false
    @State private var fields: [MongoTreeField] = []
    @State private var isShowingAll = false

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(preview && !isShowingAll ? Array(fields.prefix(6)) : fields) { field in
                MongoValueRow(field: field)
            }
            if preview && !isShowingAll && fields.count > 6 {
                Button("Show All Fields") { isShowingAll = true }.frame(minHeight: PortbaseControlSize.minimumHeight)
            }
        }
        .task(id: json) {
            guard let document = try? MongoExtendedJSON.decode(json, maximumBytes: 128 * 1_024 * 1_024) else { fields = []; return }
            fields = document.map { MongoTreeField(key: $0.key, value: $0.value) }
        }
    }
}

private struct MongoTreeField: Identifiable {
    var id: String { key }
    let key: String
    let value: BSON

    var children: [MongoTreeField]? {
        switch value {
        case .document(let document): document.map { MongoTreeField(key: $0.key, value: $0.value) }
        case .array(let array): array.enumerated().map { MongoTreeField(key: String($0.offset), value: $0.element) }
        default: nil
        }
    }

    var preview: String {
        switch value {
        case .document(let document): return "{\(document.count)}"
        case .array(let array): return "[\(array.count)]"
        case .string(let string): return String(reflecting: string)
        default: return MongoDatabaseClient.cell(value).displayValue
        }
    }
}

private struct MongoValueRow: View {
    let field: MongoTreeField
    @State private var expanded = false
    @State private var childLimit = 100

    var body: some View {
        Group {
            if let children = field.children {
                DisclosureGroup(isExpanded: $expanded) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(children.prefix(childLimit))) { child in MongoValueRow(field: child) }
                        if children.count > childLimit {
                            Button("Show More") { childLimit += 100 }.frame(minHeight: PortbaseControlSize.minimumHeight)
                        }
                    }
                } label: { label }
                .frame(minHeight: PortbaseControlSize.minimumHeight)
            } else { label }
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var label: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: field.key).foregroundStyle(.secondary)
                Text(verbatim: String(field.preview.prefix(500))).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: field.key).foregroundStyle(.secondary)
                Text(verbatim: String(field.preview.prefix(500))).textSelection(.enabled)
            }
        }
        .frame(minHeight: PortbaseControlSize.minimumHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: field.key))
        .accessibilityValue(Text(verbatim: String(field.preview.prefix(500))))
    }
}
