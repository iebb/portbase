import SwiftUI
import UniformTypeIdentifiers

struct SQLiteConnectionSection: View {
    @Binding var profile: ConnectionProfile
    @State private var importing = false
    @State private var creating = false
    @State private var managing = false
    @State private var databaseName = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Section {
            LabeledContent("Database File") {
                if let fileName = profile.sqliteFileName {
                    Text(verbatim: SQLiteFileStore.displayName(fileName: fileName)).lineLimit(2)
                } else { Text("No file selected").foregroundStyle(.secondary) }
            }
            Button("Import SQLite File…", systemImage: "square.and.arrow.down") { importing = true }
                .frame(minHeight: Sizes.touchTarget).disabled(task != nil)
            Button("Create SQLite Database…", systemImage: "plus") { databaseName = ""; creating = true }
                .frame(minHeight: Sizes.touchTarget).disabled(task != nil)
            Button("Manage Local Files…", systemImage: "folder") { managing = true }
                .frame(minHeight: Sizes.touchTarget).disabled(task != nil)
            if task != nil {
                HStack {
                    ProgressView()
                    Spacer()
                    Button("Cancel") { task?.cancel() }.frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnoteText).textSelection(.enabled) }
        } header: { Text("SQLite Database") }
        footer: { Text("Database files stay on this device. Deleting a bookmark keeps its file.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { perform { try await SQLiteFileStore.shared.importDatabase(from: url) } }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .alert("Create SQLite Database", isPresented: $creating) {
            TextField("Database name", text: $databaseName)
                .portbaseTextCapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = databaseName
                perform { try await SQLiteFileStore.shared.create(name: name) }
            }.disabled(databaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .sheet(isPresented: $managing) { SQLiteLocalFilesView(profile: $profile) }
        .onDisappear { task?.cancel() }
    }

    private func perform(_ operation: @escaping @Sendable () async throws -> SQLiteManagedFile) {
        guard task == nil else { return }
        error = nil
        task = Task {
            defer { task = nil }
            do {
                let file = try await operation()
                try Task.checkCancellation()
                profile.sqliteFileName = file.fileName
                profile.defaultDatabase = "main"
                if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { profile.name = file.displayName }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct SQLiteLocalFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: ConnectionProfile
    @State private var files: [SQLiteManagedFile] = []
    @State private var error: String?
    @State private var deleting: SQLiteManagedFile?

    var body: some View {
        PortbaseSheet(L10n.text("Local Database Files")) {
            List {
                if files.isEmpty { Text("No local database files").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    Button {
                        profile.sqliteFileName = file.fileName
                        profile.defaultDatabase = "main"
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(verbatim: file.displayName).foregroundStyle(.primary)
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                    .font(.captionText).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if file.fileName == profile.sqliteFileName { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                        }.frame(minHeight: Sizes.touchTarget)
                    }
                    .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .onAppear(perform: reload)
            .confirmationDialog("Delete Database File?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { file in
                Button("Delete File", role: .destructive) {
                    do {
                        try SQLiteFileStore.shared.remove(fileName: file.fileName)
                        if profile.sqliteFileName == file.fileName { profile.sqliteFileName = nil }
                        reload()
                    } catch { self.error = error.localizedDescription }
                }
            } message: { _ in
                Text("This permanently deletes the local database. Bookmarks that use it will need another file.")
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        do { files = try SQLiteFileStore.shared.files(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
