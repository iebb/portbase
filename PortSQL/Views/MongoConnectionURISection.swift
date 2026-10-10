import SwiftUI

struct MongoConnectionURISection: View {
    @Binding var profile: ConnectionProfile
    @State private var uri = ""
    @State private var error: String?
    @State private var requestedRetries = false

    var body: some View {
        Section("MongoDB Connection") {
            SecureField("Connection URI", text: $uri)
                .portbaseTextCapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            Button("Apply URI") {
                do {
                    let parsed = try MongoConnectionURI.parse(uri)
                    profile = parsed.applying(to: profile)
                    requestedRetries = parsed.requestedWriteRetries
                    uri = ""
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
            .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundStyle(.red) }
            Toggle("Use DNS SRV discovery", isOn: $profile.mongoConnection.usesSRV)
                .onChange(of: profile.mongoConnection.usesSRV) { _, usesSRV in
                    if usesSRV {
                        profile.mongoConnection.directConnection = false
                        profile.mongoConnection.additionalHosts = []
                        profile.port = 27017
                        if profile.transportSecurityMode == .plaintext { profile.transportSecurityMode = .systemCA }
                    }
                }
            Toggle("Direct connection", isOn: $profile.mongoConnection.directConnection)
                .disabled(profile.mongoConnection.usesSRV || !profile.mongoConnection.additionalHosts.isEmpty)
            TextField("Replica set", text: $profile.mongoConnection.replicaSet)
                .portbaseTextCapitalization(.never).autocorrectionDisabled()
            if !profile.mongoConnection.additionalHosts.isEmpty {
                LabeledContent("Additional seed hosts") {
                    Text(verbatim: profile.mongoConnection.additionalHosts.map(\.displayName).joined(separator: ", "))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Remove additional hosts", role: .destructive) { profile.mongoConnection.additionalHosts = [] }
            }
            if requestedRetries {
                Text("Writes are sent once. Check the result before retrying an interrupted write.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
