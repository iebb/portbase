import SwiftUI
import UniformTypeIdentifiers

struct ScriptFilesButton: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var importing = false
    @State private var pendingText: String?
    @State private var confirmsReplacement = false
    @State private var sharedFile: SharedScriptFile?
    @State private var error: String?

    private var script: String {
        if workspace.isDocumentDatabase, workspace.mongoDraft.mode != .command {
            return (try? workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name)) ?? ""
        }
        return workspace.activeBoundQuery?.sql == workspace.queryText ? workspace.activeBoundQuery?.sourceSQL ?? workspace.queryText : workspace.queryText
    }

    var body: some View {
        Menu {
            Button("Open Script", systemImage: "folder") { importing = true }
                .disabled(workspace.isRunning)
            Button("Share Script", systemImage: "square.and.arrow.up") {
                do { sharedFile = SharedScriptFile(url: try ScriptFileService.export(script, engine: workspace.selectedBookmark?.engine)) }
                catch { self.error = error.localizedDescription }
            }
            .disabled(script.isEmpty)
        } label: {
            Label("Script Files", systemImage: "doc.text").labelStyle(.iconOnly).toolIconChrome()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .json, .data]) { result in
            do {
                let text = try ScriptFileService.read(result.get())
                if !script.isEmpty && script != text { pendingText = text; confirmsReplacement = true }
                else { open(text) }
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Replace current query?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
            Button("Replace Query", role: .destructive) { if let pendingText { open(pendingText) }; pendingText = nil }
            Button("Cancel", role: .cancel) { pendingText = nil }
        }
        .sheet(item: $sharedFile) { file in
            ScriptActivitySheet(url: file.url).onDisappear { try? FileManager.default.removeItem(at: file.url) }
        }
        .alert("Script File", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func open(_ text: String) {
        guard !workspace.isRunning else { return }
        workspace.activeBoundQuery = nil
        workspace.queryText = text
        workspace.queryCursorOffset = 0
        workspace.querySelectionLength = 0
        if workspace.isDocumentDatabase { workspace.mongoDraft.mode = .command }
        workspace.refreshAssist()
    }
}

private struct SharedScriptFile: Identifiable { let id = UUID(); let url: URL }

#if canImport(UIKit)
struct ScriptActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
