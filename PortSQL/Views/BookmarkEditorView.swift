import Charts
import Security
import SwiftUI
import UniformTypeIdentifiers

struct BookmarksView: View {
    var onOpenConsole: (() -> Void)?
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var pendingDeletion: ConnectionProfile?
    @State private var createsSQLite = false

    var body: some View {
        ConnectionsHubView(onOpenConsole: onOpenConsole, onCreateSQLite: { createsSQLite = true }, onDelete: { pendingDeletion = $0 })
            .navigationTitle("Servers")
            .newSQLiteDatabasePrompt(isPresented: $createsSQLite) { onOpenConsole?() }
            .alert("Delete Server?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                Button("Delete", role: .destructive) {
                    if let profile = pendingDeletion, let index = bookmarks.bookmarks.firstIndex(where: { $0.id == profile.id }) {
                        bookmarks.delete(at: IndexSet(integer: index))
                        PinnedTableStore.shared.removeAll(for: profile.id)
                        ClauseHistoryStore.shared.removeAll(for: profile.id)
                    }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("Deleting a server also removes its saved credentials from this device.")
            }
    }
}

enum TransportSecurityEditorState {
    static let maximumCertificateSize = 1_048_576

    static func canSave(
        host: String,
        mode: TransportSecurityMode,
        privateCACertificate: String
    ) -> Bool {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return mode != .privateCA || isValidPrivateCACertificate(privateCACertificate)
    }

    static func isValidPrivateCACertificate(_ pem: String) -> Bool {
        let normalized = pem
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= maximumCertificateSize else { return false }

        let uppercase = normalized.uppercased()
        guard !uppercase.contains("PRIVATE KEY"),
              let certificates = certificateData(in: normalized),
              !certificates.isEmpty else {
            return false
        }

        return certificates.allSatisfy { certificate in
            SecCertificateCreateWithData(nil, certificate as CFData) != nil
        }
    }

    static func pemEncodedCertificate(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumCertificateSize else { return nil }

        if let text = String(data: data, encoding: .utf8) {
            let normalized = text
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidPrivateCACertificate(normalized) {
                return normalized + "\n"
            }
        }

        guard SecCertificateCreateWithData(nil, data as CFData) != nil else { return nil }
        let encoded = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----"
        return isValidPrivateCACertificate(pem) ? pem + "\n" : nil
    }

    private static func certificateData(in pem: String) -> [Data]? {
        let beginMarker = "-----BEGIN CERTIFICATE-----"
        let endMarker = "-----END CERTIFICATE-----"
        let sections = pem.components(separatedBy: beginMarker)
        guard sections.count > 1,
              sections.count - 1 == pem.components(separatedBy: endMarker).count - 1 else {
            return nil
        }

        var certificates: [Data] = []
        for section in sections.dropFirst() {
            guard let end = section.range(of: endMarker) else { return nil }
            let encoded = section[..<end.lowerBound].filter { !$0.isWhitespace }
            guard let certificate = Data(base64Encoded: String(encoded)), !certificate.isEmpty else {
                return nil
            }
            certificates.append(certificate)
        }
        return certificates
    }
}

private extension TransportSecurityMode {
    var localizedTitle: String {
        switch self {
        case .systemCA:
            L10n.text("TLS Required (Ask to Trust New CAs)")
        case .privateCA:
            L10n.text("TLS Required (Private CA)")
        case .preferTLS:
            L10n.text("Prefer TLS")
        case .plaintext:
            L10n.text("Plaintext Only")
        }
    }
}

struct BookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var bookmarks: BookmarkStore
    @State var profile: ConnectionProfile
    @State private var isShowingIconPicker = false
    @State private var isImportingPrivateCA = false
    @State private var privateCAImportError: String?
    @State private var saveError: String?
    /// Set when a connection string import changes the engine, so its imported port is kept.
    @State private var keepsImportedEndpoint = false
    @State private var testTask: Task<Void, Never>?
    @State private var testResult: Result<ConnectionTester.Success, Error>?
    @State private var certificateTrustRequest: CertificateTrustRequest?
    @State private var certificateReviewError: String?
    /// Fingerprints already declined in this editor, so a repeated test doesn't ask again.
    @State private var declinedFingerprints: Set<String> = []

    private static let certificateContentTypes: [UTType] = {
        let filenameTypes = ["pem", "crt", "cer"].compactMap { UTType(filenameExtension: $0) }
        return Array(Set([UTType.x509Certificate, .plainText] + filenameTypes))
    }()

    private var canSave: Bool {
        if profile.engine.isLocal { return profile.sqliteFileName != nil }
        if profile.engine == .redis, !profile.trimmedDefaultDatabase.isEmpty,
           Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true { return false }
        return (1...65_535).contains(profile.port) && MongoConnectionURI.isValidProfile(profile) && TransportSecurityEditorState.canSave(
            host: profile.host,
            mode: profile.transportSecurityMode,
            privateCACertificate: profile.privateCACertificate
        )
    }

    var body: some View {
        PortbaseSheet(L10n.text("Connection"), subtitle: profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : profile.name) {
            Form {
                SecretConflictSection(profile: $profile)

                Section("Engine") {
                    EngineChooser(selection: $profile.engine)
                    .onChange(of: profile.engine) { oldValue, engine in
                        if keepsImportedEndpoint { keepsImportedEndpoint = false; return }
                        profile.port = engine == .clickhouse && profile.transportSecurityMode == .plaintext ? 8123 : engine.defaultPort
                        if engine == .clickhouse, profile.httpAuthentication == .apiKey { profile.httpAuthentication = .basic }
                        if engine == .redis, Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true { profile.defaultDatabase = "0" }
                        if profile.iconName == BookmarkIconCatalog.defaultName(for: oldValue) {
                            profile.iconName = nil
                        }
                    }
                }

                // First after the engine, so a pasted string fills in everything below it; SQLite is a file.
                if !profile.engine.isLocal {
                    ConnectionStringImportSection(profile: $profile, willChangeEngine: { keepsImportedEndpoint = true })
                }

                if profile.engine == .mongodb { MongoConnectionURISection(profile: $profile) }

                Section("Server") {
                    LabeledTextField("Name", text: $profile.name)
                    if !bookmarks.folders.isEmpty {
                        Picker("Folder", selection: $profile.folderID) {
                            Text("No Folder").tag(Optional<UUID>.none)
                            ForEach(bookmarks.folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                        }
                    }
                    if !profile.engine.isLocal {
                    LabeledTextField("Host", text: $profile.host, prompt: "db.example.com")
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledTextField("Port", text: Binding(
                        get: { String(profile.port) },
                        set: { input in
                            let digits = input.filter(\.isNumber)
                            profile.port = Int(digits) ?? 0
                        }
                    ))
                        .portbaseKeyboardType(.numberPad)
                    LabeledTextField(verbatim: profile.engine == .redis ? L10n.text("Database number") : L10n.text("Default Database"), text: $profile.defaultDatabase)
                        .portbaseKeyboardType(profile.engine == .redis ? .numberPad : .default)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                    if profile.engine == .redis {
                        // With a master name, the host and port above are a Sentinel's, which names the current primary.
                        LabeledTextField("Sentinel master", text: $profile.redisSentinelMaster, prompt: "Optional")
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if profile.engine == .mongodb {
                        LabeledTextField("Authentication database", text: $profile.authenticationDatabase)
                            .onChange(of: profile.authenticationDatabase) { _, _ in profile.mongoConnection.authenticationSourceIsExplicit = true }
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    }
                    Toggle("Read-only mode", isOn: $profile.isReadOnly)
                }

                Section {
                    EnvironmentPicker(selection: $profile.environment)
                } header: {
                    Text("Environment")
                }

                Section {
#if !os(macOS)
                    Button {
                        isShowingIconPicker = true
                    } label: {
                        HStack(spacing: Spacing.s) {
                            Text("Icon").foregroundStyle(PortSQLPalette.ink)
                            Spacer()
                            Text(profile.avatarDescription)
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                            BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
                            Image(systemName: "chevron.right")
                                .font(.captionStrong)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
#endif
                    ConnectionColorPicker(selection: $profile.colorTag)
                } header: {
                    Text("Appearance")
                }

                if profile.engine.isLocal { SQLiteConnectionSection(profile: $profile) }
                if !profile.engine.isLocal {
                Section("Transport Security") {
                    Picker("Security Mode", selection: $profile.transportSecurityMode) {
                        ForEach(TransportSecurityMode.allCases) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.portbaseNavigation)
                    .onChange(of: profile.transportSecurityMode) { previous, next in
                        privateCAImportError = nil
                        if profile.engine == .clickhouse, profile.port == (previous == .plaintext ? 8123 : 8443) {
                            profile.port = next == .plaintext ? 8123 : 8443
                        }
                    }

                    transportSecurityDetails
                    if !profile.engine.canNegotiateTLS && profile.transportSecurityMode == .preferTLS {
                        Text("This engine requires TLS in Prefer TLS mode because its protocol cannot safely negotiate a plaintext fallback.")
                            .font(.captionText).foregroundStyle(.secondary)
                    }
                }

                Section("SSH Tunnel") {
                    Toggle("Connect through SSH", isOn: $profile.usesSSHTunnel)

                    if profile.usesSSHTunnel {
                        LabeledTextField("SSH Host", text: $profile.sshHost, prompt: "bastion.example.com")
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        LabeledTextField("SSH Port", text: Binding(
                            get: { String(profile.sshPort) },
                            set: { input in
                                let digits = input.filter(\.isNumber)
                                profile.sshPort = Int(digits) ?? 22
                            }
                        ))
                        .portbaseKeyboardType(.numberPad)
                        LabeledTextField("SSH Username", text: $profile.sshUsername)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        LabeledTextField("SSH Password", text: $profile.sshPassword, isSecure: true)
                        LabeledTextArea(title: "Private Key", text: $profile.sshPrivateKey)
                            .font(.codeCaption)
                            .portbaseTextCapitalization(.never)
                            .autocorrectionDisabled()
                        // Only an encrypted key needs one, and only then is it shown.
                        if profile.sshPrivateKey.contains("BEGIN OPENSSH PRIVATE KEY"),
                           SSHTunnelPrivateKeyParser.isEncrypted(profile.sshPrivateKey) || !profile.sshPassphrase.isEmpty {
                            LabeledTextField("Key Passphrase", text: $profile.sshPassphrase, isSecure: true)
                        }
                        SSHHostKeyTrustRows(host: profile.sshHost, port: profile.sshPort)
                        Text(ConnectionSecretLocation.sshNote)
                            .font(.captionText)
                            .foregroundStyle(.secondary)
                    }
                }

                }
                Section("Caching") {
                    Toggle("Cache table lists", isOn: $profile.schemaCachingEnabled)

                    if profile.schemaCachingEnabled {
                        Stepper(
                            "Duration: \(profile.schemaCacheDurationLabel)",
                            value: $profile.schemaCacheDurationHours,
                            in: 1...168,
                            step: 1
                        )
                    }
                }

                if profile.engine == .clickhouse || profile.engine == .elasticsearch {
                    HTTPDatabaseAuthenticationSection(profile: $profile)
                } else if !profile.engine.isLocal {
                Section("Credentials") {
                    LabeledTextField("Username", text: $profile.username)
                        .portbaseTextCapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledTextField("Password", text: $profile.password, isSecure: true)
#if !os(macOS)
                    Text(ConnectionSecretLocation.passwordNote)
                        .font(.captionText)
                        .foregroundStyle(.secondary)
#endif
                }

                }
                Section {
                    Button {
                        runConnectionTest()
                    } label: {
                        HStack(spacing: Spacing.s) {
                            if testTask != nil { ProgressView().controlSize(.small) }
                            else { Image(systemName: "bolt.horizontal.circle") }
                            Text(testTask != nil ? L10n.text("Testing…") : L10n.text("Test Connection"))
                        }
                        .frame(minHeight: Sizes.control)
                    }
                    .disabled(!canSave || testTask != nil)
                    switch testResult {
                    case .success(let success):
                        Label(ConnectionTester.summary(success), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        let message = DatabaseErrorFormatter.message(for: error)
                        ConnectionIssueBanner(message: message,
                                              onReviewCertificate: WorkspaceViewModel.offersCertificateTrust(for: message, profile: profile)
                                                ? { reviewServerCertificate(automatic: false) } : nil)
                            .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.s, bottom: Spacing.s, trailing: Spacing.s))
                        if let certificateReviewError {
                            Label(certificateReviewError, systemImage: "info.circle")
                                .font(.captionText)
                                .foregroundStyle(.secondary)
                        }
                    case nil:
                        EmptyView()
                    }
                }
                .onChange(of: profile) { _, _ in testResult = nil }

                if let saveError { Section { Text(saveError).foregroundStyle(.red).textSelection(.enabled) } }
                Section("Notes") {
                    TextField("Notes", text: $profile.notes, axis: .vertical)
                }
            }
            .portbaseForm()
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button("Save") {
                if workspace.saveBookmark(profile) { dismiss() }
                else { saveError = workspace.errorMessage }
            }
            .buttonStyle(.portbasePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .portbaseSheetNavigation()
        .sheet(isPresented: $isShowingIconPicker) {
            BookmarkIconPicker(profile: $profile)
        }
        .sheet(item: $certificateTrustRequest) { request in
            CertificateTrustSheet(request: request, onTrust: {
                // The CA joins the unsaved form; saving stores it in the Keychain.
                profile.privateCACertificate = request.authority.pem
                profile.transportSecurityMode = .privateCA
                certificateTrustRequest = nil
                runConnectionTest()
            }, onCancel: {
                declinedFingerprints.insert(request.authority.sha256Fingerprint)
                certificateTrustRequest = nil
            })
#if os(iOS)
            .presentationDetents([.medium, .large])
#endif
            .interactiveDismissDisabled()
        }
        .onDisappear { testTask?.cancel() }
        .fileImporter(
            isPresented: $isImportingPrivateCA,
            allowedContentTypes: Self.certificateContentTypes,
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
                defer {
                    if accessedSecurityScopedResource {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let pem = TransportSecurityEditorState.pemEncodedCertificate(from: data) else {
                    privateCAImportError = L10n.text("The selected file does not contain a valid X.509 certificate.")
                    return
                }
                profile.privateCACertificate = pem
                privateCAImportError = nil
            } catch {
                privateCAImportError = L10n.text("Portbase could not read this certificate file.")
            }
        }
    }

    private func runConnectionTest() {
        testTask?.cancel()
        testResult = nil
        let candidate = profile
        testTask = Task {
            do {
                let success = try await ConnectionTester.test(candidate)
                if !Task.isCancelled { testResult = .success(success) }
            } catch {
                if !Task.isCancelled {
                    testResult = .failure(error)
                    // A first connection to a server with its own CA asks to trust it.
                    if WorkspaceViewModel.offersCertificateTrust(for: DatabaseErrorFormatter.message(for: error), profile: candidate) {
                        reviewServerCertificate(automatic: true)
                    }
                }
            }
            testTask = nil
        }
    }

    private func reviewServerCertificate(automatic: Bool) {
        certificateReviewError = nil
        let candidate = profile
        Task {
            do {
                let authority = try await ServerCertificateProbe.authority(for: candidate)
                if automatic, declinedFingerprints.contains(authority.sha256Fingerprint) { return }
                guard let request = CertificateTrustRequest(profile: candidate, authority: authority) else {
                    if !automatic { certificateReviewError = L10n.text("This connection already trusts the server’s certificate authority, so the connection failed for another reason. Check the connection details.") }
                    return
                }
                certificateTrustRequest = request
            } catch {
                certificateReviewError = DatabaseErrorFormatter.message(for: error)
            }
        }
    }

    @ViewBuilder
    private var transportSecurityDetails: some View {
        switch profile.transportSecurityMode {
        case .systemCA:
#if !os(macOS)
            Label("Recommended secure default", systemImage: "checkmark.shield.fill")
                .font(.rowTitle)
                .foregroundStyle(.green)
#endif
            Text("Encrypts the connection and verifies the server certificate using trusted system certificate authorities.")
                .font(.captionText)
                .foregroundStyle(.secondary)
            Text("When a server uses its own certificate authority, as managed databases often do, Portbase shows it on the first connection and asks before trusting it for this connection.")
                .font(.captionText)
                .foregroundStyle(.secondary)

        case .privateCA:
            Text("TLS remains required. The server certificate must chain to this private CA, and the hostname is still verified.")
                .font(.captionText)
                .foregroundStyle(.secondary)

            TextField(
                "Paste PEM certificate",
                text: $profile.privateCACertificate,
                axis: .vertical
            )
            .lineLimit(6...12)
            .font(.codeCaption)
            .portbaseTextCapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Private CA Certificate")
            .onChange(of: profile.privateCACertificate) { _, _ in
                privateCAImportError = nil
            }

            Button {
                isImportingPrivateCA = true
            } label: {
                Label(
                    profile.privateCACertificate.isEmpty
                        ? L10n.text("Import Certificate")
                        : L10n.text("Replace Certificate"),
                    systemImage: "doc.badge.plus"
                )
            }

            if !profile.privateCACertificate.isEmpty {
                Button(role: .destructive) {
                    profile.privateCACertificate = ""
                    privateCAImportError = nil
                } label: {
                    Label("Clear Certificate", systemImage: "trash")
                }
            }

            if let privateCAImportError {
                StatusBanner(
                    title: L10n.text("Certificate Import Failed"),
                    message: privateCAImportError,
                    tint: .red
                )
            } else if TransportSecurityEditorState.isValidPrivateCACertificate(profile.privateCACertificate) {
                Label("Certificate ready", systemImage: "checkmark.shield.fill")
                    .font(.captionStrong)
                    .foregroundStyle(.green)
            } else if profile.privateCACertificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                StatusBanner(
                    title: L10n.text("Certificate Required"),
                    message: L10n.text("Paste a PEM certificate or import a .pem, .crt, or .cer file. Save remains unavailable until the certificate is valid."),
                    tint: .orange
                )
            } else {
                StatusBanner(
                    title: L10n.text("Invalid Certificate"),
                    message: L10n.text("The private CA must contain valid PEM certificate blocks and must not include a private key."),
                    tint: .red
                )
            }

            Label(ConnectionSecretLocation.certificateNote, systemImage: "iphone.and.arrow.forward")
            .font(.captionText)
            .foregroundStyle(.secondary)

        case .preferTLS:
            StatusBanner(
                title: L10n.text("Security Warning"),
                message: L10n.text("Prefer TLS can fall back to plaintext only when the server does not support TLS. Certificate errors never trigger a downgrade."),
                tint: .orange
            )

        case .plaintext:
            StatusBanner(
                title: L10n.text("Unencrypted Connection"),
                message: L10n.text("Plaintext sends database credentials and data without encryption. Use it only for legacy servers on a trusted network."),
                tint: .red
            )
        }
    }
}

/// Engine tiles with brand colors, replacing a plain menu picker.
private struct EngineChooser: View {
    @Binding var selection: DatabaseEngine

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Spacing.s)], spacing: Spacing.s) {
            ForEach(DatabaseEngine.allCases) { engine in
                let selected = selection == engine
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = engine } } label: {
                    VStack(spacing: Spacing.xs) {
                        EngineBadge(engine: engine, size: Sizes.avatarLarge, cornerRadius: Radius.control)
                        Text(engine.rawValue)
                            .font(.microText.weight(selected ? .bold : .medium))
                            .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background(selected ? PortSQLPalette.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(selected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(engine.rawValue)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

private struct BookmarkIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: ConnectionProfile
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 68, maximum: 92), spacing: Spacing.m)
    ]

    var body: some View {
        PortbaseSheet(L10n.text("Choose Icon")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    PortbaseSearchField(prompt: L10n.text("server, chart, folder"), text: $searchText)

                    LazyVGrid(columns: columns, spacing: Spacing.l) {
                        if searchText.isEmpty {
                            choice(L10n.text("Engine"), selected: profile.avatarStyle == .engine) {
                                profile.iconName = nil
                                profile.showsInitials = false
                            } content: { selected in
                                EngineGlyph(engine: profile.engine)
                                    .fill(selected ? Color.white : PortSQLPalette.ink)
                                    .frame(width: 34, height: 34)
                            }
                            choice(L10n.text("Initials"), selected: profile.avatarStyle == .initials) {
                                profile.iconName = nil
                                profile.showsInitials = true
                            } content: { selected in
                                Text(profile.initials)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(selected ? .white : PortSQLPalette.ink)
                            }
                        }
                        ForEach(filteredIcons, id: \.self) { iconName in
                            Button {
                                profile.iconName = iconName
                                profile.showsInitials = false
                            } label: {
                                VStack(spacing: Spacing.s) {
                                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                        .fill(
                                            iconName == profile.resolvedIconName
                                                ? AnyShapeStyle(selectedFill)
                                                : AnyShapeStyle(PortSQLPalette.surface)
                                        )
                                        .frame(height: 68)
                                        .overlay {
                                            Image(systemName: iconName)
                                                .font(.pageTitle)
                                                .foregroundStyle(iconName == profile.resolvedIconName ? .white : PortSQLPalette.ink)
                                        }
                                        .overlay {
                                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                                .stroke(iconName == profile.resolvedIconName ? Color.clear : PortSQLPalette.stroke, lineWidth: 1)
                                        }

                                    Text(iconName)
                                        .font(.microText)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2, reservesSpace: true)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var selectedFill: LinearGradient {
        LinearGradient(colors: profile.colorTag?.colors ?? profile.engine.brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A tile in the grid for the engine's mark or initials, styled like the symbol tiles.
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void,
                        @ViewBuilder content: (Bool) -> some View) -> some View {
        Button(action: action) {
            VStack(spacing: Spacing.s) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(selected ? AnyShapeStyle(selectedFill) : AnyShapeStyle(PortSQLPalette.surface))
                    .frame(height: 68)
                    .overlay { content(selected) }
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .stroke(selected ? Color.clear : PortSQLPalette.stroke, lineWidth: 1)
                    }
                Text(title)
                    .font(.microText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var filteredIcons: [String] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return BookmarkIconCatalog.names }
        return BookmarkIconCatalog.names.filter { $0.lowercased().contains(needle) }
    }
}
