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
    var usesTLS: Bool = true
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
        self.usesTLS = usesTLS
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
        usesTLS = try container.decodeIfPresent(Bool.self, forKey: .usesTLS) ?? true
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
        try container.encode(password, forKey: .password)
        try container.encode(defaultDatabase, forKey: .defaultDatabase)
        try container.encode(notes, forKey: .notes)
        try container.encode(usesTLS, forKey: .usesTLS)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

extension ConnectionProfile {
    static let developmentBookmarkID = UUID(uuidString: "5D2D7E7A-9C2F-4F10-BD6F-BE7EAFEA4E10")!

    static func developmentProfileFromConfiguration() -> ConnectionProfile? {
        guard let rawURL = AppConfiguration.developmentDatabaseURL,
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            return nil
        }

        let engine: DatabaseEngine
        switch scheme {
        case "mysql":
            engine = .mysql
        case "postgres", "postgresql":
            engine = .postgresql
        default:
            return nil
        }

        let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let name = AppConfiguration.developmentDatabaseName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = components.user?.removingPercentEncoding ?? ""
        let password = components.password?.removingPercentEncoding ?? ""

        return ConnectionProfile(
            id: developmentBookmarkID,
            name: name?.isEmpty == false ? name! : "Development Database",
            engine: engine,
            iconName: nil,
            host: host,
            port: components.port ?? engine.defaultPort,
            username: username,
            password: password,
            defaultDatabase: database,
            notes: "Auto-configured development connection",
            usesTLS: inferredTLS(from: components, engine: engine)
        )
    }

    private static func inferredTLS(from components: URLComponents, engine: DatabaseEngine) -> Bool {
        guard let queryItems = components.queryItems, !queryItems.isEmpty else {
            return engine == .postgresql
        }

        for key in ["tls", "ssl", "sslmode"] {
            if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value?
                .lowercased() {
                switch value {
                case "1", "true", "yes", "require", "required", "verify-ca", "verify-full":
                    return true
                case "0", "false", "no", "disable", "disabled", "off":
                    return false
                default:
                    continue
                }
            }
        }

        return engine == .postgresql
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
