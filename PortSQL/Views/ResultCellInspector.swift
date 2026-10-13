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
}

struct ResultCellInspector: View {
    let selection: ResultCellSelection
    @Environment(\.dismiss) private var dismiss
    @State private var formatted = true
    @State private var base64 = false
    @State private var file: URL?
    @State private var error: String?

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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(ResultInspectionService.typeName(selection.cell) + " · " + selection.column.type).font(.captionText).foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.format("Row %d", selection.row + 1)).font(.captionText).foregroundStyle(.secondary)
                }
                if case .json = selection.cell { Toggle("Format JSON", isOn: $formatted).frame(minHeight: Sizes.touchTarget) }
                if case .binary(let bytes) = selection.cell {
                    Picker("Encoding", selection: $base64) { Text("Hex").tag(false); Text("Base64").tag(true) }.pickerStyle(.segmented)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)).font(.captionText)
                    if bytes.count > 4_096 { Text("Preview: first 4096 bytes. Share exports the complete value.").font(.captionText).foregroundStyle(.secondary) }
                }
                if selection.cell == .text("") { Text("Empty text").foregroundStyle(.secondary) }
                CellValueTextView(value: preview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Cell value")
                if let error { Text(error).font(.captionText).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle(selection.column.name)
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        let value: String
                        if case .binary(let bytes) = selection.cell, base64 { value = bytes.base64EncodedString() }
                        else { value = selection.cell.isNull ? "NULL" : selection.cell.displayValue }
                        var item: [String: Any] = ["public.utf8-plain-text": value]
                        if let data = try? JSONEncoder().encode(selection.cell) { item["ad.neko.portsql.cell"] = data }
                        PortbaseClipboard.copy(items: [item])
                    }
                    if let file { ShareLink(item: file) { Label("Share Value", systemImage: "square.and.arrow.up") } }
                }
            }
            .task {
                do { file = try ResultInspectionService.export(selection.cell) }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
        }
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
