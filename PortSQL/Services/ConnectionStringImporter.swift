import Foundation

/// Fills a connection profile from a URL-style connection string.
///
/// Credentials stay in the returned profile only; saving it moves them to the Keychain.
/// A string that asks for an unencrypted or downgradable connection never changes the
/// transport mode: plaintext remains an explicit choice in Transport Security.
struct ConnectionStringImport {
    var profile: ConnectionProfile
    var notices: [String]
}

enum ConnectionStringError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme(String)
    case localFile
    case invalid

    var errorDescription: String? {
        switch self {
        case .empty: L10n.text("Paste a connection string to import.")
        case .unsupportedScheme(let scheme): L10n.format("Portbase can’t import “%@” connection strings.", scheme)
        case .localFile: L10n.text("SQLite databases are files. Create or import one from the SQLite section instead.")
        case .invalid: L10n.text("This connection string is incomplete or malformed. Check the host, port, and encoding.")
        }
    }
}

enum ConnectionStringImporter {
    static let maximumLength = 16_384

    static func apply(_ source: String, to base: ConnectionProfile) throws -> ConnectionStringImport {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConnectionStringError.empty }
        guard text.utf8.count <= maximumLength, !text.contains("\0"), !text.contains(where: \.isNewline) else {
            throw ConnectionStringError.invalid
        }
        if text.lowercased().hasPrefix("jdbc:") { text = String(text.dropFirst(5)) }
        guard let separator = text.range(of: "://") else { throw ConnectionStringError.invalid }
        let scheme = text[..<separator.lowerBound].lowercased()

        switch scheme {
        case "mongodb", "mongodb+srv":
            let parsed = try MongoConnectionURI.parse(text)
            var notices: [String] = []
            if parsed.requestedWriteRetries {
                notices.append(L10n.text("Writes are sent once. Check the result before retrying an interrupted write."))
            }
            var profile = parsed.applying(to: base)
            // The MongoDB parser honours an explicit tls=false; keep that choice visible rather than silent.
            if profile.transportSecurityMode == .plaintext && base.transportSecurityMode != .plaintext {
                profile.transportSecurityMode = base.transportSecurityMode
                notices.append(plaintextNotice)
            }
            if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = profile.host }
            return ConnectionStringImport(profile: profile, notices: notices)
        case "sqlite", "file":
            throw ConnectionStringError.localFile
        default:
            break
        }

        guard let engine = engine(for: scheme, current: base.engine) else {
            throw ConnectionStringError.unsupportedScheme(scheme)
        }
        guard let components = URLComponents(string: text), let rawHost = components.host, !rawHost.isEmpty else {
            throw ConnectionStringError.invalid
        }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        guard !host.contains("@"), !host.contains("/"), !host.contains(","), host.utf8.count <= 253 else { throw ConnectionStringError.invalid }

        var profile = base
        var notices: [String] = []
        profile.engine = engine
        profile.host = host
        if let user = components.user { profile.username = user }
        if let password = components.password {
            profile.password = password
            profile.passwordWasExplicitlySet = true
        }

        let secureScheme = ["rediss", "https", "clickhouses"].contains(scheme)
        let insecureScheme = ["redis", "http"].contains(scheme)
        if let port = components.port {
            guard (1...65_535).contains(port) else { throw ConnectionStringError.invalid }
            profile.port = port
        } else if engine == .clickhouse {
            profile.port = insecureScheme ? 8123 : 8443
        } else {
            profile.port = engine.defaultPort
        }

        let path = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        guard !path.contains("/") else { throw ConnectionStringError.invalid }
        if engine == .redis {
            if !path.isEmpty {
                guard let number = Int32(path), number >= 0 else { throw ConnectionStringError.invalid }
                profile.defaultDatabase = String(number)
            } else if profile.engine != base.engine || Int32(profile.trimmedDefaultDatabase).map({ $0 >= 0 }) != true {
                profile.defaultDatabase = "0"
            }
        } else if engine == .elasticsearch {
            if !path.isEmpty { notices.append(L10n.text("The URL path was ignored. Choose an index in the console.")) }
        } else if !path.isEmpty {
            profile.defaultDatabase = path
        }

        var ignored: [String] = []
        var requestsPlaintext = insecureScheme
        var requestsTLS = secureScheme
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            let value = (item.value ?? "").lowercased()
            switch name {
            case "sslmode", "ssl-mode", "ssl_mode":
                if ["disable", "disabled"].contains(value) { requestsPlaintext = true }
                else if ["allow", "prefer", "preferred"].contains(value) { notices.append(preferNotice) }
                else { requestsTLS = true }
            case "ssl", "tls", "usessl", "use_ssl", "secure":
                if ["false", "0", "no", "off"].contains(value) { requestsPlaintext = true } else { requestsTLS = true }
            case "sslrootcert", "sslca", "ssl-ca", "tlscafile", "servercacert":
                notices.append(L10n.text("This connection string names a CA certificate file. Import that certificate under Transport Security."))
            case "applicationname", "application_name", "connect_timeout", "connecttimeout", "charset":
                break
            default:
                ignored.append(item.name)
            }
        }
        if requestsPlaintext { notices.append(plaintextNotice) }
        if requestsTLS && (profile.transportSecurityMode == .plaintext || profile.transportSecurityMode == .preferTLS) {
            profile.transportSecurityMode = .systemCA
        }
        if !ignored.isEmpty {
            notices.append(L10n.format("Ignored options: %@", ignored.sorted().joined(separator: ", ")))
        }

        if engine == .clickhouse, profile.httpAuthentication == .apiKey { profile.httpAuthentication = .basic }
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.name = profile.trimmedDefaultDatabase.isEmpty || engine == .redis ? host : "\(profile.trimmedDefaultDatabase) @ \(host)"
        }
        if profile.engine != base.engine, profile.iconName == BookmarkIconCatalog.defaultName(for: base.engine) {
            profile.iconName = nil
        }
        return ConnectionStringImport(profile: profile, notices: notices)
    }

    /// Recognizes a pasted string, so the editor can offer an import.
    static func looksLikeConnectionString(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = value.hasPrefix("jdbc:") ? String(value.dropFirst(5)) : value
        guard let separator = candidate.range(of: "://") else { return false }
        let scheme = String(candidate[..<separator.lowerBound])
        return ["mongodb", "mongodb+srv"].contains(scheme) || engine(for: scheme, current: .postgresql) != nil
    }

    private static func engine(for scheme: String, current: DatabaseEngine) -> DatabaseEngine? {
        switch scheme {
        case "postgres", "postgresql", "pgsql": .postgresql
        case "mysql", "mysqlx": .mysql
        case "mariadb": .mariadb
        case "redis", "rediss": .redis
        case "clickhouse", "clickhouses", "ch": .clickhouse
        case "elasticsearch", "es", "opensearch": .elasticsearch
        // Plain HTTP URLs are only meaningful for the HTTP engines the person already chose.
        case "http", "https": current == .clickhouse || current == .elasticsearch ? current : nil
        default: nil
        }
    }

    private static var plaintextNotice: String {
        L10n.text("This connection string asks for an unencrypted connection. TLS stays required; choose Plaintext Only under Transport Security only if the server has no TLS.")
    }

    private static var preferNotice: String {
        L10n.text("This connection string allows falling back to plaintext. TLS stays required; choose Prefer TLS under Transport Security if you need the fallback.")
    }
}
