import SwiftUI

/// Asks for a name, then creates an empty local SQLite database and connects to it.
private struct NewSQLiteDatabasePrompt: ViewModifier {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Binding var isPresented: Bool
    let onCreated: () -> Void
    @State private var name = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Create SQLite Database", isPresented: $isPresented) {
                TextField("Database name", text: $name)
                    .portbaseTextCapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    let requested = name
                    name = ""
                    Task {
                        do {
                            try await LocalSQLiteDatabase.create(named: requested, bookmarks: bookmarks, workspace: workspace)
                            onCreated()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Database files stay on this device. Deleting a bookmark keeps its file.")
            }
            .alert("Create SQLite Database", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

extension View {
    func newSQLiteDatabasePrompt(isPresented: Binding<Bool>, onCreated: @escaping () -> Void) -> some View {
        modifier(NewSQLiteDatabasePrompt(isPresented: isPresented, onCreated: onCreated))
    }
}
