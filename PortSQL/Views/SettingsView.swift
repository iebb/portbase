import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore

    var body: some View {
        Form {
            Section {
                AboutHeader()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: 0, bottom: Spacing.s, trailing: 0))
            }

            AppearanceSettingsSection()
            EditorThemeSettingsSection()
            ResultHeaderStyleSettingsSection()

            Section {
                CloudStatusRow()
                ConnectionSecretSyncToggle()
                SSHHostKeySyncToggle()
                Button {
                    bookmarks.synchronizeCloud()
                    library.synchronizeCloud()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                if let error = bookmarks.cloudSyncError ?? library.cloudSyncError {
                    Text(error).font(.footnoteText).foregroundStyle(.red)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Connections, saved queries, and chart configurations sync with iCloud. Query history, results, and SQLite files stay on this device.")
            }

            Section("Assistant") {
                NavigationLink {
                    AssistantSettingsView()
                } label: {
                    Label("AI Assistant", systemImage: "sparkles")
                }
            }

            Section("Library") {
                NavigationLink {
                    LibraryStorageView()
                } label: {
                    LabeledContent {
                        Text(L10n.format("Saved: %d", library.snippets.count))
                    } label: {
                        Label("Library Storage", systemImage: "archivebox")
                    }
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.s)], alignment: .leading, spacing: Spacing.s) {
                    ForEach(DatabaseEngine.allCases) { engine in
                        HStack(spacing: Spacing.s) {
                            EngineBadge(engine: engine, size: Sizes.iconTileSmall, cornerRadius: Radius.s)
                            Text(engine.rawValue).font(.rowDetail).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, Spacing.xxs)
            } header: {
                Text("Supported Engines")
            } footer: {
                Text("Database passwords, SSH keys, and private CA certificates stay in this device’s Keychain.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

struct AboutHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.m) {
                PortbaseLogoMark(size: 56)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(verbatim: "Portbase").font(.pageTitle)
                    Text(versionLabel).font(.rowDetail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Link(destination: URL(string: "https://github.com/iebb/portbase")!) {
                HStack(spacing: Spacing.s) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer(minLength: Spacing.s)
                    Text(verbatim: "GitHub").foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.right")
                }
                .font(.rowDetail)
                .frame(minHeight: Sizes.touchTarget)
                .contentShape(Rectangle())
            }
            .accessibilityHint("View Portbase on GitHub")
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return L10n.format("Version %@ (%@)", version, build)
    }
}

struct AppearanceSettingsSection: View {
    @AppStorage(PortbaseAccent.storageKey) private var accent = PortbaseAccent.jade.rawValue
    @AppStorage(PortbaseAppearance.storageKey) private var appearance = PortbaseAppearance.system.rawValue
    @AppStorage(PortbaseTheme.storageKey) private var theme = PortbaseTheme.navy.rawValue
    @AppStorage(PortbaseInterfaceFont.storageKey) private var interfaceFont = PortbaseInterfaceFont.googleSans.rawValue
    @AppStorage(PortbaseCodeFont.storageKey) private var codeFont = PortbaseCodeFont.googleSansCode.rawValue

    var body: some View {
        Section {
            LabeledContent("Appearance") {
                PortbaseSegmentedPicker(selection: $appearance,
                                        options: PortbaseAppearance.allCases.map { PortbaseChoice(value: $0.rawValue, title: $0.title, systemImage: $0.symbolName) })
            }

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Accent Color").font(.rowDetail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: Spacing.m)], spacing: Spacing.m) {
                    ForEach(PortbaseAccent.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { accent = option.rawValue }
                        } label: {
                            VStack(spacing: Spacing.xs) {
                                Circle()
                                    .fill(LinearGradient(colors: option.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                                    .overlay {
                                        if accent == option.rawValue {
                                            Image(systemName: "checkmark").font(.captionText.weight(.heavy)).foregroundStyle(.white)
                                        }
                                    }
                                    .padding(Spacing.xxs)
                                    .overlay {
                                        Circle().strokeBorder(accent == option.rawValue ? option.gradient[0] : .clear, lineWidth: 2)
                                    }
                                Text(option.title).font(.microText).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(accent == option.rawValue ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, Spacing.xxs)

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Theme").font(.rowDetail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Spacing.m)], spacing: Spacing.m) {
                    ForEach(PortbaseTheme.allCases) { option in themeCard(option) }
                }
            }
            .padding(.vertical, Spacing.xxs)

            Picker("Interface Font", selection: $interfaceFont) {
                ForEach(PortbaseInterfaceFont.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            Picker("Code Font", selection: $codeFont) {
                ForEach(PortbaseCodeFont.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(verbatim: "Aa Bb Cc 0123").font(.cardTitle)
                Text(verbatim: "SELECT 1;").font(.codeDetail).foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Font preview")
        } header: {
            Text("Appearance")
        }
    }
}

extension AppearanceSettingsSection {
    /// A theme preview: light and dark canvases with a card, so both appearances are visible at once.
    func themeCard(_ option: PortbaseTheme) -> some View {
        let palette = option.palette
        let selected = theme == option.rawValue
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { theme = option.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: 0) {
                    swatch(canvas: palette.lightSwatch.0, surface: palette.lightSwatch.1)
                    swatch(canvas: palette.darkSwatch.0, surface: palette.darkSwatch.1)
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(selected ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: selected ? 2 : 1)
                }
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(option.title).font(.rowTitle).foregroundStyle(PortSQLPalette.ink)
                    Text(option.subtitle).font(.captionText).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(canvas: UInt32, surface: UInt32) -> some View {
        Color(hex: canvas).overlay(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Capsule().fill(PortSQLPalette.accent).frame(width: 18, height: 4)
                Capsule().fill(Color.gray.opacity(0.35)).frame(width: 26, height: 4)
            }
            .padding(Spacing.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(hex: surface), in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .padding([.top, .leading], Spacing.s)
        }
    }
}

struct EditorThemeSettingsSection: View {
    @AppStorage(EditorTheme.storageKey) private var themeName = EditorTheme.portbase.rawValue

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(EditorTheme.allCases) { theme in
                    Button {
                        themeName = theme.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            EditorThemePreview(theme: theme, isSelected: themeName == theme.rawValue)
                            HStack(spacing: Spacing.xxs) {
                                Text(theme.title).font(.captionStrong).foregroundStyle(PortSQLPalette.ink)
                                if themeName == theme.rawValue {
                                    Image(systemName: "checkmark.circle.fill").font(.captionText).foregroundStyle(PortSQLPalette.accent)
                                }
                            }
                            Text(theme.subtitle).font(.microText).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(themeName == theme.rawValue ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Editor Theme")
        }
    }
}

/// Whether database passwords, SSH keys, and private CA certificates sync through iCloud Keychain.
/// Turning it off asks whether to also remove them from iCloud Keychain.
struct ConnectionSecretSyncToggle: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @AppStorage(KeychainService.syncsConnectionSecretsKey) private var syncs = true
    @State private var confirmsTurningOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Toggle(isOn: Binding(get: { syncs }, set: { on in
                if on { apply(true) } else { confirmsTurningOff = true }
            })) {
                Label("Sync Passwords and Keys", systemImage: "key.icloud")
            }
            Text(syncs
                 ? L10n.text("Database passwords, SSH keys and passphrases, and private CA certificates sync end-to-end encrypted through iCloud Keychain.")
                 : L10n.text("Database passwords, SSH keys and passphrases, and private CA certificates stay in this device’s Keychain."))
                .font(.footnoteText)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Stop Syncing Passwords and Keys?", isPresented: $confirmsTurningOff, titleVisibility: .visible) {
            Button("Keep Them in iCloud Keychain") { apply(false) }
            Button("Remove Them from iCloud Keychain", role: .destructive) { apply(false, removing: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device keeps its own copy either way. Removing deletes the copies in iCloud Keychain, but a device that still syncs adds its own back, so turn syncing off there too.")
        }
    }

    private func apply(_ on: Bool, removing: Bool = false) {
        KeychainService.setSyncsConnectionSecrets(on, removingFromICloud: removing)
        syncs = on
        bookmarks.refreshSecrets()
    }
}

/// Says where connection secrets are kept, for the editor and the connection list.
enum ConnectionSecretLocation {
    static var passwordNote: String {
        KeychainService.syncsConnectionSecrets
            ? L10n.text("Passwords are stored in Keychain and sync end-to-end encrypted through iCloud Keychain. Bookmark data never contains them.")
            : L10n.text("Database passwords are stored in Keychain on this device and are no longer written to iCloud bookmark data.")
    }

    static var serverListNote: String {
        KeychainService.syncsConnectionSecrets
            ? L10n.text("Server settings sync through iCloud. Passwords sync through iCloud Keychain.")
            : L10n.text("Server settings sync through iCloud. Passwords stay in this device’s Keychain.")
    }

    static var sshNote: String {
        KeychainService.syncsConnectionSecrets
            ? L10n.text("SSH credentials are stored in Keychain and sync through iCloud Keychain. Portbase opens a local loopback forward and verifies the SSH host key after first trust. Password login and unencrypted OpenSSH Ed25519/ECDSA private keys are supported.")
            : L10n.text("SSH credentials are stored in Keychain on this device. Portbase opens a local loopback forward and verifies the SSH host key after first trust. Password login and unencrypted OpenSSH Ed25519/ECDSA private keys are supported.")
    }

    static var certificateNote: String {
        KeychainService.syncsConnectionSecrets
            ? L10n.text("Private CA certificates are stored in Keychain and sync through iCloud Keychain.")
            : L10n.text("Private CA certificates are stored in this device’s Keychain and do not sync through iCloud.")
    }
}

private struct CloudStatusRow: View {
    var body: some View {
        let available = FileManager.default.ubiquityIdentityToken != nil
        LabeledContent {
            PortbaseChip(title: available ? L10n.text("iCloud available") : L10n.text("Unavailable"),
                         systemImage: available ? "checkmark.icloud.fill" : "icloud.slash", tint: available ? .green : .orange)
        } label: {
            Label("Status", systemImage: "icloud")
        }
    }
}

/// How result grid headers show each column's type.
enum ResultHeaderStyle: String, CaseIterable, Identifiable {
    /// The type beside the name, in a quieter style.
    case nameAndType
    /// The type on a second line under the name.
    case typeBelow
    /// Only the name; the type shows on hover and to VoiceOver.
    case nameOnly

    static let storageKey = "Portbase.resultHeaderStyle"

    /// The Mac's compact rows suit one line; touch rows have room for two.
    static var platformDefault: ResultHeaderStyle {
#if os(macOS)
        .nameAndType
#else
        .typeBelow
#endif
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nameAndType: L10n.text("Column and Type")
        case .typeBelow: L10n.text("Type Below Column")
        case .nameOnly: L10n.text("Column Name Only")
        }
    }
}

/// The result grid's header style, with a preview of each.
struct ResultHeaderStyleSettingsSection: View {
    @AppStorage(ResultHeaderStyle.storageKey) private var style = ResultHeaderStyle.platformDefault

    var body: some View {
        Section {
            Picker("Column Headers", selection: $style) {
                ForEach(ResultHeaderStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            HStack(spacing: 0) {
                preview(name: "customer_id", type: "integer")
                Divider()
                preview(name: "email", type: "text")
            }
            .frame(height: 44)
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityHidden(true)
        } header: {
            Text("Results")
        } footer: {
            Text("How result tables show each column's type. A hidden type still shows when you point at the header and to VoiceOver.")
        }
    }

    @ViewBuilder private func preview(name: String, type: String) -> some View {
        Group {
            switch style {
            case .nameAndType:
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(name).font(.codeCaption.weight(.bold))
                    Text(type).font(.microText.monospaced()).foregroundStyle(.tertiary)
                }
            case .typeBelow:
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.codeCaption.weight(.bold))
                    Text(type).font(.microText.monospaced()).foregroundStyle(.tertiary)
                }
            case .nameOnly:
                Text(name).font(.codeCaption.weight(.bold))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
