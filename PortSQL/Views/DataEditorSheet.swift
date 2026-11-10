import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

struct QueryParameterSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QueryParameterDraft

    init(draft: QueryParameterDraft) {
        _draft = State(initialValue: draft)
    }

    private var preview: String {
        QueryParameterService.render(
            sql: draft.sourceSQL,
            values: draft.values,
            nullParameters: draft.nullParameters,
            engine: workspace.selectedBookmark?.engine ?? .postgresql
        )
    }

    var body: some View {
        PortbaseSheet(L10n.text("Query Parameters"), onClose: { workspace.cancelParameters(); dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ForEach(draft.names, id: \.self) { name in
                        let isNull = draft.nullParameters.contains(name)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text(verbatim: name).font(.codeCaption).foregroundStyle(PortSQLPalette.muted)
                                Spacer(minLength: Spacing.s)
                                Toggle("NULL", isOn: Binding(
                                    get: { isNull },
                                    set: { enabled in
                                        if enabled { draft.nullParameters.insert(name) }
                                        else { draft.nullParameters.remove(name) }
                                    }
                                ))
                                .font(.captionText)
                            }
                            TextField(isNull ? "NULL" : L10n.text("Value"), text: Binding(
                                get: { draft.values[name] ?? "" },
                                set: { draft.values[name] = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(.codeText)
                            .disabled(isNull)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                            .portbaseFieldChrome()
                            .accessibilityLabel(name)
                        }
                    }
                    if let parameterErrorMessage = workspace.parameterErrorMessage {
                        Label(parameterErrorMessage, systemImage: "exclamationmark.circle")
                            .font(.captionText)
                            .foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        PortbaseFieldLabel(L10n.text("Preview"))
                        PortbaseCodeBlock(text: preview)
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.l)
            }
        } footer: {
            Button("Cancel") { workspace.cancelParameters(); dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button("Apply") { if workspace.applyParameters(draft) { dismiss() } }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct DataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var workspace: WorkspaceViewModel

    private func close() {
        workspace.dismissDataEditor()
        dismiss()
    }

    var body: some View {
        PortbaseSheet(L10n.text(workspace.dataEditorDraft?.mode.title ?? "Data Editor"),
                      subtitle: workspace.dataEditorDraft?.table.displayName,
                      onClose: close) {
            if let binding = Binding($workspace.dataEditorDraft) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        Text(editorSubtitle(for: binding.wrappedValue.mode))
                            .font(.captionText)
                            .foregroundStyle(PortSQLPalette.muted)
                        if let errorMessage = workspace.dataEditorErrorMessage {
                            StatusBanner(title: L10n.text("Save failed"), message: errorMessage, tint: .red)
                        }
                        ForEach(binding.fields) { fieldBinding in
                            let field = fieldBinding.wrappedValue
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                HStack(spacing: Spacing.s) {
                                    Text(verbatim: field.column.name).font(.codeDetail).foregroundStyle(PortSQLPalette.ink)
                                    if field.column.isPrimaryKey {
                                        PortbaseChip(title: L10n.text("PK"), systemImage: "key.fill", tint: PortSQLPalette.accent)
                                    }
                                    Spacer(minLength: Spacing.s)
                                    Text(L10n.format("%@ • %@", field.column.type, L10n.text(field.column.isNullable ? "nullable" : "required")))
                                        .font(.captionText)
                                        .foregroundStyle(PortSQLPalette.muted)
                                }
                                fieldValueEditor(fieldBinding)
                                if field.column.isNullable, field.isEditable {
                                    Toggle("NULL", isOn: fieldBinding.isNull)
                                        .font(.captionText)
                                        .accessibilityHint("Stores a database NULL instead of a value")
                                }
                                if let validationMessage = workspace.dataEditorValidation[field.id] {
                                    Label(validationMessage, systemImage: "exclamationmark.circle")
                                        .font(.captionText)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.l)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            if workspace.dataEditorDraft?.mode == .view {
                Button("Done", action: close)
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: close)
                    .buttonStyle(.portbaseSecondary)
                    .disabled(workspace.isSavingMutation)
                Button("Save") { workspace.saveDataEditor() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.isSavingMutation)
            }
        }
        .interactiveDismissDisabled(workspace.isSavingMutation)
        .onChange(of: workspace.dataEditorDraft == nil) { _, isNil in
            if isNil {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func fieldValueEditor(_ fieldBinding: Binding<DataEditorField>) -> some View {
        if fieldBinding.wrappedValue.isNull {
            Text("NULL")
                .font(.codeText)
                .foregroundStyle(.secondary)
                .italic()
        } else if DataEditorValidationService.isJSONColumn(fieldBinding.wrappedValue.column) {
            JSONFieldEditor(
                value: fieldBinding.value,
                isEditable: fieldBinding.wrappedValue.isEditable,
                placeholder: DataEditorValidationService.placeholder(for: fieldBinding.wrappedValue.column),
                colorScheme: colorScheme
            )
        } else if fieldBinding.wrappedValue.isEditable {
            TextField(
                DataEditorValidationService.placeholder(for: fieldBinding.wrappedValue.column),
                text: fieldBinding.value
            )
            .textFieldStyle(.plain)
            .portbaseTextCapitalization(.never)
            .autocorrectionDisabled()
            .font(.codeText)
            .portbaseKeyboardType(DataEditorValidationService.keyboardType(for: fieldBinding.wrappedValue.column))
            .portbaseFieldChrome()
        } else {
            Text(fieldBinding.wrappedValue.value.isEmpty ? "\"\"" : fieldBinding.wrappedValue.value)
                .font(.codeText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .portbaseFieldChrome()
        }
    }

    private func editorSubtitle(for mode: DataEditorMode) -> String {
        switch mode {
        case .view:
            return L10n.text("Inspect the selected row. This result isn’t currently writable, so fields are shown read-only.")
        case .insert:
            return L10n.text("Insert a new row with schema-aware validation.")
        case .update:
            return L10n.text("Update the selected row and write the mutation back to the database.")
        }
    }
}

private struct JSONFieldEditor: View {
    @Binding var value: String
    let isEditable: Bool
    let placeholder: String
    let colorScheme: ColorScheme

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidJSON: Bool {
        trimmedValue.isEmpty || DataEditorValidationService.formattedJSON(trimmedValue) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if isEditable {
                HStack(spacing: Spacing.s) {
                    Label(isValidJSON ? "JSON" : L10n.text("Invalid JSON"), systemImage: isValidJSON ? "curlybraces" : "exclamationmark.triangle.fill")
                        .font(.captionStrong)
                        .foregroundStyle(isValidJSON ? Color.secondary : Color.red)

                    Spacer()

                    Button("Format") {
                        applyJSONFormatting(prettyPrinted: true)
                    }
                    .font(.captionStrong)
                    .disabled(!canFormatJSON)

                    Button("Minify") {
                        applyJSONFormatting(prettyPrinted: false)
                    }
                    .font(.captionStrong)
                    .disabled(!canFormatJSON)
                }

                ZStack(alignment: .topLeading) {
                    if value.isEmpty {
                        Text(placeholder)
                            .font(.codeText)
                            .foregroundStyle(PortSQLPalette.editorPlaceholder(for: colorScheme))
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.s)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $value)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.codeText)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.xxs)
                }
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(isValidJSON ? PortSQLPalette.editorBorder(for: colorScheme) : Color.red.opacity(0.55), lineWidth: 1)
                }
            } else {
                ScrollView {
                    Text(value.isEmpty ? "NULL" : value)
                        .font(.codeText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 180)
                .padding(Spacing.m)
                .background(PortSQLPalette.editorBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(PortSQLPalette.editorBorder(for: colorScheme), lineWidth: 1)
                }
            }
        }
    }

    private var canFormatJSON: Bool {
        DataEditorValidationService.formattedJSON(trimmedValue) != nil
    }

    private func applyJSONFormatting(prettyPrinted: Bool) {
        guard let formatted = DataEditorValidationService.formattedJSON(trimmedValue, prettyPrinted: prettyPrinted) else {
            return
        }
        value = formatted
    }
}


private extension Binding {
    init?(_ source: Binding<Value?>) {
        guard let wrapped = source.wrappedValue else { return nil }
        self.init(
            get: { source.wrappedValue ?? wrapped },
            set: { source.wrappedValue = $0 }
        )
    }
}

private extension Binding where Value == DataEditorDraft {
    var fields: [Binding<DataEditorField>] {
        wrappedValue.fields.indices.map { index in
            Binding<DataEditorField>(
                get: { wrappedValue.fields[index] },
                set: { wrappedValue.fields[index] = $0 }
            )
        }
    }
}

private extension Binding where Value == DataEditorField {
    var value: Binding<String> {
        Binding<String>(
            get: { wrappedValue.value },
            set: { wrappedValue.value = $0 }
        )
    }
}
