import Foundation

extension DatabaseService {
    func scanRedisKeys(profile: ConnectionProfile, database: String, cursor: String,
                       pattern: Data?, type: String?, policy: DatabaseExecutionPolicy,
                       timeoutSeconds: Int = 30) async throws -> RedisScanPage {
        guard profile.engine == .redis else { throw DatabaseServiceError.unsupported }
        guard case .readOnly = policy else { throw DatabaseServiceError.readOnlyQueryRequired }
        try validateExecution(query: "SCAN 0", profile: profile, policy: policy, isReadOnly: true)
        return try await RedisDatabaseClient.scan(profile: profile, database: database, cursor: cursor, pattern: pattern,
            type: type, timeoutSeconds: max(1, min(timeoutSeconds, 300)), eventLoopGroup: eventLoopGroup)
    }

    func inspectRedisKey(profile: ConnectionProfile, database: String, key: RedisKey, cursor: String = "0",
                         policy: DatabaseExecutionPolicy, timeoutSeconds: Int = 30) async throws -> RedisKeyInspection {
        guard profile.engine == .redis else { throw DatabaseServiceError.unsupported }
        guard case .readOnly = policy else { throw DatabaseServiceError.readOnlyQueryRequired }
        try validateExecution(query: "TYPE key", profile: profile, policy: policy, isReadOnly: true)
        return try await RedisDatabaseClient.inspect(profile: profile, database: database, key: key, cursor: cursor,
            timeoutSeconds: max(1, min(timeoutSeconds, 300)), eventLoopGroup: eventLoopGroup)
    }
}
