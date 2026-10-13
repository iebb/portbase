import SwiftUI

struct LibraryStorageView: View {
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var deletion: DeletedLibraryItem?
    @State private var closedDeletion: ConsoleDraft?

    var body: some View {
        List {
            if let error = library.storageError ?? consoles.storageError {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section("Storage") {
                LabeledContent("Saved Queries", value: library.snippets.count.formatted())
                LabeledContent("Charts", value: library.visualizations.count.formatted())
                LabeledContent("Chart Previews", value: library.previewStorageSize)
                Button("Clear Chart Previews") { library.clearPreviews() }
                Button("Clear Query History") { library.clearHistory() }
            }
            Section("Recently Closed Consoles") {
                ForEach(consoles.closed) { draft in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(draft.title)
                            Text(draft.query).font(.codeCaption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { consoles.add(restoring: draft) }.buttonStyle(.borderless)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { closedDeletion = draft } }
                }
            }
            Section("Trash") {
                ForEach(library.trash) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            Text(item.deletedAt, style: .date).font(.captionText).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { library.restore(item) }.buttonStyle(.borderless)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deletion = item } }
                }
            }
        }
        .navigationTitle("Library Storage")
        .alert("Delete Permanently?", isPresented: Binding(get: { deletion != nil || closedDeletion != nil }, set: { if !$0 { deletion = nil; closedDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let deletion { library.permanentlyDelete(deletion) }
                if let closedDeletion { consoles.deleteClosed(closedDeletion.id) }
                deletion = nil; closedDeletion = nil
            }
            Button("Cancel", role: .cancel) { deletion = nil; closedDeletion = nil }
        }
    }
}
