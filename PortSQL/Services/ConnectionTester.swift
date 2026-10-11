import Foundation

/// Verifies a profile before it is saved, using only read-only requests.
enum ConnectionTester {
    struct Success: Equatable {
        let duration: TimeInterval
        let databaseCount: Int?
    }

    static func test(_ profile: ConnectionProfile) async throws -> Success {
        let started = ProcessInfo.processInfo.systemUptime
        let count: Int?
        if profile.engine == .redis {
            // Redis database numbers are configured, not listed, so ask the server directly.
            _ = try await DatabaseService.shared.execute(query: "PING", profile: profile,
                                                         database: profile.trimmedDefaultDatabase.isEmpty ? "0" : profile.trimmedDefaultDatabase,
                                                         policy: .readOnly)
            count = nil
        } else {
            count = try await DatabaseService.shared.listDatabases(profile: profile).count
        }
        return Success(duration: max(0, ProcessInfo.processInfo.systemUptime - started), databaseCount: count)
    }

    static func summary(_ success: Success) -> String {
        let time = WorkspaceActivityService.durationLabel(success.duration)
        guard let count = success.databaseCount else { return L10n.format("Connected in %@.", time) }
        return L10n.format("Connected in %@. Databases: %d", time, count)
    }
}
