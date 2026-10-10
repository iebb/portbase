import XCTest
@testable import PortSQL

private enum OpaqueTLSError: Error { case handshakeFailed(String) }

final class ConnectionImportAndIssueTests: XCTestCase {
    func testFormatterExpandsErrorsWithoutDescriptions() {
        // Errors such as NIOSSLError only describe themselves as "… (Module.Type error N.)".
        let message = DatabaseErrorFormatter.message(for: OpaqueTLSError.handshakeFailed("SSL routines:CERTIFICATE_VERIFY_FAILED"))
        XCTAssertFalse(message.contains("couldn’t be completed"))
        XCTAssertTrue(message.contains("CERTIFICATE_VERIFY_FAILED"))
        XCTAssertEqual(ConnectionIssue.classify(message).kind, .certificateUntrusted)
        XCTAssertEqual(DatabaseErrorFormatter.message(for: ConnectionStringError.invalid), ConnectionStringError.invalid.errorDescription)
    }

    private func blank(_ engine: DatabaseEngine = .postgresql) -> ConnectionProfile {
        ConnectionProfile(name: "", engine: engine, iconName: nil, host: "", port: engine.defaultPort,
                          username: "", password: "", defaultDatabase: "")
    }

    func testPostgresURLFillsEndpointCredentialsAndDatabase() throws {
        let result = try ConnectionStringImporter.apply("postgresql://app%40corp:p%3Ass%2Fword@db.example.com:6543/orders?sslmode=verify-full&application_name=x", to: blank(.mysql))
        let profile = result.profile
        XCTAssertEqual(profile.engine, .postgresql)
        XCTAssertEqual(profile.host, "db.example.com")
        XCTAssertEqual(profile.port, 6543)
        XCTAssertEqual(profile.username, "app@corp", "Credentials are percent-decoded")
        XCTAssertEqual(profile.password, "p:ss/word")
        XCTAssertTrue(profile.passwordWasExplicitlySet)
        XCTAssertEqual(profile.defaultDatabase, "orders")
        XCTAssertEqual(profile.transportSecurityMode, .systemCA)
        XCTAssertEqual(profile.name, "orders @ db.example.com")
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testImportNeverEnablesPlaintextOrFallback() throws {
        for source in ["postgres://u@h/db?sslmode=disable", "mysql://u@h/db?ssl=false", "redis://h:6379/2", "postgres://u@h/db?sslmode=prefer"] {
            let result = try ConnectionStringImporter.apply(source, to: blank())
            XCTAssertEqual(result.profile.transportSecurityMode, .systemCA, source)
            XCTAssertFalse(result.notices.isEmpty, "A notice explains the kept TLS requirement for \(source)")
        }
        var legacy = blank(.mysql)
        legacy.transportSecurityMode = .plaintext
        XCTAssertEqual(try ConnectionStringImporter.apply("mysql://h/db?ssl-mode=REQUIRED", to: legacy).profile.transportSecurityMode, .systemCA,
                       "A string that requires TLS upgrades an existing plaintext profile")
    }

    func testMongoImportKeepsTLSWhenTheStringDisablesIt() throws {
        let result = try ConnectionStringImporter.apply("mongodb://u:p@m1.example.com:27018/app?tls=false&retryWrites=true", to: blank())
        XCTAssertEqual(result.profile.engine, .mongodb)
        XCTAssertEqual(result.profile.port, 27018)
        XCTAssertEqual(result.profile.transportSecurityMode, .systemCA)
        XCTAssertEqual(result.notices.count, 2)
    }

    func testJDBCRedisAndHTTPEngines() throws {
        let mariadb = try ConnectionStringImporter.apply("jdbc:mariadb://[::1]/shop", to: blank())
        XCTAssertEqual(mariadb.profile.engine, .mariadb)
        XCTAssertEqual(mariadb.profile.host, "::1")
        XCTAssertEqual(mariadb.profile.port, 3306)

        let redis = try ConnectionStringImporter.apply("rediss://:secret@cache.example.com/3", to: blank())
        XCTAssertEqual(redis.profile.engine, .redis)
        XCTAssertEqual(redis.profile.defaultDatabase, "3")
        XCTAssertEqual(redis.profile.password, "secret")
        XCTAssertThrowsError(try ConnectionStringImporter.apply("redis://h/notanumber", to: blank()))

        let clickhouse = try ConnectionStringImporter.apply("https://ch.example.com", to: blank(.clickhouse))
        XCTAssertEqual(clickhouse.profile.port, 8443)
        XCTAssertThrowsError(try ConnectionStringImporter.apply("https://ch.example.com", to: blank(.postgresql)),
                             "Plain HTTPS URLs need an HTTP engine to be chosen first")
    }

    func testRejectsUnsupportedAndMalformedStrings() {
        XCTAssertEqual(try? ConnectionStringImporter.apply("", to: blank()).profile.host, nil)
        XCTAssertThrowsError(try ConnectionStringImporter.apply("oracle://h/db", to: blank())) { error in
            XCTAssertEqual(error as? ConnectionStringError, .unsupportedScheme("oracle"))
        }
        XCTAssertThrowsError(try ConnectionStringImporter.apply("sqlite:///tmp/x.db", to: blank()))
        XCTAssertThrowsError(try ConnectionStringImporter.apply("postgres://h1,h2/db", to: blank()))
        XCTAssertThrowsError(try ConnectionStringImporter.apply("postgres://h:70000/db", to: blank()))
        XCTAssertTrue(ConnectionStringImporter.looksLikeConnectionString("jdbc:postgresql://h/db"))
        XCTAssertFalse(ConnectionStringImporter.looksLikeConnectionString("SELECT 1"))
    }

    func testIgnoredOptionsAreNamedWithoutValues() throws {
        let result = try ConnectionStringImporter.apply("postgres://h/db?token=secret-value&pool=5", to: blank())
        let notice = try XCTUnwrap(result.notices.first)
        XCTAssertTrue(notice.contains("token") && notice.contains("pool"))
        XCTAssertFalse(notice.contains("secret-value"))
    }

    func testClassifiesTLSAndConnectionFailures() {
        let cases: [(String, ConnectionIssue.Kind)] = [
            ("handshakeFailed(NIOSSL.BoringSSLError.sslError([error:1000007d:SSL routines:OPENSSL_internal:CERTIFICATE_VERIFY_FAILED]))", .certificateUntrusted),
            ("NIOSSLExtraError.failedToValidateHostname: Couldn't find db.internal in certificate from peer", .certificateHostname),
            ("The certificate for this server is invalid.", .certificateUntrusted),
            ("certificate has expired", .certificateExpired),
            ("PSQLError(code: sslUnsupported)", .tlsUnavailable),
            ("error:100000f7:SSL routines:OPENSSL_internal:WRONG_VERSION_NUMBER", .tlsHandshake),
            ("password authentication failed for user \"app\" (28P01)", .authentication),
            ("connect(descriptor:addr:size:): Connection refused (errno: 61)", .unreachable),
            ("The database query timed out and its connection was closed.", .timeout),
            ("column \"ssl_mode\" does not exist", .other),
            ("syntax error at or near \"password\"", .other),
        ]
        for (message, kind) in cases {
            XCTAssertEqual(ConnectionIssue.classify(message).kind, kind, message)
        }
        XCTAssertTrue(ConnectionIssue.classify("CERTIFICATE_VERIFY_FAILED").isSecurityIssue)
        XCTAssertEqual(ConnectionIssue.classify("raw text").details, "raw text")
    }
}
