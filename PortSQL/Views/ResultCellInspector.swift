import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ResultCellSelection: Identifiable {
    let id = UUID()
    let column: QueryColumn
    let cell: QueryCell
    let row: Int
    /// Present when the cell's row can be updated safely, which makes the value editable.
    var edit: ResultCellEdit?
}

/// What the value editor needs to change one cell: the field to edit and an apply action that stages it for Submit.
struct ResultCellEdit {
    let field: DataEditorField
    let engine: DatabaseEngine
    let save: @MainActor (DataEditorField) async throws -> Void
}

/// A snapshot of an editable rectangle. Every destination validates the same input using its own type.
struct ResultCellsEdit: Identifiable {
    let id = UUID()
    let fields: [DataEditorField]
    let engine: DatabaseEngine
    let save: @MainActor (String, Bool) throws -> Void

    var allowsNull: Bool { fields.allSatisfy { $0.column.isNullable } }

    func validationMessage(value: String, isNull: Bool) -> String? {
        let replacements = fields.map { field in
            var field = field
            field.value = value
            field.isNull = isNull
            return field
        }
        let errors = DataEditorValidationService.validate(fields: replacements, mode: .update, engine: engine)
        guard let field = replacements.first(where: { errors[$0.id] != nil }), let message = errors[field.id] else { return nil }
        return field.column.name + ": " + message
    }
}

struct ResultCellsEditor: View {
    let edit: ResultCellsEdit
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var isNull = false
    @State private var error: String?

    var body: some View {
        PortbaseSheet(L10n.text("Set Selected Values…"), subtitle: L10n.format("Cells: %d", edit.fields.count), onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if edit.allowsNull {
                    Toggle("Set to NULL", isOn: $isNull).frame(minHeight: Sizes.touchTarget)
                }
                if isNull {
                    Text(verbatim: "NULL").font(.codeText).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: $value)
                        .font(.codeText)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 120)
                        .accessibilityLabel(L10n.text("Value"))
                }
                if let message = error ?? edit.validationMessage(value: value, isNull: isNull) {
                    Text(message).font(.captionText).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(.portbaseSecondary)
            Button("Apply") {
                do { try edit.save(value, isNull); dismiss() }
                catch { self.error = DatabaseErrorFormatter.message(for: error) }
            }
            .buttonStyle(.portbasePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(edit.validationMessage(value: value, isNull: isNull) != nil)
        }
        .onAppear {
            if let first = edit.fields.first, edit.fields.allSatisfy({ $0.isNull == first.isNull && $0.value == first.value }) {
                value = first.value
                isNull = first.isNull && edit.allowsNull
            }
        }
        .onChange(of: value) { _, _ in error = nil }
        .onChange(of: isNull) { _, _ in error = nil }
    }
}

struct ResultCellInspector: View {
    let selection: ResultCellSelection
    @Environment(\.dismiss) private var dismiss
    @State private var formatted = true
    @State private var base64 = false
    @State private var file: URL?
    @State private var error: String?
    @State private var draft: DataEditorField?
    @State private var isSaving = false

    private var preview: String {
        switch selection.cell {
        case .null: return "NULL"
        case .json(let text): return formatted ? ResultInspectionService.formattedJSON(text) : text
        case .binary(let bytes):
            let prefix = bytes.prefix(4_096)
            return base64 ? Data(prefix).base64EncodedString() : "0x" + prefix.map { String(format: "%02x", $0) }.joined()
        default: return selection.cell.displayValue
        }
    }

    private var hasChanges: Bool {
        // Compared with the value the editor opened with, which may already be a staged edit.
        guard let draft, let initial = selection.edit?.field else { return false }
        return draft.isNull != initial.isNull || (!draft.isNull && draft.value != initial.value)
    }

    private var validationMessage: String? {
        guard let draft, let edit = selection.edit, hasChanges else { return nil }
        return DataEditorValidationService.validate(fields: [draft], mode: .update, engine: edit.engine).values.first
    }

    var body: some View {
        PortbaseSheet(selection.column.name,
                      subtitle: ResultInspectionService.typeName(selection.cell) + " · " + selection.column.type + " · " + L10n.format("Row %d", selection.row + 1)) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if draft != nil {
                    CellValueEditor(field: Binding(get: { draft! }, set: { draft = $0 }))
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle").font(.captionText).foregroundStyle(.red)
                    }
                } else {
                    readOnlyPreview
                }
                if let error { Text(error).font(.captionText).foregroundStyle(.red) }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
        } footer: {
            Button("Copy", systemImage: "doc.on.doc") {
                let value: String
                if case .binary(let bytes) = selection.cell, base64 { value = bytes.base64EncodedString() }
                else { value = selection.cell.isNull ? "NULL" : selection.cell.displayValue }
                var item: [String: Any] = ["public.utf8-plain-text": value]
                if let data = try? JSONEncoder().encode(selection.cell) { item["ad.neko.portsql.cell"] = data }
                PortbaseClipboard.copy(items: [item])
            }
            .buttonStyle(.portbaseToolbar)
            if let file {
                ShareLink(item: file) { Label("Share Value", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.portbaseToolbar)
            }
            Spacer(minLength: Spacing.s)
            if draft != nil {
                Button(L10n.text(hasChanges ? "Cancel" : "Done")) { dismiss() }
                    .buttonStyle(.portbaseSecondary)
                    .disabled(isSaving)
                Button("Apply") { save() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || validationMessage != nil || isSaving)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(hasChanges || isSaving)
        .onAppear { if draft == nil { draft = selection.edit?.field } }
        .task {
            do { file = try ResultInspectionService.export(selection.cell) }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
    }

    @ViewBuilder private var readOnlyPreview: some View {
        if case .json = selection.cell { Toggle("Format JSON", isOn: $formatted).frame(minHeight: Sizes.touchTarget) }
        if case .binary(let bytes) = selection.cell {
            PortbaseSegmentedPicker(selection: $base64, options: [
                PortbaseChoice(value: false, title: L10n.text("Hex")), PortbaseChoice(value: true, title: L10n.text("Base64")),
            ])
            .accessibilityLabel("Encoding")
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)).font(.captionText)
            if bytes.count > 4_096 { Text("Preview: first 4096 bytes. Share exports the complete value.").font(.captionText).foregroundStyle(.secondary) }
        }
        if selection.cell == .text("") { Text("Empty text").foregroundStyle(.secondary) }
        CellValueTextView(value: preview)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Cell value")
    }

    private func save() {
        guard let draft, let edit = selection.edit else { return }
        isSaving = true
        error = nil
        Task {
            do {
                try await edit.save(draft)
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                self.error = DatabaseErrorFormatter.message(for: error)
            }
        }
    }
}

/// Edits one value with a control that fits its column type. The text stays the source of truth,
/// so pickers and buttons only rewrite the parts they show.
private struct CellValueEditor: View {
    @Binding var field: DataEditorField
    @State private var lastValue = ""

    private var kind: DataEditorValueKind { DataEditorValidationService.valueKind(for: field.column) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if field.column.isNullable {
                Toggle(L10n.text("Set to NULL"), isOn: Binding(
                    get: { field.isNull },
                    set: { isNull in
                        if isNull { lastValue = field.value } else if field.value.isEmpty { field.value = lastValue }
                        field.isNull = isNull
                    }
                ))
                .frame(minHeight: Sizes.touchTarget)
            }
            if field.isNull {
                Text(verbatim: "NULL").font(.codeText).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                editor
            }
        }
    }

    @ViewBuilder private var editor: some View {
        switch kind {
        case .boolean: booleanEditor
        case .integer, .decimal: numberEditor
        case .date, .dateTime, .time: temporalEditor
        case .uuid: uuidEditor
        case .json: jsonEditor
        case .text, .binary: textEditor
        }
    }

    private var booleanEditor: some View {
        let usesDigits = ["0", "1"].contains(field.originalValue ?? "")
        let isTrue = ["1", "true", "yes"].contains(field.value.trimmingCharacters(in: .whitespaces).lowercased())
        return VStack(alignment: .leading, spacing: Spacing.m) {
            PortbaseSegmentedPicker(selection: Binding(
                get: { isTrue },
                set: { field.value = usesDigits ? ($0 ? "1" : "0") : ($0 ? "true" : "false") }
            ), options: [PortbaseChoice(value: true, title: "true"), PortbaseChoice(value: false, title: "false")])
            .accessibilityLabel("Value")
            Spacer(minLength: 0)
        }
    }

    private var numberEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            singleLineField
                .portbaseKeyboardType(DataEditorValidationService.keyboardType(for: field.column))
            if kind == .integer, let number = Int64(field.value.trimmingCharacters(in: .whitespaces)) {
                HStack(spacing: Spacing.s) {
                    Button(L10n.text("Decrease"), systemImage: "minus") { if number > .min { field.value = String(number - 1) } }
                    Button(L10n.text("Increase"), systemImage: "plus") { if number < .max { field.value = String(number + 1) } }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.portbaseSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var temporalEditor: some View {
        let value = TemporalEditValue(field.value, kind: kind)
        let components: DatePickerComponents = value.map { $0.hasDate && $0.hasTime ? [.date, .hourAndMinute] : $0.hasDate ? .date : .hourAndMinute } ?? .date
        return VStack(alignment: .leading, spacing: Spacing.m) {
            singleLineField.portbaseKeyboardType(.numbersAndPunctuation)
            HStack(spacing: Spacing.s) {
                if let value, let date = value.date {
                    DatePicker("Value", selection: Binding(
                        get: { date },
                        set: { var updated = value; updated.apply($0); field.value = updated.text }
                    ), displayedComponents: components)
                    .labelsHidden()
                    .environment(\.timeZone, TemporalEditValue.calendar.timeZone)
                    .environment(\.calendar, TemporalEditValue.calendar)
                }
                Spacer(minLength: 0)
                Button("Now", systemImage: "clock") { setNow() }.buttonStyle(.portbaseSecondary)
            }
            Text(DataEditorValidationService.placeholder(for: field.column)).font(.captionText).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var uuidEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            singleLineField
            Button("Generate UUID", systemImage: "wand.and.stars") { field.value = UUID().uuidString.lowercased() }
                .buttonStyle(.portbaseSecondary)
            Spacer(minLength: 0)
        }
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button("Format", systemImage: "text.alignleft") {
                    if let text = DataEditorValidationService.formattedJSON(field.value) { field.value = text }
                }
                Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
                    if let text = DataEditorValidationService.formattedJSON(field.value, prettyPrinted: false) { field.value = text }
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.portbaseSecondary)
            multiLineField
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if field.value.isEmpty { Text("Empty text").font(.captionText).foregroundStyle(.secondary) }
            multiLineField
        }
    }

    private var singleLineField: some View {
        TextField(DataEditorValidationService.placeholder(for: field.column), text: $field.value)
            .font(.codeText)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .portbaseTextCapitalization(.never)
            .portbaseFieldChrome()
            .accessibilityLabel("Cell value")
    }

    private var multiLineField: some View {
        TextEditor(text: $field.value)
            .font(.codeText)
            .autocorrectionDisabled()
            .portbaseTextCapitalization(.never)
            .scrollContentBackground(.hidden)
            .padding(Spacing.s)
            .background(PortSQLPalette.panel, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Cell value")
    }

    private func setNow() {
        let template: String
        switch kind {
        case .date: template = "2000-01-01"
        case .dateTime(let zoned): template = "2000-01-01 00:00:00" + (zoned ? "+00:00" : "")
        case .time(let zoned): template = "00:00:00" + (zoned ? "+00:00" : "")
        default: return
        }
        guard var value = TemporalEditValue(field.value, kind: kind) ?? TemporalEditValue(template, kind: kind) else { return }
        value.setNow()
        field.value = value.text
    }
}

#if canImport(UIKit)
private struct CellValueTextView: UIViewRepresentable {
    let value: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.font = PortbaseFonts.codeFont(TypeSize.code, textStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .secondarySystemBackground
        view.textContainerInset = UIEdgeInsets(top: Spacing.m, left: Spacing.s, bottom: Spacing.m, right: Spacing.s)
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) { if uiView.text != value { uiView.text = value } }
}

#else
private struct CellValueTextView: View {
    let value: String
    var body: some View { NativeReadOnlyText(value: value) }
}
#endif
