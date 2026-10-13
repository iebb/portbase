import SwiftUI

struct MongoConnectionURISection: View {
    @Binding var profile: ConnectionProfile

    var body: some View {
        Section("MongoDB Connection") {
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
                        .font(.codeCaption).textSelection(.enabled)
                }
                Button("Remove additional hosts", role: .destructive) { profile.mongoConnection.additionalHosts = [] }
            }
        }
    }
}
