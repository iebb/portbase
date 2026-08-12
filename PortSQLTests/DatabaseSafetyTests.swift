import XCTest
@testable import PortSQL

#if canImport(NIOSSL)
import NIOSSL
#endif

final class DatabaseSafetyTests: XCTestCase {
    private let validCertificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIDEzCCAfugAwIBAgIURiMaUmhI1Xr0mZ4p+JmI0XjZTaIwDQYJKoZIhvcNAQEL
    BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTE3MTAzMDEyMDUwMFoXDTQwMDEw
    MTAwMDAwMFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
    AAOCAQ8AMIIBCgKCAQEA26DcKAxqdWivhS/J3Klf+cEnrT2cDzLhmVRCHuQZXiIr
    tqr5401KDbRTVOg8v2qIyd8x4+YbpE47JP3fBrcMey70UK/Er8nu28RY3z7gZLLi
    Yf+obHdDFCK5JaCGmM61I0c0vp7aMXsyv7h3vjEzTuBMlKR8p37ftaXSUAe3Qk/D
    /fzA3k02E2e3ap0Sapd/wUu/0n/MFyy9HkkeykivAzLaaFhhvp3hATdFYC4FLld8
    OMB60bC2S13CAljpMlpjU/XLLOUbaPgnNUqE1nFqFBoTl6kV6+ii8Dd5ENVvE7pE
    SoNoyGLDUkDRJJMNUHAo0zbxyhd7WOtyZ7B4YBbPswIDAQABo10wWzBLBgNVHREE
    RDBCgglsb2NhbGhvc3SCC2V4YW1wbGUuY29tgRB1c2VyQGV4YW1wbGUuY29thwTA
    qAABhxAgAQ24AAAAAAAAAAAAAAABMAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQEL
    BQADggEBACYBArIoL9ZzVX3M+WmTD5epmGEffrH7diRJZsfpVXi86brBPrbvpTBx
    Fa+ZKxBAchPnWn4rxoWVJmTm4WYqZljek7oQKzidu88rMTbsxHA+/qyVPVlQ898I
    hgnW4h3FFapKOFqq5Hj2gKKItFIcGoVY2oLTBFkyfAx0ofromGQp3fh58KlPhC0W
    GX1nFCea74mGyq60X86aEWiyecYYj5AEcaDrTnGg3HLGTsD3mh8SUZPAda13rO4+
    RGtGsA1C9Yovlu9a6pWLgephYJ73XYPmRIGgM64fkUbSuvXNJMYbWnzpoCdW6hka
    IEaDUul/WnIkn/JZx8n+wgoWtyQa4EA=
    -----END CERTIFICATE-----
    """

    func testTransportSecurityLegacyMigrationAndSecureDefault() throws {
        let decoder = JSONDecoder()
        let base = #"{"name":"DB","engine":"PostgreSQL","host":"db.example.com","port":5432,"username":"u","password":"","database":"db"}"#
        let plaintext = #"{"name":"DB","engine":"PostgreSQL","host":"db.example.com","port":5432,"username":"u","password":"","database":"db","usesTLS":false}"#

        XCTAssertEqual(try decoder.decode(ConnectionProfile.self, from: Data(base.utf8)).transportSecurityMode, .systemCA)
        XCTAssertEqual(try decoder.decode(ConnectionProfile.self, from: Data(plaintext.utf8)).transportSecurityMode, .plaintext)
    }

    func testEveryTransportSecurityModeRoundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in TransportSecurityMode.allCases {
            let profile = ConnectionProfile(
                name: "Database",
                engine: .postgresql,
                host: "db.example.com",
                port: 5432,
                username: "app",
                password: "",
                database: "app",
                transportSecurityMode: mode
            )

            let decoded = try decoder.decode(ConnectionProfile.self, from: encoder.encode(profile))
            XCTAssertEqual(decoded.transportSecurityMode, mode)
            XCTAssertEqual(decoded.usesTLS, mode != .plaintext)
        }
    }

    #if canImport(NIOSSL)
    func testPrivateCATLSAddsParsedCertificateToSystemRoots() throws {
        let profile = ConnectionProfile(
            name: "Private CA",
            engine: .postgresql,
            host: "db.example.com",
            port: 5432,
            username: "app",
            password: "",
            database: "app",
            transportSecurityMode: .privateCA,
            privateCACertificate: validCertificatePEM
        )

        let configuration = try DatabaseService.tlsConfiguration(for: profile)
        XCTAssertEqual(configuration.certificateVerification, .fullVerification)
        XCTAssertEqual(configuration.trustRoots, .default)
        XCTAssertEqual(configuration.additionalTrustRoots.count, 1)
    }

    func testPrivateCATLSRejectsMissingInvalidAndPrivateKeyMaterial() {
        for pem in ["", "not a certificate", "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----"] {
            let profile = ConnectionProfile(
                name: "Private CA",
                engine: .mysql,
                host: "db.example.com",
                port: 3306,
                username: "app",
                password: "",
                database: "app",
                transportSecurityMode: .privateCA,
                privateCACertificate: pem
            )
            XCTAssertThrowsError(try DatabaseService.tlsConfiguration(for: profile))
        }
    }
    #endif
    func testPostgresColumnEditPlanQuotesIdentifiersAndPreservesRenameCase() throws {
        let original = SchemaColumnDescriptor(
            name: "DisplayName",
            type: "VARCHAR(80)",
            isNullable: true,
            isPrimaryKey: false,
            isUnique: false
        )
        let table = SchemaTableDescriptor(
            schemaName: "Sales Data",
            name: "Order",
            columns: [original],
            rowCountEstimate: nil
        )
        let draft = SchemaColumnDraft(
            mode: .edit,
            table: table,
            originalColumn: original,
            name: "displayName",
            type: "VARCHAR(120)",
            isNullable: false
        )

        let plan = try DatabaseService.schemaColumnChangePlan(for: draft, engine: .postgresql)

        XCTAssertEqual(plan.statements.count, 3)
        XCTAssertTrue(plan.previewSQL.contains("ALTER TABLE \"Sales Data\".\"Order\""))
        XCTAssertTrue(plan.previewSQL.contains("RENAME COLUMN \"DisplayName\" TO \"displayName\""))
        XCTAssertTrue(plan.previewSQL.contains("ALTER COLUMN \"displayName\" TYPE VARCHAR(120)"))
        XCTAssertTrue(plan.previewSQL.contains("ALTER COLUMN \"displayName\" SET NOT NULL"))
    }

    func testUnsafeSchemaTypeIsRejectedBeforeDDLExecution() {
        let table = SchemaTableDescriptor(
            schemaName: "public",
            name: "users",
            columns: [],
            rowCountEstimate: nil
        )
        let draft = SchemaColumnDraft(
            mode: .add,
            table: table,
            originalColumn: nil,
            name: "nickname",
            type: "TEXT; DROP TABLE users",
            isNullable: true
        )

        XCTAssertThrowsError(
            try DatabaseService.schemaColumnChangePlan(for: draft, engine: .postgresql)
        ) { error in
            guard case DatabaseServiceError.invalidSchemaDefinition = error else {
                return XCTFail("Expected invalidSchemaDefinition, received \(error)")
            }
        }
    }

    func testMySQLExistingColumnEditFailsClosedWithoutCompleteMetadata() {
        let original = SchemaColumnDescriptor(
            name: "total",
            type: "DECIMAL(10,2)",
            isNullable: false,
            isPrimaryKey: false,
            isUnique: false
        )
        let table = SchemaTableDescriptor(
            schemaName: "shop",
            name: "orders",
            columns: [original],
            rowCountEstimate: nil
        )
        let draft = SchemaColumnDraft(
            mode: .edit,
            table: table,
            originalColumn: original,
            name: "total",
            type: "DECIMAL(12,2)",
            isNullable: false
        )

        XCTAssertThrowsError(
            try DatabaseService.schemaColumnChangePlan(for: draft, engine: .mysql)
        ) { error in
            guard case DatabaseServiceError.mysqlColumnEditRequiresCompleteMetadata = error else {
                return XCTFail("Expected fail-closed MySQL edit error, received \(error)")
            }
        }
    }

    func testDropPlanQuotesEmbeddedIdentifierDelimiters() {
        let column = SchemaColumnDescriptor(
            name: "strange`column",
            type: "TEXT",
            isNullable: true,
            isPrimaryKey: false,
            isUnique: false
        )
        let table = SchemaTableDescriptor(
            schemaName: "app",
            name: "users",
            columns: [column],
            rowCountEstimate: nil
        )

        let plan = DatabaseService.dropColumnPlan(column, from: table, engine: .mysql)

        XCTAssertEqual(
            plan.previewSQL,
            "ALTER TABLE `app`.`users`\nDROP COLUMN `strange``column`;"
        )
    }
}
