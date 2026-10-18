import SwiftUI

struct LibraryStorageView: View {
    @EnvironmentObject private var library: WorkspaceLibraryStore
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var deletion: DeletedLibraryItem?
    @State private var closedDeletion: ConsoleDraft?
    @State private var clearing: ClearTarget?

    private enum ClearTarget: Identifiable {
        case history, previews
        var id: Self { self }
    }

    var body: some View {
        Form {
            if let error = library.storageError ?? consoles.storageError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            Section {
                LabeledContent { Text(library.snippets.count.formatted()).monospacedDigit() } label: {
                    Label("Saved Queries", systemImage: "books.vertical")
                }
                LabeledContent { Text(library.visualizations.count.formatted()).monospacedDigit() } label: {
                    Label("Charts", systemImage: "chart.bar.xaxis")
                }
                LabeledContent { Text(library.previewStorageSize).monospacedDigit() } label: {
                    Label("Chart Previews", systemImage: "photo.on.rectangle")
                }
            } header: {
                Text("Storage")
            } footer: {
                HStack(spacing: Spacing.s) {
                    Button("Clear Chart Previews") { clearing = .previews }
                    Button("Clear Query History", role: .destructive) { clearing = .history }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Spacing.xs)
            }

            Section("Recently Closed Consoles") {
                if consoles.closed.isEmpty {
                    emptyRow(L10n.text("Consoles you close stay here for a while, ready to restore."))
                }
                ForEach(consoles.closed) { draft in
                    itemRow(title: draft.title, onRestore: { consoles.add(restoring: draft) }, onDelete: { closedDeletion = draft }) {
                        Text(draft.query).font(.codeCaption).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Trash") {
                if library.trash.isEmpty {
                    emptyRow(L10n.text("Deleted queries and charts stay here until you delete them permanently."))
                }
                ForEach(library.trash) { item in
                    itemRow(title: item.title, onRestore: { library.restore(item) }, onDelete: { deletion = item }) {
                        Text(item.deletedAt, style: .date).font(.captionText).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Library Storage")
        // Clearing can't be undone, unlike deleting a saved query, which goes to the trash.
        .confirmationDialog(clearing == .history ? L10n.text("Clear query history?") : L10n.text("Clear chart previews?"),
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
                            titleVisibility: .visible) {
            Button(clearing == .history ? L10n.text("Clear Query History") : L10n.text("Clear Chart Previews"), role: .destructive) {
                if clearing == .history { library.clearHistory() } else { library.clearPreviews() }
                clearing = nil
            }
            Button("Cancel", role: .cancel) { clearing = nil }
        } message: {
            Text(clearing == .history ? L10n.text("Every query in the history is removed from this device. This can't be undone.")
                                      : L10n.text("Saved chart thumbnails are removed. Charts redraw them the next time they run."))
        }
        .alert("Delete Permanently?", isPresented: Binding(get: { deletion != nil || closedDeletion != nil }, set: { if !$0 { deletion = nil; closedDeletion = nil } })) {
            Button("Delete", role: .destructive) {
                if let deletion { library.permanentlyDelete(deletion) }
                if let closedDeletion { consoles.deleteClosed(closedDeletion.id) }
                deletion = nil; closedDeletion = nil
            }
            Button("Cancel", role: .cancel) { deletion = nil; closedDeletion = nil }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.captionText).foregroundStyle(.secondary)
    }

    /// A closed console or deleted item with Restore and Delete Permanently, as buttons, a context menu,
    /// and, on iPhone and iPad, a swipe.
    private func itemRow<Detail: View>(title: String, onRestore: @escaping () -> Void, onDelete: @escaping () -> Void,
                                       @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title).lineLimit(1)
                detail()
            }
            Spacer(minLength: Spacing.s)
            Button("Restore", action: onRestore).buttonStyle(.borderless)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Delete Permanently"))
            .accessibilityLabel("Delete Permanently")
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
            Button("Delete Permanently", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .swipeActions { Button("Delete", role: .destructive, action: onDelete) }
    }
}
