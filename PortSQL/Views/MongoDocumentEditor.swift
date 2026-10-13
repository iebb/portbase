import SwiftUI
@preconcurrency import SwiftBSON

struct MongoInsertDocumentButton: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var context: MongoDocumentMutationContext?

    var body: some View {
        if let current = MongoDocumentMutationContext.insertionContext(workspace: workspace) {
            Button { context = current } label: { Label("Insert Document", systemImage: "plus") }
#if os(macOS)
                .frame(minHeight: 24)
#else
                .frame(minHeight: Sizes.control)
#endif
                .disabled(workspace.isRunning)
                .sheet(item: $context) { context in
                    MongoDocumentEditor(context: context, mode: .insert) {
                        refreshCollection(context)
                    }
                }
        }
    }

    private func refreshCollection(_ context: MongoDocumentMutationContext) {
        guard workspace.selectedBookmark?.id == context.profile.id, workspace.activeDatabaseName == context.database,
              workspace.selectedExplorerTable?.name == context.collection else { return }
        workspace.browse()
    }
}

struct MongoDocumentEditor: View {
    let context: MongoDocumentMutationContext
    let mode: MongoDocumentDraft.Mode
    var originalJSON: String?
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MongoDocumentDraft?
    @State private var error: String?
    @State private var showsJSON = false
    @State private var jsonText = "{}"
    @State private var cursor = 0
    @State private var selectionLength = 0
    @State private var review: MongoMutationReview?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Collection", value: context.collection)
                    LabeledContent("Database", value: context.database)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                if mode == .delete {
                    Section("Document") {
                        Text(MongoQueryService.formattedJSON(originalJSON ?? "{}"))
                            .font(.codeCaption).textSelection(.enabled)
                    }
                } else {
                    Section {
                        Picker("Editor", selection: Binding(get: { showsJSON }, set: changeEditor)) {
                            Text("Fields").tag(false)
                            Text("JSON").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if showsJSON {
                        Section("Document") {
                            HighlightedQueryEditor(text: $jsonText, cursorOffset: $cursor, selectionLength: $selectionLength,
                                                   isJSON: true, fitsContent: true)
                        }
                    } else if draft != nil {
                        ForEach(draft?.fields ?? []) { field in
                            fieldSection(field: field)
                        }
                        Section {
                            Button("Add Field", systemImage: "plus") { draft?.fields.append(MongoDocumentField()) }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { prepareReview() }.disabled(draft == nil)
                }
            }
            .task {
                guard draft == nil else { return }
                do { draft = try MongoDocumentDraft(mode: mode, originalJSON: originalJSON) }
                catch { self.error = error.localizedDescription }
            }
            .sheet(item: $review) { review in
                MongoDocumentMutationReview(context: context, request: review.request) {
                    onSaved()
                    dismiss()
                }
            }
        }
    }

    private var title: String {
        switch mode {
        case .insert: L10n.text("Insert Document")
        case .edit: L10n.text("Edit Document")
        case .duplicate: L10n.text("Duplicate Document")
        case .delete: L10n.text("Delete Document")
        }
    }

    @ViewBuilder
    private func fieldSection(field: MongoDocumentField) -> some View {
        Section {
            HStack {
                TextField("Field name", text: fieldBinding(field, \.name))
                    .portbaseTextCapitalization(.never).autocorrectionDisabled().disabled(field.isIdentifier)
                if !field.isIdentifier {
                    Button(role: .destructive) {
                        draft?.fields.removeAll { $0.id == field.id }
                    } label: { Image(systemName: "trash").frame(minWidth: Sizes.control, minHeight: Sizes.control) }
                        .buttonStyle(.borderless).accessibilityLabel("Remove Field")
                }
            }
            Picker("Type", selection: fieldBinding(field, \.type)) {
                ForEach(MongoFieldType.allCases) { type in Text(type.title).tag(type) }
            }
            .disabled(field.isIdentifier)
            if field.type == .boolean {
                Toggle("Value", isOn: Binding(get: { fieldBinding(field, \.value).wrappedValue == "true" },
                                             set: { fieldBinding(field, \.value).wrappedValue = String($0) }))
                    .disabled(field.isIdentifier)
            } else if field.type == .null {
                Text(verbatim: "NULL").font(.codeText).foregroundStyle(.secondary)
            } else {
                TextField("Value", text: fieldBinding(field, \.value), axis: .vertical)
                    .font(.codeText)
                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                    .disabled(field.isIdentifier)
            }
        }
    }

    private func fieldBinding<Value>(_ field: MongoDocumentField, _ keyPath: WritableKeyPath<MongoDocumentField, Value>) -> Binding<Value> {
        Binding(get: { (draft?.fields.first { $0.id == field.id } ?? field)[keyPath: keyPath] }, set: { value in
            guard let index = draft?.fields.firstIndex(where: { $0.id == field.id }) else { return }
            draft!.fields[index][keyPath: keyPath] = value
        })
    }

    private func changeEditor(_ json: Bool) {
        do {
            guard var draft else { return }
            if json { jsonText = MongoQueryService.pretty(try draft.document(), canonical: true) }
            else {
                let document = try MongoExtendedJSON.decode(jsonText, maximumBytes: 128 * 1_024 * 1_024)
                draft.fields = document.map { MongoDocumentField(name: $0.key, value: $0.value, locksIdentifier: mode == .edit) }
                self.draft = draft
            }
            showsJSON = json
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func prepareReview() {
        do {
            guard var draft else { return }
            if showsJSON {
                let document = try MongoExtendedJSON.decode(jsonText, maximumBytes: 128 * 1_024 * 1_024)
                draft.fields = document.map { MongoDocumentField(name: $0.key, value: $0.value, locksIdentifier: mode == .edit) }
            }
            review = MongoMutationReview(request: try draft.request(collection: context.collection))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct MongoMutationReview: Identifiable {
    let id = UUID()
    let request: MongoDocumentMutationRequest
}

private struct MongoDocumentMutationReview: View {
    let context: MongoDocumentMutationContext
    let request: MongoDocumentMutationRequest
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var commitUnknown = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Connection", value: context.profile.name)
                    LabeledContent("Collection", value: context.collection)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if isSaving { ProgressView("Saving") }
                }
                if let original = request.originalJSON {
                    Section("Original Document") { json(original) }
                }
                if let replacement = request.replacementJSON {
                    Section("New Document") { json(replacement) }
                }
                Section("Command") {
                    Text((try? request.previewCommand()) ?? "")
                        .font(.codeCaption).textSelection(.enabled)
                }
                Section {
                    Text("The original document is checked again in a transaction. Conflicting changes cancel the save.")
                        .font(.captionText).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review Changes")
            .portbaseTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text(isSaving ? "Stop" : "Cancel")) {
                        if isSaving { task?.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text(request.operation == .delete ? "Delete" : "Save"), role: request.operation == .delete ? .destructive : nil) { save() }
                        .disabled(isSaving || commitUnknown)
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func json(_ text: String) -> some View {
        Text(MongoQueryService.formattedJSON(text)).font(.codeCaption).textSelection(.enabled)
    }

    private func save() {
        isSaving = true
        error = nil
        task = Task {
            do {
                _ = try await DatabaseService.shared.performMongoDocumentMutation(request: request, profile: context.profile,
                    database: context.database, policy: .mutation(expectedAffectedRows: 1))
                isSaving = false
                task = nil
                onSaved()
            } catch {
                self.error = error.localizedDescription
                if case MongoConnectionError.commitUnknown = error { commitUnknown = true }
                // Cancellation can arrive after commit was sent. Never offer a blind retry from this preview.
                if error is CancellationError { commitUnknown = true; self.error = MongoConnectionError.commitUnknown.localizedDescription }
                if case DatabaseServiceError.queryTimedOut = error { commitUnknown = true; self.error = MongoConnectionError.commitUnknown.localizedDescription }
                isSaving = false
                task = nil
            }
        }
    }
}
