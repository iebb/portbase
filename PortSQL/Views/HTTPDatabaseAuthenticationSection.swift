import SwiftUI

struct HTTPDatabaseAuthenticationSection: View {
    @Binding var profile: ConnectionProfile

    var body: some View {
        Section("Credentials") {
            Picker("Authentication", selection: $profile.httpAuthentication) {
                ForEach(authenticationMethods) { method in Text(method.title).tag(method) }
            }
            .frame(minHeight: Sizes.touchTarget)
            if profile.httpAuthentication == .basic {
                LabeledTextField("Username", text: $profile.username)
                    .portbaseTextCapitalization(.never).autocorrectionDisabled().frame(minHeight: Sizes.touchTarget)
            }
            LabeledTextField(verbatim: secretTitle, text: Binding(get: { profile.password }, set: {
                profile.password = $0
                profile.passwordWasExplicitlySet = true
            }), isSecure: true)
            .portbaseTextCapitalization(.never).autocorrectionDisabled().frame(minHeight: Sizes.touchTarget)
            .accessibilityLabel(secretTitle)
        }
    }

    private var authenticationMethods: [HTTPDatabaseAuthentication] {
        profile.engine == .elasticsearch ? HTTPDatabaseAuthentication.allCases : [.basic, .bearer]
    }

    private var secretTitle: String {
        switch profile.httpAuthentication {
        case .basic: L10n.text("Password")
        case .apiKey: L10n.text("API Key")
        case .bearer: L10n.text("Access Token")
        }
    }
}
