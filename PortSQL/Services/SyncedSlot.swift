import Foundation

extension Notification.Name {
    /// Posted on the main thread when a synced secret or host key gains or settles a conflict.
    static let syncConflictsDidChange = Notification.Name("Portbase.syncConflictsDidChange")
}

/// This device as other devices see it in synced versions.
enum SyncDevice {
    private static let idKey = "Portbase.deviceID"
    private static let lock = NSLock()

    static var id: String {
        lock.lock()
        defer { lock.unlock() }
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    /// A name to tell devices apart by, such as the Mac's name or "iPad".
    static var name: String {
#if os(macOS)
        return Host.current().localizedName ?? "Mac"
#else
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
#endif
    }
}

/// One value kept on this device and, while syncing, as a versioned iCloud Keychain item, such as a
/// connection's password or a server's trusted host key.
///
/// The iCloud item holds the value with when and on which device it last changed. This device remembers
/// when its own copy last changed and which iCloud version it last agreed with, which tells a change on
/// one side, taken over by the other, from changes on both. When both sides changed to different values,
/// the policy decides: secrets take the later change and keep the other value as a conflict to review;
/// host keys keep this device's key and fail closed on anything else until the user chooses.
struct SyncedSlot {
    enum Policy {
        case laterChangeWins
        case keepLocal
    }

    static let remoteSuffix = ".sync"
    static let conflictSuffix = ".conflict"
    /// How versions before conflict resolution marked a secret cleared on a syncing device.
    private static let legacyClearedMarker = "\u{1}portbase.cleared"
    private static let stateKey = "Portbase.syncState"
    private static let stateLock = NSLock()

    let account: String
    let policy: Policy
    /// This device's copy, with when the store saw it change if it knows.
    let readLocal: () -> (value: String, modified: Date?)?
    let writeLocal: (String?) -> Void

    private var remoteAccount: String { account + Self.remoteSuffix }
    private var conflictAccount: String { account + Self.conflictSuffix }

    /// The slot account an iCloud item belongs to, including the unversioned items of earlier versions.
    static func baseAccount(_ syncedAccount: String) -> String? {
        if syncedAccount.hasSuffix(remoteSuffix) { return String(syncedAccount.dropLast(remoteSuffix.count)) }
        return syncedAccount
    }

    // MARK: Reading and writing

    /// This device's value: nil when it never had one, empty once cleared.
    func localValue() -> String? {
        if let local = readLocal() { return local.value }
        return state.local == nil ? nil : ""
    }

    /// Brings this device's copy and the iCloud copy into agreement and returns the value to use: nil when
    /// neither side ever had one, empty once cleared.
    @discardableResult
    func reconcile() -> String? {
        let local = localVersion()
        let remote = remoteVersion()
        let state = state
        switch SyncResolution.resolve(local: local, remote: remote, base: state.base) {
        case .inSync:
            if let remote {
                if remote.device == "legacy" { putRemote(remote) }
                update { $0.base = remote.modified; if $0.local == nil { $0.local = remote.modified } }
            }
            return (local ?? remote).map { $0.value ?? "" }
        case .upload:
            guard let local else { return nil }
            putRemote(local)
            update { $0.base = local.modified }
            return local.value ?? ""
        case .adopt:
            guard let remote else { return nil }
            adopt(remote)
            return remote.value ?? ""
        case .conflict:
            guard let local, let remote else { return nil }
            switch policy {
            case .keepLocal:
                saveConflict(remote)
                return local.value ?? ""
            case .laterChangeWins:
                let winner = SyncResolution.winner(local, remote)
                let loser = winner == local ? remote : local
                if loser.value != nil { saveConflict(loser) }
                if winner == local {
                    putRemote(local)
                    update { $0.base = local.modified }
                } else {
                    adopt(remote)
                }
                return winner.value ?? ""
            }
        }
    }

    /// Saves a new value, or clears it with nil, as the newest version. Settles any conflict.
    func write(_ value: String?, syncing: Bool) {
        let now = Date()
        writeLocal(value)
        update { $0.local = now }
        if syncing {
            putRemote(SyncedVersion(value: value, modified: now, device: SyncDevice.id, deviceName: SyncDevice.name))
            update { $0.base = now }
        }
        dismissConflict()
    }

    func removeRemote() {
        KeychainService.deleteItem(remoteAccount, synced: true)
        KeychainService.deleteItem(account, synced: true)
        update { $0.base = nil }
    }

    func removeLocal() {
        writeLocal(nil)
        update { $0 = State() }
        dismissConflict()
    }

    func removeEverywhere() {
        removeLocal()
        removeRemote()
    }

    // MARK: Conflicts

    /// The other side's value from the last conflict, until it's reviewed.
    func conflict() -> SyncedVersion? {
        KeychainService.record(conflictAccount, synced: false).flatMap { try? JSONDecoder().decode(SyncedVersion.self, from: Data($0.value.utf8)) }
    }

    func dismissConflict() {
        guard KeychainService.record(conflictAccount, synced: false) != nil else { return }
        KeychainService.deleteItem(conflictAccount, synced: false)
        Self.announceConflicts()
    }

    private func saveConflict(_ version: SyncedVersion) {
        guard conflict() != version, let data = try? JSONEncoder().encode(version),
              let text = String(data: data, encoding: .utf8) else { return }
        KeychainService.setItem(text, account: conflictAccount, synced: false)
        Self.announceConflicts()
    }

    private static func announceConflicts() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .syncConflictsDidChange, object: nil) }
    }

    // MARK: Versions

    private func localVersion() -> SyncedVersion? {
        let local = readLocal()
        let changed = state.local
        guard local != nil || changed != nil else { return nil }
        return SyncedVersion(value: local?.value, modified: changed ?? local?.modified ?? .distantPast,
                             device: SyncDevice.id, deviceName: SyncDevice.name)
    }

    private func remoteVersion() -> SyncedVersion? {
        if let record = KeychainService.record(remoteAccount, synced: true),
           let version = try? JSONDecoder().decode(SyncedVersion.self, from: Data(record.value.utf8)) {
            return version
        }
        // An unversioned value from before conflict resolution, dated by when Keychain saw it change.
        guard let legacy = KeychainService.record(account, synced: true) else { return nil }
        return SyncedVersion(value: legacy.value == Self.legacyClearedMarker ? nil : legacy.value,
                             modified: legacy.modified ?? .distantPast, device: "legacy", deviceName: nil)
    }

    private func adopt(_ remote: SyncedVersion) {
        writeLocal(remote.value)
        // An earlier version's unversioned value becomes a versioned one, keeping its date.
        if remote.device == "legacy" { putRemote(remote) }
        update { $0.local = remote.modified; $0.base = remote.modified }
    }

    private func putRemote(_ version: SyncedVersion) {
        var version = version
        if version.device == "legacy" { version.device = SyncDevice.id; version.deviceName = SyncDevice.name }
        guard let data = try? JSONEncoder().encode(version), let text = String(data: data, encoding: .utf8) else { return }
        KeychainService.setItem(text, account: remoteAccount, synced: true)
        // The unversioned item of earlier versions is replaced by the versioned one.
        KeychainService.deleteItem(account, synced: true)
    }

    // MARK: State

    /// When this device's copy last changed, and the iCloud version it last agreed with.
    private struct State: Codable, Equatable {
        var local: Date?
        var base: Date?
    }

    private var state: State {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return Self.allStates()[account] ?? State()
    }

    private func update(_ change: (inout State) -> Void) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        var states = Self.allStates()
        var state = states[account] ?? State()
        change(&state)
        states[account] = state == State() ? nil : state
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    private static func allStates() -> [String: State] {
        UserDefaults.standard.data(forKey: stateKey).flatMap { try? JSONDecoder().decode([String: State].self, from: $0) } ?? [:]
    }
}

// MARK: - SSH host keys

/// Trusted SSH host keys, kept on this device and, when the user turns it on, synced through iCloud
/// Keychain so a server trusted on one device is trusted on the others. Keys are never merged: when two
/// devices trust different keys for a server, each keeps its own, which still fails closed on any other
/// key, until the user picks one.
final class SSHTunnelSyncingHostKeyStore: SSHTunnelHostKeyStore, @unchecked Sendable {
    static let shared = SSHTunnelSyncingHostKeyStore()
    static let syncsKey = "Portbase.syncSSHHostKeys"
    private static let accountPrefix = "hostkey."

    /// Off unless turned on.
    static var isSyncing: Bool { UserDefaults.standard.bool(forKey: syncsKey) }

    private let local: SSHTunnelUserDefaultsHostKeyStore

    init(local: SSHTunnelUserDefaultsHostKeyStore = SSHTunnelUserDefaultsHostKeyStore()) {
        self.local = local
    }

    static func storeKey(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(max(1, port))"
    }

    func fingerprint(for hostKey: String) -> String? {
        let value = Self.isSyncing ? slot(hostKey).reconcile() : local.fingerprint(for: hostKey)
        return value?.isEmpty == false ? value : nil
    }

    func setFingerprint(_ fingerprint: String, for hostKey: String) {
        slot(hostKey).write(fingerprint, syncing: Self.isSyncing)
    }

    /// The key another device trusts for this server, when it differs from this device's.
    func conflict(for hostKey: String) -> SyncedVersion? { slot(hostKey).conflict() }

    /// Trusts this device's key everywhere, replacing the other device's.
    func keepCurrent(for hostKey: String) {
        guard let current = local.fingerprint(for: hostKey) else { slot(hostKey).dismissConflict(); return }
        slot(hostKey).write(current, syncing: Self.isSyncing)
    }

    /// Trusts the key another device trusts.
    func useOther(for hostKey: String) {
        guard let other = conflict(for: hostKey) else { return }
        slot(hostKey).write(other.value, syncing: Self.isSyncing)
    }

    /// Forgets the server's key, so the next connection asks to trust whatever key it presents.
    func forget(_ hostKey: String) {
        slot(hostKey).write(nil, syncing: Self.isSyncing)
    }

    func setSyncing(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.syncsKey)
        guard enabled else { return }
        let remote = KeychainService.accounts(synced: true).compactMap { account -> String? in
            guard account.hasPrefix(Self.accountPrefix), account.hasSuffix(SyncedSlot.remoteSuffix) else { return nil }
            return String(account.dropFirst(Self.accountPrefix.count).dropLast(SyncedSlot.remoteSuffix.count))
        }
        for host in Set(local.hosts).union(remote) { _ = slot(host).reconcile() }
    }

    private func slot(_ hostKey: String) -> SyncedSlot {
        let local = local
        return SyncedSlot(account: Self.accountPrefix + hostKey, policy: .keepLocal,
                          readLocal: { local.fingerprint(for: hostKey).map { ($0, nil) } },
                          writeLocal: { value in
                              if let value { local.setFingerprint(value, for: hostKey) } else { local.removeFingerprint(for: hostKey) }
                          })
    }
}
