import SwiftUI

/// The connection's URL, generated from the server details above it and kept in step as they change.
/// Editing or pasting a URL here and choosing Apply fills the details in instead. The password is never
/// shown; one included in a pasted URL is kept for the Keychain when the connection is saved.
struct ConnectionStringImportSection: View {
    @Binding var profile: ConnectionProfile
    /// Called before an import changes the engine, so the editor skips its engine defaults.
    var willChangeEngine: () -> Void = {}
    @State private var text = ""
    @State private var generated = ""
    @State private var error: String?
    @State private var notices: [String] = []
    @State private var applied = false

    private var current: String { ConnectionStringImporter.connectionString(for: profile) ?? "" }
    /// The user typed or pasted something other than the generated string.
    private var isEdited: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != generated }

    var body: some View {
        Section {
            TextField(L10n.text("Connection string"), text: $text, axis: .vertical)
                .lineLimit(1...3)
                .portbaseTextCapitalization(.never)
                .autocorrectionDisabled()
                .portbaseURLField()
                .font(.codeText)
                .onSubmit(applyString)
                .accessibilityLabel("Connection string")
            HStack(spacing: Spacing.s) {
                if isEdited {
                    Button("Apply", systemImage: "arrow.down.doc") { applyString() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Revert", systemImage: "arrow.uturn.backward") { reset() }
                } else {
                    Button("Copy", systemImage: "doc.on.doc") { PortbaseClipboard.copy(generated) }
                        .disabled(generated.isEmpty)
                }
            }
            .buttonStyle(.borderless)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.footnoteText)
                    .foregroundStyle(.red)
            } else if applied {
                Label("Connection details imported. Review them above, then save.", systemImage: "checkmark.circle.fill")
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
            Text("Generated from the server details above, without the password. Paste a PostgreSQL, MySQL, MariaDB, Redis, ClickHouse, or Elasticsearch URL (JDBC prefixes work) and choose Apply to fill them in.")
        }
        .onAppear { reset() }
        // Follow the fields as they change, unless the user is editing the string.
        .onChange(of: current) { _, value in
            if !isEdited { text = value }
            generated = value
        }
    }

    private func reset() {
        generated = current
        text = generated
        error = nil
    }

    private func applyString() {
        do {
            let result = try ConnectionStringImporter.apply(text, to: profile)
            if result.profile.engine != profile.engine { willChangeEngine() }
            profile = result.profile
            notices = result.notices
            error = nil
            applied = true
            // Show the regenerated string, which leaves out any pasted password.
            generated = ConnectionStringImporter.connectionString(for: result.profile) ?? ""
            text = generated
        } catch {
            self.error = error.localizedDescription
            notices = []
            applied = false
        }
    }
}
