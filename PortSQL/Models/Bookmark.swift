import Foundation
import SwiftUI

enum DatabaseEngine: String, Codable, CaseIterable, Identifiable {
    case mysql = "MySQL"
    case postgresql = "PostgreSQL"

    var id: String { rawValue }

    var defaultPort: Int {
        switch self {
        case .mysql: 3306
        case .postgresql: 5432
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .mysql:
            LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .postgresql:
            LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var symbolName: String {
        switch self {
        case .mysql: "cylinder.split.1x2.fill"
        case .postgresql: "shippingbox.circle.fill"
        }
    }
}

enum TransportSecurityMode: String, Codable, CaseIterable, Identifiable {
    case systemCA
    case privateCA
    case preferTLS
    case plaintext

    var id: String { rawValue }

    var requiresPrivateCA: Bool { self == .privateCA }
    var permitsPlaintext: Bool { self == .preferTLS || self == .plaintext }
}

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var engine: DatabaseEngine
    var iconName: String? = nil
    var host: String
    var port: Int
    var username: String
    var password: String
    var defaultDatabase: String
    var notes: String = ""
    var transportSecurityMode: TransportSecurityMode = .systemCA
    var privateCACertificate: String = ""
    var usesTLS: Bool {
        get { transportSecurityMode != .plaintext }
        set { transportSecurityMode = newValue ? .systemCA : .plaintext }
    }
    var isReadOnly: Bool = false
    var usesSSHTunnel: Bool = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUsername: String = ""
    var sshPassword: String = ""
    var sshPrivateKey: String = ""
    var sshPassphrase: String = ""
    var schemaCachingEnabled: Bool = true
    var schemaCacheDurationHours: Int = 24
    var createdAt: Date = .now

    var database: String {
        get { defaultDatabase }
        set { defaultDatabase = newValue }
    }

    var resolvedIconName: String? {
        guard let iconName, !iconName.isEmpty else {
            return nil
        }
        return iconName
    }

    var trimmedDefaultDatabase: String {
        defaultDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var schemaCacheDuration: TimeInterval {
        TimeInterval(max(1, schemaCacheDurationHours)) * 60 * 60
    }

    var schemaCacheDurationLabel: String {
        let hours = max(1, schemaCacheDurationHours)
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        return hours.isMultiple(of: 24) ? "\(days)d" : "\(hours)h"
    }

    var sshTunnelSummary: String? {
        guard usesSSHTunnel else { return nil }
        let user = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return L10n.text("SSH tunnel enabled") }
        return user.isEmpty ? "\(host):\(sshPort)" : "\(user)@\(host):\(sshPort)"
    }

    var initials: String {
        let source = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : name
        let parts = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)

        let letters = parts.compactMap { part -> String? in
            guard let scalar = part.first else { return nil }
            return String(scalar).uppercased()
        }

        if !letters.isEmpty {
            return letters.joined()
        }

        let compact = source
            .filter(\.isLetter)
            .prefix(2)
            .uppercased()
        return compact.isEmpty ? engine.rawValue.prefix(2).uppercased() : compact
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case engine
        case iconName
        case host
        case port
        case username
        case password
        case defaultDatabase
        case database
        case notes
        case usesTLS
        case transportSecurityMode
        case privateCACertificate
        case isReadOnly
        case usesSSHTunnel
        case sshHost
        case sshPort
        case sshUsername
        case sshPassword
        case sshPrivateKey
        case sshPassphrase
        case schemaCachingEnabled
        case schemaCacheDurationHours
        case createdAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        engine: DatabaseEngine,
        iconName: String? = nil,
        host: String,
        port: Int,
        username: String,
        password: String,
        defaultDatabase: String,
        notes: String = "",
        usesTLS: Bool = true,
        transportSecurityMode: TransportSecurityMode? = nil,
        privateCACertificate: String = "",
        isReadOnly: Bool = false,
        usesSSHTunnel: Bool = false,
        sshHost: String = "",
        sshPort: Int = 22,
        sshUsername: String = "",
        sshPassword: String = "",
        sshPrivateKey: String = "",
        sshPassphrase: String = "",
        schemaCachingEnabled: Bool = true,
        schemaCacheDurationHours: Int = 24,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.iconName = iconName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.defaultDatabase = defaultDatabase
        self.notes = notes
        self.transportSecurityMode = transportSecurityMode ?? (usesTLS ? .systemCA : .plaintext)
        self.privateCACertificate = privateCACertificate
        self.isReadOnly = isReadOnly
        self.usesSSHTunnel = usesSSHTunnel
        self.sshHost = sshHost
        self.sshPort = max(1, sshPort)
        self.sshUsername = sshUsername
        self.sshPassword = sshPassword
        self.sshPrivateKey = sshPrivateKey
        self.sshPassphrase = sshPassphrase
        self.schemaCachingEnabled = schemaCachingEnabled
        self.schemaCacheDurationHours = max(1, schemaCacheDurationHours)
        self.createdAt = createdAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        engine: DatabaseEngine,
        iconName: String? = nil,
        host: String,
        port: Int,
        username: String,
        password: String,
        database: String,
        notes: String = "",
        usesTLS: Bool = true,
        transportSecurityMode: TransportSecurityMode? = nil,
        privateCACertificate: String = "",
        isReadOnly: Bool = false,
        usesSSHTunnel: Bool = false,
        sshHost: String = "",
        sshPort: Int = 22,
        sshUsername: String = "",
        sshPassword: String = "",
        sshPrivateKey: String = "",
        sshPassphrase: String = "",
        schemaCachingEnabled: Bool = true,
        schemaCacheDurationHours: Int = 24,
        createdAt: Date = .now
    ) {
        self.init(
            id: id,
            name: name,
            engine: engine,
            iconName: iconName,
            host: host,
            port: port,
            username: username,
            password: password,
            defaultDatabase: database,
            notes: notes,
            usesTLS: usesTLS,
            transportSecurityMode: transportSecurityMode,
            privateCACertificate: privateCACertificate,
            isReadOnly: isReadOnly,
            usesSSHTunnel: usesSSHTunnel,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            sshPassword: sshPassword,
            sshPrivateKey: sshPrivateKey,
            sshPassphrase: sshPassphrase,
            schemaCachingEnabled: schemaCachingEnabled,
            schemaCacheDurationHours: schemaCacheDurationHours,
            createdAt: createdAt
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        engine = try container.decode(DatabaseEngine.self, forKey: .engine)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        defaultDatabase = try container.decodeIfPresent(String.self, forKey: .defaultDatabase)
            ?? container.decodeIfPresent(String.self, forKey: .database)
            ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        if let explicitMode = try container.decodeIfPresent(TransportSecurityMode.self, forKey: .transportSecurityMode) {
            transportSecurityMode = explicitMode
        } else {
            transportSecurityMode = (try container.decodeIfPresent(Bool.self, forKey: .usesTLS) ?? true) ? .systemCA : .plaintext
        }
        privateCACertificate = try container.decodeIfPresent(String.self, forKey: .privateCACertificate) ?? ""
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        usesSSHTunnel = try container.decodeIfPresent(Bool.self, forKey: .usesSSHTunnel) ?? false
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = max(1, try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22)
        sshUsername = try container.decodeIfPresent(String.self, forKey: .sshUsername) ?? ""
        sshPassword = try container.decodeIfPresent(String.self, forKey: .sshPassword) ?? ""
        sshPrivateKey = try container.decodeIfPresent(String.self, forKey: .sshPrivateKey) ?? ""
        sshPassphrase = try container.decodeIfPresent(String.self, forKey: .sshPassphrase) ?? ""
        schemaCachingEnabled = try container.decodeIfPresent(Bool.self, forKey: .schemaCachingEnabled) ?? true
        schemaCacheDurationHours = max(1, try container.decodeIfPresent(Int.self, forKey: .schemaCacheDurationHours) ?? 24)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(engine, forKey: .engine)
        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode("", forKey: .password)
        try container.encode(defaultDatabase, forKey: .defaultDatabase)
        try container.encode(notes, forKey: .notes)
        try container.encode(usesTLS, forKey: .usesTLS)
        try container.encode(transportSecurityMode, forKey: .transportSecurityMode)
        try container.encode(privateCACertificate.isEmpty ? "" : "<keychain>", forKey: .privateCACertificate)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encode(usesSSHTunnel, forKey: .usesSSHTunnel)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(max(1, sshPort), forKey: .sshPort)
        try container.encode(sshUsername, forKey: .sshUsername)
        try container.encode("", forKey: .sshPassword)
        try container.encode(sshPrivateKey.isEmpty ? "" : "<keychain>", forKey: .sshPrivateKey)
        try container.encode("", forKey: .sshPassphrase)
        try container.encode(schemaCachingEnabled, forKey: .schemaCachingEnabled)
        try container.encode(max(1, schemaCacheDurationHours), forKey: .schemaCacheDurationHours)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

struct SchemaSuggestion: Identifiable, Hashable {
    var id: String { "\(kind)-\(value)" }
    let kind: String
    let value: String
}

struct EditorHint: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let message: String
    let severity: Severity

    enum Severity: String {
        case info
        case warning
        case critical

        var tint: Color {
            switch self {
            case .info: .blue
            case .warning: .orange
            case .critical: .red
            }
        }
    }
}
