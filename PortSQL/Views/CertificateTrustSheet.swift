import SwiftUI

/// A server CA offered for trust on first use, for one connection.
struct CertificateTrustRequest: Identifiable, Equatable {
    let profileID: UUID
    let connectionName: String
    let authority: ServerCertificateAuthority
    /// The connection already trusts a different private CA, so accepting replaces it.
    let replacesExistingAuthority: Bool
    var id: String { profileID.uuidString + authority.id }
}

extension CertificateTrustRequest {
    /// A request to trust `authority` for `profile`, or nil when the profile already trusts it.
    init?(profile: ConnectionProfile, authority: ServerCertificateAuthority) {
        let saved = profile.transportSecurityMode == .privateCA && profile.privateCACertificate != "<keychain>"
            ? ServerCertificateProbe.fingerprints(ofPEM: profile.privateCACertificate) : []
        guard !saved.contains(authority.sha256Fingerprint) else { return nil }
        self.init(profileID: profile.id, connectionName: profile.displayTitle, authority: authority,
                  replacesExistingAuthority: !saved.isEmpty)
    }
}

extension WorkspaceViewModel {
    /// Whether a connection failure can be resolved by trusting the CA the server presents: an
    /// untrusted certificate, or a private-CA connection whose CA isn't on this device (it stays in
    /// the Keychain and doesn't sync).
    static func offersCertificateTrust(for message: String, profile: ConnectionProfile) -> Bool {
        guard ServerCertificateProbe.preamble(for: profile.engine) != nil, profile.usesTLS else { return false }
        return ConnectionIssue.classify(message).kind == .certificateUntrusted
            || message == DatabaseServiceError.privateCACertificateMissing.localizedDescription
    }

    /// Offers the server's CA once after a certificate failure on the selected connection.
    func offerCertificateTrustIfNeeded(for message: String?) {
        guard let message, certificateProbeTask == nil, certificateTrustRequest == nil,
              let profile = selectedBookmark, Self.offersCertificateTrust(for: message, profile: profile) else { return }
        reviewServerCertificate(automatic: true)
    }

    /// Fetches the CA behind the selected connection's certificate and asks whether to trust it.
    /// Automatic reviews stay quiet when there's nothing to offer; the issue banner explains the failure.
    func reviewServerCertificate(automatic: Bool = false) {
        guard let profile = selectedBookmark else { return }
        certificateProbeTask?.cancel()
        certificateReviewError = nil
        certificateProbeTask = Task { [weak self] in
            do {
                let authority = try await ServerCertificateProbe.authority(for: profile)
                guard let self, !Task.isCancelled else { return }
                self.certificateProbeTask = nil
                if automatic, self.declinedCertificateAuthorities.contains(Self.declineKey(profile.id, authority)) { return }
                guard let request = CertificateTrustRequest(profile: profile, authority: authority) else {
                    // The connection already trusts this CA, so trusting it again can't help.
                    if !automatic { self.certificateReviewError = L10n.text("This connection already trusts the server’s certificate authority, so the connection failed for another reason. Check the connection details.") }
                    return
                }
                self.certificateTrustRequest = request
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.certificateProbeTask = nil
                if !automatic { self.certificateReviewError = DatabaseErrorFormatter.message(for: error) }
            }
        }
    }

    /// Saves the confirmed CA in the Keychain as the connection's private CA, switches the connection to
    /// TLS Required (Private CA), and reconnects. Chain and hostname verification stay on.
    func trustCertificateAuthority(_ request: CertificateTrustRequest) {
        certificateTrustRequest = nil
        guard let store = bookmarkStore, var profile = store.bookmark(with: request.profileID) else { return }
        guard TransportSecurityEditorState.isValidPrivateCACertificate(request.authority.pem) else {
            certificateReviewError = DatabaseServiceError.privateCACertificateInvalid.localizedDescription
            return
        }
        profile.privateCACertificate = request.authority.pem
        profile.transportSecurityMode = .privateCA
        guard store.upsert(profile) else {
            certificateReviewError = store.errorMessage
            return
        }
        if selectedBookmarkID == request.profileID { reconnect() }
    }

    func declineCertificateAuthority(_ request: CertificateTrustRequest) {
        declinedCertificateAuthorities.insert(Self.declineKey(request.profileID, request.authority))
        certificateTrustRequest = nil
    }

    private static func declineKey(_ profileID: UUID, _ authority: ServerCertificateAuthority) -> String {
        profileID.uuidString + "/" + authority.sha256Fingerprint
    }
}

/// Shows a server's CA so the user can decide whether to trust it for one connection.
struct CertificateTrustSheet: View {
    let request: CertificateTrustRequest
    let onTrust: () -> Void
    let onCancel: () -> Void

    private var authority: ServerCertificateAuthority { request.authority }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: request.replacesExistingAuthority ? "exclamationmark.shield.fill" : "lock.shield.fill")
                        .font(.tileSymbol)
                        .foregroundStyle(request.replacesExistingAuthority ? Color.orange : PortSQLPalette.accent)
                        .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                        .background((request.replacesExistingAuthority ? Color.orange : PortSQLPalette.accent).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(request.replacesExistingAuthority ? L10n.text("The server’s certificate authority changed")
                                                               : L10n.text("Trust this server’s certificate authority?"))
                            .font(.sectionTitle)
                            .foregroundStyle(PortSQLPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(request.connectionName).font(.rowDetail).foregroundStyle(.secondary)
                    }
                }

                Text("The server presented a certificate from an authority this device doesn’t trust. Managed databases such as DigitalOcean, Amazon RDS, and Azure sign certificates with their own CA. Trust it only if you expected to connect to this server.")
                    .font(.rowDetail)
                    .foregroundStyle(PortSQLPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    row(L10n.text("Authority"), authority.commonName)
                    PortbaseRowDivider()
                    row(L10n.text("Server"), authority.hostname)
                    PortbaseRowDivider()
                    row(L10n.text("Expires"), authority.notValidAfter.formatted(date: .abbreviated, time: .omitted))
                    PortbaseRowDivider()
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("SHA-256 fingerprint").font(.captionText).foregroundStyle(.secondary)
                        Text(authority.sha256Fingerprint)
                            .font(.codeCaption)
                            .foregroundStyle(PortSQLPalette.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.card)
                    .padding(.vertical, Spacing.s)
                    .accessibilityElement(children: .combine)
                }
                .portbaseCardSurface(radius: Radius.control)

                if !authority.coversHostname {
                    StatusBanner(title: L10n.text("Certificate doesn’t match the host"),
                                 message: L10n.format("The server’s certificate doesn’t list %@, so trusting this authority won’t fix the connection. Connect with a hostname the certificate names.", authority.hostname),
                                 tint: .red)
                } else if request.replacesExistingAuthority {
                    StatusBanner(title: L10n.text("Different authority"),
                                 message: L10n.text("This connection already trusts another certificate authority. Replace it only if your provider rotated its CA."),
                                 tint: .orange)
                }

                Text("Portbase saves the authority in this device’s Keychain and switches this connection to TLS Required (Private CA). Certificates and hostnames are still verified on every connection, and a different authority will be refused.")
                    .font(.captionText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.s) {
                    Spacer(minLength: 0)
                    Button(role: .cancel, action: onCancel) {
                        Text("Cancel").frame(minHeight: Sizes.buttonContent)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    Button(action: onTrust) {
                        Text(request.replacesExistingAuthority ? L10n.text("Replace and Connect") : L10n.text("Trust and Connect"))
                            .frame(minHeight: Sizes.buttonContent)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!authority.coversHostname)
                }
            }
            .padding(Spacing.xl)
        }
        .frame(minWidth: 360, idealWidth: 500, maxWidth: 560)
        .background(PortSQLPalette.surface)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.s)
            Text(value).foregroundStyle(PortSQLPalette.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.rowDetail)
        .padding(.horizontal, Spacing.card)
        .frame(minHeight: Sizes.statusBar + Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Presents the trust-on-first-use prompt and review errors for a workspace.
    func certificateTrustPrompt(_ workspace: WorkspaceViewModel) -> some View {
        modifier(CertificateTrustPromptModifier(workspace: workspace))
    }
}

private struct CertificateTrustPromptModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $workspace.certificateTrustRequest) { request in
                CertificateTrustSheet(request: request,
                                      onTrust: { workspace.trustCertificateAuthority(request) },
                                      onCancel: { workspace.declineCertificateAuthority(request) })
#if os(iOS)
                    .presentationDetents([.medium, .large])
#endif
                    .interactiveDismissDisabled()
            }
            .alert(L10n.text("Couldn’t review the certificate"),
                   isPresented: Binding(get: { workspace.certificateReviewError != nil }, set: { if !$0 { workspace.certificateReviewError = nil } })) {
                Button("OK", role: .cancel) { workspace.certificateReviewError = nil }
            } message: {
                Text(workspace.certificateReviewError ?? "")
            }
    }
}
