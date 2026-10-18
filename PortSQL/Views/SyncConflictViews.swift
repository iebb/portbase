import SwiftUI

extension KeychainService.SecretKind {
    var title: String {
        switch self {
        case .databasePassword: L10n.text("Database password")
        case .sshPassword: L10n.text("SSH password")
        case .sshPrivateKey: L10n.text("SSH private key")
        case .sshPassphrase: L10n.text("SSH passphrase")
        case .privateCACertificate: L10n.text("Private CA certificate")
        }
    }
}

extension SyncedVersion {
    /// Who saved this version, for conflict messages.
    var deviceTitle: String {
        if device == SyncDevice.id { return L10n.text("This device") }
        return deviceName ?? L10n.text("Another device")
    }
}

/// A connection's secrets that two devices changed at once. The later change is in use; the other value
/// waits here, without being shown, until the user keeps the current one or switches to it.
struct SecretConflictSection: View {
    @Binding var profile: ConnectionProfile
    @EnvironmentObject private var bookmarks: BookmarkStore
    @State private var conflicts: [KeychainService.SecretKind: SyncedVersion] = [:]

    var body: some View {
        Group {
            if !conflicts.isEmpty {
                Section {
                    ForEach(KeychainService.SecretKind.allCases.filter { conflicts[$0] != nil }, id: \.self) { kind in
                        if let conflict = conflicts[kind] { row(kind, conflict) }
                    }
                } header: {
                    Label("Sync Conflicts", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                } footer: {
                    Text("These changed on more than one device at once. The later change is in use, and the other value is kept until you choose.")
                }
            }
        }
        .task(id: profile.id) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .syncConflictsDidChange)) { _ in load() }
    }

    private func row(_ kind: KeychainService.SecretKind, _ conflict: SyncedVersion) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(kind.title).font(.rowTitle)
            Text(conflict.value == nil
                 ? L10n.format("%1$@ cleared it on %2$@.", conflict.deviceTitle, conflict.modified.formatted(date: .abbreviated, time: .shortened))
                 : L10n.format("%1$@ saved a different value on %2$@.", conflict.deviceTitle, conflict.modified.formatted(date: .abbreviated, time: .shortened)))
                .font(.captionText)
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                Button(conflict.value == nil ? L10n.text("Clear It") : L10n.text("Use That Value")) { resolve(kind, usingOther: true) }
                Button("Keep Current") { resolve(kind, usingOther: false) }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func resolve(_ kind: KeychainService.SecretKind, usingOther: Bool) {
        KeychainService.resolveConflict(kind, for: profile.id, usingOther: usingOther)
        if usingOther {
            let value = KeychainService.secret(kind, for: profile.id)
            switch kind {
            case .databasePassword: profile.password = value
            case .sshPassword: profile.sshPassword = value
            case .sshPrivateKey: profile.sshPrivateKey = value
            case .sshPassphrase: profile.sshPassphrase = value
            case .privateCACertificate: profile.privateCACertificate = value
            }
        }
        bookmarks.refreshSecrets()
        load()
    }

    private func load() { conflicts = KeychainService.conflicts(for: profile.id) }
}

/// The SSH server's trusted host key, a way to forget it, and, when another device trusts a different
/// key, the choice between the two. Until the user chooses, this device keeps its own key.
struct SSHHostKeyTrustRows: View {
    let host: String
    let port: Int
    @State private var trusted: String?
    @State private var conflict: SyncedVersion?
    @State private var confirmsForgetting = false

    private var key: String { SSHTunnelSyncingHostKeyStore.storeKey(host: host, port: port) }
    private var store: SSHTunnelSyncingHostKeyStore { .shared }

    var body: some View {
        Group {
            if let trusted {
                LabeledContent("Trusted Host Key") {
                    Text(trusted).font(.codeCaption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Button("Forget Host Key", role: .destructive) { confirmsForgetting = true }
            }
            if let conflict, let other = conflict.value {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(L10n.format("%@ trusts a different host key for this server.", conflict.deviceTitle),
                          systemImage: "exclamationmark.shield")
                        .font(.rowTitle)
                        .foregroundStyle(.orange)
                    Text(other).font(.codeCaption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Text("Until you choose, this device keeps trusting its own key, and a server presenting any other key is refused.")
                        .font(.captionText)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.s) {
                        Button("Trust That Key") { store.useOther(for: key); load() }
                        Button("Keep This Device's Key") { store.keepCurrent(for: key); load() }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, Spacing.xxs)
            }
        }
        .task(id: key) { load() }
        .onReceive(NotificationCenter.default.publisher(for: .syncConflictsDidChange)) { _ in load() }
        .confirmationDialog("Forget Host Key?", isPresented: $confirmsForgetting, titleVisibility: .visible) {
            Button("Forget Host Key", role: .destructive) { store.forget(key); load() }
        } message: {
            Text("The next connection trusts the key the server presents, as on first use.")
        }
    }

    private func load() {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { trusted = nil; conflict = nil; return }
        trusted = store.fingerprint(for: key)
        conflict = store.conflict(for: key)
    }
}

/// Whether trusted SSH host keys sync through iCloud Keychain. Off unless turned on.
struct SSHHostKeySyncToggle: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @AppStorage(SSHTunnelSyncingHostKeyStore.syncsKey) private var syncs = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Toggle(isOn: Binding(get: { syncs }, set: { on in
                SSHTunnelSyncingHostKeyStore.shared.setSyncing(on)
                syncs = on
                bookmarks.refreshSyncConflicts()
            })) {
                Label("Sync Trusted SSH Host Keys", systemImage: "checkmark.shield")
            }
            Text("A server trusted on one device is trusted on the others. When two devices trust different keys for a server, each keeps its own until you choose in the connection's SSH settings.")
                .font(.footnoteText)
                .foregroundStyle(.secondary)
        }
    }
}

/// Connections whose passwords, keys, or host keys changed on more than one device at once.
struct SyncConflictBanner: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var workspace: WorkspaceViewModel

    private var profiles: [ConnectionProfile] { bookmarks.bookmarks.filter { bookmarks.syncConflicts.contains($0.id) } }

    var body: some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(L10n.format("Sync conflicts: %d", profiles.count), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.rowTitle.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Passwords, keys, or trusted host keys of these connections changed on more than one device at once. Open one to choose which to keep.")
                    .font(.captionText)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(profiles) { profile in
                            Button(profile.displayTitle) { workspace.selectedProfileForEdit = profile }
                                .buttonStyle(.portbaseToolbar)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.orange.opacity(0.3)) }
        }
    }
}
