import Foundation

struct MongoHostAddress: Codable, Hashable, Sendable {
    let host: String
    let port: Int

    var displayName: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func parse(_ source: String, defaultPort: Int = 27017) throws -> Self {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MongoConnectionError.invalidURI }
        var host: String
        var port = defaultPort
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]") else { throw MongoConnectionError.invalidURI }
            host = String(text[text.index(after: text.startIndex)..<closing])
            let suffix = text[text.index(after: closing)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":"), let value = Int(suffix.dropFirst()) else { throw MongoConnectionError.invalidURI }
                port = value
            }
            guard DatabaseService.isIPAddress(host) else { throw MongoConnectionError.invalidURI }
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw MongoConnectionError.invalidURI }
            host = String(parts[0])
            if parts.count == 2 {
                guard let value = Int(parts[1]) else { throw MongoConnectionError.invalidURI }
                port = value
            }
            host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard !host.isEmpty, host.utf8.count <= 253,
                  host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
                throw MongoConnectionError.invalidURI
            }
        }
        guard (1...65535).contains(port) else { throw MongoConnectionError.invalidURI }
        return Self(host: host, port: port)
    }
}

// Only connection metadata is serialized. The imported URI and its password are never retained here.
struct MongoConnectionOptions: Codable, Hashable, Sendable {
    var additionalHosts: [MongoHostAddress] = []
    var usesSRV = false
    var directConnection = false
    var replicaSet = ""
    var authenticationSourceIsExplicit = false
    var applicationName = "Portbase"
    var majorityWriteConcern = false
    var authenticationMechanism = "DEFAULT"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case additionalHosts, usesSRV, directConnection, replicaSet, authenticationSourceIsExplicit
        case applicationName, majorityWriteConcern, authenticationMechanism
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        additionalHosts = try values.decodeIfPresent([MongoHostAddress].self, forKey: .additionalHosts) ?? []
        usesSRV = try values.decodeIfPresent(Bool.self, forKey: .usesSRV) ?? false
        directConnection = try values.decodeIfPresent(Bool.self, forKey: .directConnection) ?? false
        replicaSet = try values.decodeIfPresent(String.self, forKey: .replicaSet) ?? ""
        authenticationSourceIsExplicit = try values.decodeIfPresent(Bool.self, forKey: .authenticationSourceIsExplicit) ?? false
        applicationName = try values.decodeIfPresent(String.self, forKey: .applicationName) ?? "Portbase"
        majorityWriteConcern = try values.decodeIfPresent(Bool.self, forKey: .majorityWriteConcern) ?? false
        authenticationMechanism = try values.decodeIfPresent(String.self, forKey: .authenticationMechanism) ?? "DEFAULT"
    }
}

enum MongoConnectionError: LocalizedError {
    case invalidURI, unsupportedURIOption, invalidSRVRecords, dnsLookupFailed, primaryUnavailable, replicaSetMismatch
    case transactionsUnavailable, documentChanged, invalidDocument, immutableIdentifier, commitUnknown

    var errorDescription: String? {
        switch self {
        case .invalidURI: L10n.text("Enter a valid mongodb:// or mongodb+srv:// connection URI.")
        case .unsupportedURIOption: L10n.text("This URI contains an unsupported option. Portbase supports SCRAM authentication, primary reads, TLS, replica sets, and direct connections.")
        case .invalidSRVRecords: L10n.text("MongoDB DNS records are invalid or point outside the seed domain.")
        case .dnsLookupFailed: L10n.text("MongoDB DNS discovery failed. Check the SRV hostname and network connection.")
        case .primaryUnavailable: L10n.text("No writable MongoDB primary is available. Check the replica set and network connection, then retry.")
        case .replicaSetMismatch: L10n.text("The MongoDB server belongs to a different replica set.")
        case .transactionsUnavailable: L10n.text("Document editing requires MongoDB 4.2 or later with a transaction-capable replica set or sharded cluster. Standalone servers remain available for queries and imports.")
        case .documentChanged: L10n.text("This document changed or was deleted after it was loaded. No changes were saved. Reload it before editing again.")
        case .invalidDocument: L10n.text("Enter a valid BSON document with unique field names. Documents must fit within 16 MiB.")
        case .immutableIdentifier: L10n.text("The _id field cannot be changed when editing an existing document.")
        case .commitUnknown: L10n.text("MongoDB did not confirm the commit. Reload the collection to check the document before trying again.")
        }
    }
}

enum MongoConnectionURI {
    static func isValidProfile(_ profile: ConnectionProfile) -> Bool {
        (try? validateProfile(profile)) != nil
    }

    static func validateProfile(_ profile: ConnectionProfile) throws {
        // A URI belongs in the import field. Never serialize a credential-bearing URI as a hostname.
        guard !profile.host.contains("://"), !profile.host.contains("@"), !profile.host.contains("\0") else {
            throw MongoConnectionError.invalidURI
        }
        guard profile.engine == .mongodb else { return }
        let host = try MongoHostAddress.parse(profile.host.contains(":") ? "[\(profile.host)]:\(profile.port)" : "\(profile.host):\(profile.port)")
        let settings = profile.mongoConnection
        guard settings.additionalHosts.count < 32,
              !settings.directConnection || (!settings.usesSRV && settings.additionalHosts.isEmpty),
              settings.applicationName.utf8.count <= 128, !settings.applicationName.contains("\0"),
              settings.replicaSet.utf8.count <= 256, !settings.replicaSet.contains("\0"),
              ["DEFAULT", "SCRAM-SHA-1", "SCRAM-SHA-256"].contains(settings.authenticationMechanism) else { throw MongoConnectionError.invalidURI }
        if settings.usesSRV {
            guard !DatabaseService.isIPAddress(host.host), host.host.contains("."), host.port == 27017,
                  settings.additionalHosts.isEmpty else { throw MongoConnectionError.invalidURI }
        }
        for address in settings.additionalHosts { _ = try MongoHostAddress.parse(address.displayName) }
        guard Set([host] + settings.additionalHosts).count == settings.additionalHosts.count + 1 else { throw MongoConnectionError.invalidURI }
    }

    struct Parsed {
        let hosts: [MongoHostAddress]
        let username: String
        let password: String
        let database: String
        let authenticationDatabase: String
        let options: MongoConnectionOptions
        let tls: Bool?
        let requestedWriteRetries: Bool

        func applying(to profile: ConnectionProfile) -> ConnectionProfile {
            var updated = profile
            updated.engine = .mongodb
            updated.host = hosts[0].host
            updated.port = hosts[0].port
            updated.username = username
            updated.password = password
            updated.passwordWasExplicitlySet = true
            updated.defaultDatabase = database
            updated.authenticationDatabase = authenticationDatabase
            updated.mongoConnection = options
            if let tls {
                if tls { if updated.transportSecurityMode == .plaintext { updated.transportSecurityMode = .systemCA } }
                else { updated.transportSecurityMode = .plaintext }
            }
            return updated
        }
    }

    static func parse(_ source: String) throws -> Parsed {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 16_384, !text.contains("#"), !text.contains("\0") else { throw MongoConnectionError.invalidURI }
        let srv = text.hasPrefix("mongodb+srv://")
        let prefix = srv ? "mongodb+srv://" : "mongodb://"
        guard text.hasPrefix(prefix) else { throw MongoConnectionError.invalidURI }
        let remainder = text.dropFirst(prefix.count)
        let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? remainder.endIndex
        var authority = String(remainder[..<authorityEnd])
        let tail = String(remainder[authorityEnd...])
        var username = ""
        var password = ""
        if let at = authority.lastIndex(of: "@") {
            let credentials = authority[..<at]
            guard !credentials.contains("@"), let colon = credentials.firstIndex(of: ":") else { throw MongoConnectionError.invalidURI }
            username = try decode(String(credentials[..<colon]))
            password = try decode(String(credentials[credentials.index(after: colon)...]))
            guard !username.isEmpty else { throw MongoConnectionError.invalidURI }
            authority = String(authority[authority.index(after: at)...])
        }
        let hosts = try authority.split(separator: ",", omittingEmptySubsequences: false).map { try MongoHostAddress.parse(String($0)) }
        guard !hosts.isEmpty, hosts.count <= 32, Set(hosts).count == hosts.count else { throw MongoConnectionError.invalidURI }
        if srv {
            guard hosts.count == 1, !authority.contains(":"), !DatabaseService.isIPAddress(hosts[0].host), hosts[0].host.contains(".") else {
                throw MongoConnectionError.invalidURI
            }
        }
        let pieces = tail.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces.first ?? "")
        guard path.isEmpty || path.hasPrefix("/") else { throw MongoConnectionError.invalidURI }
        let database = try decode(path.isEmpty ? "" : String(path.dropFirst()))
        guard !database.contains("/"), !database.contains("\\"), !database.contains("\0") else { throw MongoConnectionError.invalidURI }
        let query = pieces.count == 2 ? try parseOptions(String(pieces[1])) : [:]
        let allowed: Set<String> = ["authsource", "replicaset", "tls", "ssl", "directconnection", "retrywrites", "w", "appname", "readpreference", "authmechanism"]
        guard Set(query.keys).isSubset(of: allowed), query["readpreference"].map({ $0 == "primary" }) ?? true,
              query["authmechanism"].map({ ["SCRAM-SHA-1", "SCRAM-SHA-256", "DEFAULT"].contains($0) }) ?? true,
              query["w"].map({ ["1", "majority"].contains($0) }) ?? true else { throw MongoConnectionError.unsupportedURIOption }
        let tlsValue = try boolean(query["tls"])
        let sslValue = try boolean(query["ssl"])
        guard tlsValue == nil || sslValue == nil || tlsValue == sslValue else { throw MongoConnectionError.invalidURI }
        let direct = try boolean(query["directconnection"]) ?? false
        guard !direct || (!srv && hosts.count == 1) else { throw MongoConnectionError.invalidURI }
        var options = MongoConnectionOptions()
        options.additionalHosts = Array(hosts.dropFirst())
        options.usesSRV = srv
        options.directConnection = direct
        options.replicaSet = query["replicaset"] ?? ""
        options.authenticationSourceIsExplicit = query["authsource"] != nil
        options.applicationName = query["appname"] ?? "Portbase"
        options.majorityWriteConcern = query["w"] == "majority"
        options.authenticationMechanism = query["authmechanism"] ?? "DEFAULT"
        guard options.applicationName.utf8.count <= 128, options.replicaSet.utf8.count <= 256 else { throw MongoConnectionError.invalidURI }
        let authenticationDatabase = query["authsource"] ?? (database.isEmpty ? "admin" : database)
        guard !authenticationDatabase.isEmpty else { throw MongoConnectionError.invalidURI }
        return Parsed(hosts: hosts, username: username, password: password, database: database,
                      authenticationDatabase: authenticationDatabase, options: options,
                      tls: tlsValue ?? sslValue ?? (srv ? true : nil), requestedWriteRetries: try boolean(query["retrywrites"]) ?? false)
    }

    static func parseOptions(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw MongoConnectionError.invalidURI }
            let key = try decode(String(parts[0])).lowercased()
            let value = try decode(String(parts[1]))
            guard !key.isEmpty, result[key] == nil else { throw MongoConnectionError.invalidURI }
            result[key] = value
        }
        return result
    }

    private static func decode(_ text: String) throws -> String {
        guard let value = text.removingPercentEncoding, !value.contains("\0") else { throw MongoConnectionError.invalidURI }
        return value
    }

    private static func boolean(_ value: String?) throws -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: throw MongoConnectionError.invalidURI
        }
    }
}
