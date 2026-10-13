import SwiftUI

/// Imports host, port, credentials, database, and TLS requirements from a pasted connection string.
struct ConnectionStringImportSection: View {
    @Binding var profile: ConnectionProfile
    /// Called before an import changes the engine, so the editor skips its engine defaults.
    var willChangeEngine: () -> Void = {}
    @State private var text = ""
    @State private var error: String?
    @State private var notices: [String] = []
    @State private var imported = false
    /// An example URL; it is not translated.
    private static let example = "postgresql://user:password@host:5432/database"

    var body: some View {
        Section {
            SecureField(Self.example, text: $text)
                .portbaseTextCapitalization(.never)
                .autocorrectionDisabled()
                .font(.codeText)
                .onSubmit(importString)
                .accessibilityLabel("Connection string")
            Button {
                importString()
            } label: {
                Label("Import", systemImage: "arrow.down.doc")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.footnoteText)
                    .foregroundStyle(.red)
            } else if imported {
                Label("Connection details imported. Review them below, then save.", systemImage: "checkmark.circle.fill")
                    .font(.footnoteText)
                    .foregroundStyle(.green)
            }
            ForEach(notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.footnoteText)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Connection String")
        } footer: {
            Text("Supports PostgreSQL, MySQL, MariaDB, MongoDB, Redis, ClickHouse, and Elasticsearch URLs, including JDBC prefixes. The password is stored in this device’s Keychain when you save.")
        }
    }

    private func importString() {
        do {
            let result = try ConnectionStringImporter.apply(text, to: profile)
            if result.profile.engine != profile.engine { willChangeEngine() }
            profile = result.profile
            notices = result.notices
            error = nil
            imported = true
            text = ""
        } catch {
            self.error = error.localizedDescription
            notices = []
            imported = false
        }
    }
}
