import ImageIO
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
            ToolbarItem(placement: PortbaseToolbar.leading) { ConnectionSwitcherButton() }
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
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        if let identifier = MongoDocumentSummary.identifier(in: document) {
                            Text(verbatim: "_id").font(.codeCaption).foregroundStyle(.secondary)
                            Text(verbatim: identifier)
                                .font(.codeCaption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text(L10n.format("Document %d", index + 1)).font(.captionStrong)
                        }
                        Spacer(minLength: Spacing.s)
                        Button {
                            PortbaseClipboard.copy(document)
                        } label: {
                            Image(systemName: "doc.on.doc").frame(minWidth: Sizes.control, minHeight: Sizes.control)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Copy JSON")
                        Button {
                            selectedDocument = MongoDocumentSelection(index: index, json: document, context: context)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(minWidth: Sizes.control, minHeight: Sizes.control)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.format("Document %d", index + 1))
                        .accessibilityHint("Open full document")
                    }
                    MongoDocumentTree(json: document, preview: true)
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.xs)
                .portbaseCardSurface(radius: Radius.control)
                .padding(.bottom, Spacing.s)
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
        PortbaseSheet(L10n.format("Document %d", selection.index + 1)) {
            VStack(spacing: 0) {
                PortbaseTabs(selection: $showsJSON, options: [
                    PortbaseChoice(value: false, title: L10n.text("Document")), PortbaseChoice(value: true, title: L10n.text("JSON")),
                ])
                .padding(.horizontal, Spacing.xl)
                .overlay(alignment: .bottom) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
                ScrollView {
                    if showsJSON {
                        Text(MongoQueryService.formattedJSON(selection.json))
                            .font(.codeText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        MongoDocumentTree(json: selection.json).padding()
                    }
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
        } footer: {
            Menu {
                ShareLink(item: selection.json) { Label("JSON", systemImage: "square.and.arrow.up") }
                if selection.context != nil, (try? MongoExtendedJSON.decode(selection.json, maximumBytes: 128 * 1_024 * 1_024)["_id"]) != nil {
                    Button("Edit Document", systemImage: "pencil") { editing = .init(mode: .edit) }
                    Button("Duplicate Document", systemImage: "plus.square.on.square") { editing = .init(mode: .duplicate) }
                    Button("Delete Document", systemImage: "trash", role: .destructive) { editing = .init(mode: .delete) }
                }
            } label: { Label("Document Actions", systemImage: "ellipsis.circle") }
                .fixedSize()
                .menuStyle(.button)
                .buttonStyle(.portbaseToolbar)

            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
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
                Button("Show All Fields") { isShowingAll = true }.frame(minHeight: Sizes.control)
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
        default: return MongoExtendedJSON.display(value)
        }
    }

    /// PNG or JPEG bytes small enough to thumbnail while the row is on screen.
    var imageData: Data? {
        guard case .binary(let binary) = value, binary.data.readableBytes <= 8 * 1_024 * 1_024 else { return nil }
        let data = Data(binary.data.readableBytesView)
        return data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) ? data : nil
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
                            Button("Show More") { childLimit += 100 }.frame(minHeight: Sizes.control)
                        }
                    }
                    // A guide line under the parent's key marks each nesting level.
                    .padding(.leading, Spacing.l)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(PortSQLPalette.stroke).frame(width: 1).padding(.leading, Spacing.xs)
                    }
                } label: { label }
                .frame(minHeight: Sizes.control)
            } else { label }
        }
        .font(.codeCaption)
    }

    private var label: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                Text(verbatim: field.key).foregroundStyle(.secondary)
                value
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: field.key).foregroundStyle(.secondary)
                value
            }
        }
        .frame(minHeight: Sizes.control, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: field.key))
        .accessibilityValue(Text(verbatim: String(field.preview.prefix(500))))
    }

    private var value: some View {
        HStack(spacing: Spacing.s) {
            if let data = field.imageData { MongoImageThumbnail(data: data) }
            Text(verbatim: String(field.preview.prefix(500)))
                .foregroundStyle(field.value == .null ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}

private struct MongoImageThumbnail: View {
    let data: Data
    @State private var image: CGImage?

    var body: some View {
        // A fixed frame keeps the view present while the thumbnail loads; an empty view never runs its task.
        Color.clear
            .frame(width: 28, height: 28)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                        .overlay(RoundedRectangle(cornerRadius: Radius.xs).stroke(PortSQLPalette.stroke))
                }
            }
            .task(id: data) {
                let data = data
                image = await Task.detached(priority: .utility) { Self.thumbnail(data) }.value
            }
    }

    private nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

enum MongoDocumentSummary {
    /// The document's `_id`, decoded from Canonical Extended JSON wrappers such as `{"$oid": …}`.
    static func identifier(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["_id"] else { return nil }
        return describe(value)
    }

    private static func describe(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let wrapper = value as? [String: Any], wrapper.count == 1, let (key, inner) = wrapper.first, key.hasPrefix("$") {
            if let string = inner as? String { return string }
            if let nested = inner as? [String: Any], let date = nested["$numberLong"] as? String { return date }
            return describe(inner)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
