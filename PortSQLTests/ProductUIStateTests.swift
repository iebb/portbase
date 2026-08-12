import CoreGraphics
import UIKit
import XCTest
@testable import PortSQL

final class ProductUIStateTests: XCTestCase {
    private let validPrivateCAPEM = """
    -----BEGIN CERTIFICATE-----
    MIICFjCCAX+gAwIBAgIUDKFGUNWvOdqmYUQGa9tw7REda+0wDQYJKoZIhvcNAQEL
    BQAwHTEbMBkGA1UEAwwSUG9ydFNRTCBVSSBUZXN0IENBMB4XDTI2MDgxMjE0MDQ0
    NFoXDTI2MDgxMzE0MDQ0NFowHTEbMBkGA1UEAwwSUG9ydFNRTCBVSSBUZXN0IENB
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDD55vbazKByF2tsgnj24jCM5r3
    xHG4neDBLJcqfTdO4ZyxFDj/I6LdLsD8XWs4a4E6PRSuSOkYeSvTk9Fdec0fCOiQ
    O+1IuJfiH/IN1bddnhzUuvnvwd0/dG0k91tjWdtQ+Xi3XMH0MScCso0o8OukfQC9
    3KOUmH+vTbiFBFto1QIDAQABo1MwUTAdBgNVHQ4EFgQU3w/7N1N8zHayhCDIDedG
    nMLiw5owHwYDVR0jBBgwFoAU3w/7N1N8zHayhCDIDedGnMLiw5owDwYDVR0TAQH/
    BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOBgQAu1UO7HcXMPZh/VwJkov/OqtkD9WsY
    NQ69e1BdH5yR10truk0H6mkHeJ00VwZ2WdmzV22ccPgdvRJqptf+qIFLCuKQa8wD
    FZx745o1KlLmJunwUX7jS0vZnHk+LWtVl735dVht3YOqqjksCkGHPdhYDSQdKlom
    JntzCqPMRqxybQ==
    -----END CERTIFICATE-----
    """

    func testSavedChartStateResolvesEveryTerminalState() {
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: false,
                isRunning: false,
                hasPreview: false,
                error: nil,
                hasSourceQuery: true,
                hasConnection: true
            ),
            .loading
        )
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: true,
                isRunning: false,
                hasPreview: true,
                error: nil,
                hasSourceQuery: true,
                hasConnection: true
            ),
            .content
        )
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: true,
                isRunning: false,
                hasPreview: false,
                error: nil,
                hasSourceQuery: false,
                hasConnection: true
            ),
            .missingQuery
        )
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: true,
                isRunning: false,
                hasPreview: false,
                error: nil,
                hasSourceQuery: true,
                hasConnection: false
            ),
            .missingConnection
        )
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: true,
                isRunning: false,
                hasPreview: false,
                error: nil,
                hasSourceQuery: true,
                hasConnection: true
            ),
            .idle
        )
        XCTAssertEqual(
            SavedChartPreviewState.resolve(
                hasResolvedInitialState: true,
                isRunning: false,
                hasPreview: false,
                error: "Offline",
                hasSourceQuery: true,
                hasConnection: true
            ),
            .failed("Offline")
        )
    }

    func testResultGridExpandsColumnsToFillWideContainers() {
        let expanded = ResultGridLayout.expandedWidths(
            naturalWidths: [100, 140],
            availableWidth: 416
        )

        XCTAssertEqual(expanded, [180, 220])
        XCTAssertFalse(ResultGridLayout.needsHorizontalScrolling(widths: expanded, availableWidth: 416))
    }

    func testResultGridPreservesNaturalWidthsWhenHorizontalScrollingIsRequired() {
        let natural: [CGFloat] = [180, 220, 160]

        XCTAssertEqual(
            ResultGridLayout.expandedWidths(naturalWidths: natural, availableWidth: 390),
            natural
        )
        XCTAssertTrue(ResultGridLayout.needsHorizontalScrolling(widths: natural, availableWidth: 390))
    }

    func testResultGridAccessibilityNamesHeadersAndRowValues() {
        let columns = [
            QueryColumn(name: "id", type: "integer"),
            QueryColumn(name: "nickname", type: "text")
        ]

        XCTAssertEqual(
            ResultGridAccessibility.headerValue(
                column: columns[0],
                isPrimaryKey: true,
                sortDirection: "DESC"
            ),
            "integer, primary key, sorted descending"
        )
        XCTAssertEqual(
            ResultGridAccessibility.rowLabel(columns: columns, cells: [.integer("42"), .text("")]),
            "id: 42, nickname: empty string"
        )
        XCTAssertEqual(
            ResultGridAccessibility.rowLabel(columns: columns, cells: [.integer("42"), .null]),
            "id: 42, nickname: NULL"
        )
    }

    func testSQLEditorTypographyScalesForAccessibilityContentSizes() {
        let regularTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)

        XCTAssertGreaterThan(
            SQLEditorTypography.queryFont(compatibleWith: accessibilityTraits).pointSize,
            SQLEditorTypography.queryFont(compatibleWith: regularTraits).pointSize
        )
        XCTAssertGreaterThan(
            SQLEditorTypography.clauseFont(compatibleWith: accessibilityTraits).pointSize,
            SQLEditorTypography.clauseFont(compatibleWith: regularTraits).pointSize
        )
    }

    func testTransportSecuritySaveGatingRequiresAValidPrivateCAOnlyInPrivateCAMode() {
        XCTAssertTrue(
            TransportSecurityEditorState.canSave(
                host: "db.example.com",
                mode: .systemCA,
                privateCACertificate: ""
            )
        )
        XCTAssertTrue(
            TransportSecurityEditorState.canSave(
                host: "db.example.com",
                mode: .preferTLS,
                privateCACertificate: ""
            )
        )
        XCTAssertTrue(
            TransportSecurityEditorState.canSave(
                host: "db.example.com",
                mode: .plaintext,
                privateCACertificate: ""
            )
        )
        XCTAssertFalse(
            TransportSecurityEditorState.canSave(
                host: "db.example.com",
                mode: .privateCA,
                privateCACertificate: ""
            )
        )
        XCTAssertTrue(
            TransportSecurityEditorState.canSave(
                host: "db.example.com",
                mode: .privateCA,
                privateCACertificate: validPrivateCAPEM
            )
        )
        XCTAssertFalse(
            TransportSecurityEditorState.canSave(
                host: "   ",
                mode: .systemCA,
                privateCACertificate: validPrivateCAPEM
            )
        )
    }

    func testPrivateCAValidationRejectsPrivateKeysAndImportsPEMOrBinaryDER() throws {
        XCTAssertTrue(TransportSecurityEditorState.isValidPrivateCACertificate(validPrivateCAPEM))
        XCTAssertFalse(
            TransportSecurityEditorState.isValidPrivateCACertificate(
                "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
            )
        )

        let importedPEM = try XCTUnwrap(
            TransportSecurityEditorState.pemEncodedCertificate(from: Data(validPrivateCAPEM.utf8))
        )
        XCTAssertEqual(
            importedPEM.trimmingCharacters(in: .whitespacesAndNewlines),
            validPrivateCAPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let base64 = validPrivateCAPEM
            .split(separator: "\n")
            .dropFirst()
            .dropLast()
            .joined()
        let binaryDER = try XCTUnwrap(Data(base64Encoded: base64))
        let convertedDER = try XCTUnwrap(
            TransportSecurityEditorState.pemEncodedCertificate(from: binaryDER)
        )
        XCTAssertTrue(TransportSecurityEditorState.isValidPrivateCACertificate(convertedDER))
        XCTAssertTrue(convertedDER.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(convertedDER.hasSuffix("-----END CERTIFICATE-----\n"))

        XCTAssertNil(
            TransportSecurityEditorState.pemEncodedCertificate(
                from: Data(repeating: 0, count: TransportSecurityEditorState.maximumCertificateSize + 1)
            )
        )
    }
}
