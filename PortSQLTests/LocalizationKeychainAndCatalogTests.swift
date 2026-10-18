import XCTest
@testable import PortSQL

final class LocalizationKeychainAndCatalogTests: XCTestCase {
    private let locales = ["en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans", "zh-Hant"]
    private let nonEnglishLocales = ["de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans", "zh-Hant"]

    func testAppShipsExpectedLocalizationBundlesWithMatchingLocalizableKeys() throws {
        let baseline = try localizableStrings(for: "en")

        XCTAssertFalse(baseline.isEmpty)
        for locale in locales {
            let strings = try localizableStrings(for: locale)
            XCTAssertEqual(Set(strings.keys), Set(baseline.keys), "Missing or extra Localizable.strings keys for \(locale)")
        }
    }

    func testLocalizedCatalogsContainNoMojibakeControlCharactersOrPipelineArtifacts() throws {
        let localeSpecificMojibakeMarkers: [String: [String]] = [
            "de": ["Ã", "Â"],
            "es": ["Ã", "Â"],
            "fr": ["Ã", "Â", "â€"],
            "ja": ["ã‚", "ãƒ", "æ", "ç"],
            "ko": ["ì", "ë", "í", "ê"],
            "pt-BR": ["Ã", "Â"],
            "ru": ["Ð", "Ñ"],
            "zh-Hans": ["ä", "å", "æ", "ç"],
            "zh-Hant": ["ä", "å", "æ", "ç"],
        ]
        let universalArtifacts = ["�", "ðŸ", "ZXQTOKEN", "[[", "]]" ]

        for locale in locales {
            for (key, value) in try localizableStrings(for: locale) {
                XCTAssertFalse(value.isEmpty, "Empty localization for \(locale): \(key)")

                let disallowedControlScalars = value.unicodeScalars.filter { scalar in
                    let codePoint = scalar.value
                    let isControl = codePoint < 0x20 || (0x7F ... 0x9F).contains(codePoint)
                    return isControl && codePoint != 0x09 && codePoint != 0x0A
                }
                XCTAssertTrue(
                    disallowedControlScalars.isEmpty,
                    "Control characters in \(locale): \(key) = \(value)"
                )

                for artifact in universalArtifacts + (localeSpecificMojibakeMarkers[locale] ?? []) {
                    XCTAssertFalse(
                        value.contains(artifact),
                        "Encoding or translation-pipeline artifact '\(artifact)' in \(locale): \(key) = \(value)"
                    )
                }
            }
        }
    }

    func testLocalizedCatalogsPreserveFormatPlaceholders() throws {
        let baseline = try localizableStrings(for: "en")

        for locale in nonEnglishLocales {
            let strings = try localizableStrings(for: locale)
            for (key, baselineValue) in baseline {
                XCTAssertEqual(
                    formatPlaceholderTypes(in: strings[key] ?? ""),
                    formatPlaceholderTypes(in: baselineValue),
                    "Format placeholders changed for \(locale): \(key)"
                )
            }
        }
    }

    func testPluralCatalogsDefineEveryRuntimePluralWithSemanticForms() throws {
        let expectedKeys: Set<String> = ["column_count", "column_count_short", "row_count", "metric_count", "connection_count"]

        for locale in locales {
            let catalog = try localizablePluralRules(for: locale)
            XCTAssertEqual(Set(catalog.keys), expectedKeys, "Missing or extra plural keys for \(locale)")

            for key in expectedKeys {
                let entry = try XCTUnwrap(catalog[key] as? [String: Any], "Missing plural entry \(key) for \(locale)")
                let format = try XCTUnwrap(entry["NSStringLocalizedFormatKey"] as? String)
                let variableName = try XCTUnwrap(pluralVariableName(in: format), "Invalid plural format for \(locale): \(key)")
                let rules = try XCTUnwrap(entry[variableName] as? [String: String])

                XCTAssertEqual(rules["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
                XCTAssertEqual(rules["NSStringFormatValueTypeKey"], "d")
                XCTAssertTrue(rules["other"]?.contains("%d") == true, "Missing numeric 'other' rule for \(locale): \(key)")
                XCTAssertFalse(rules["one"]?.isEmpty ?? true, "Missing singular rule for \(locale): \(key)")
            }
        }

        let russianRows = try pluralForms(for: "row_count", locale: "ru")
        XCTAssertEqual(russianRows["one"], "%d строка")
        XCTAssertEqual(russianRows["few"], "%d строки")
        XCTAssertEqual(russianRows["many"], "%d строк")
    }

    func testNonEnglishCatalogsHaveNoUnexpectedEnglishIdentityFallbacks() throws {
        let baseline = try localizableStrings(for: "en")
        let universallyInvariantKeys: Set<String> = [
            "PORTBASE", "Portbase", "iCloud", "WHERE", "ORDER", "SQL", "DDL", "Portbase Pro", "JSON", "NULL", "PK",
        ]
        let localeSpecificInvariantKeys: [String: Set<String>] = [
            "de": ["FORMAT", "EXPLAIN", "SCHEMA", "Server", "Name", "Host", "Port", "Auto", "Filter", "Staging", "Orange", "Indigo"],
            "es": ["Host", "Auto", "No", "Color"],
            "fr": ["Mode", "Port", "Page %d", "Auto", "Date", "Production", "Orange", "Indigo"],
            "ja": [],
            "ko": [],
            "pt-BR": ["Host", "Auto"],
            "ru": ["EXPLAIN"],
            "zh-Hans": [],
            "zh-Hant": [],
        ]
        let maximumUnexpectedIdentityFallbacks = 0

        for locale in nonEnglishLocales {
            let strings = try localizableStrings(for: locale)
            let allowed = universallyInvariantKeys.union(localeSpecificInvariantKeys[locale] ?? [])
            let unexpectedFallbacks = strings.compactMap { key, value -> String? in
                guard value == baseline[key], !allowed.contains(key) else { return nil }
                return key
            }.sorted()

            XCTAssertLessThanOrEqual(
                unexpectedFallbacks.count,
                maximumUnexpectedIdentityFallbacks,
                "Unexpected English identity fallbacks in \(locale): \(unexpectedFallbacks.joined(separator: ", "))"
            )
        }
    }

    func testKeychainStoresUpdatesAndDeletesConnectionSecrets() {
        let profileID = UUID()
        defer { KeychainService.deleteAllSecrets(for: profileID) }

        KeychainService.setPassword("first", for: profileID)
        XCTAssertEqual(KeychainService.password(for: profileID), "first")

        KeychainService.setPassword("second", for: profileID)
        XCTAssertEqual(KeychainService.password(for: profileID), "second")

        KeychainService.setSecret("ssh-secret", kind: .sshPassword, for: profileID)
        XCTAssertEqual(KeychainService.secret(.sshPassword, for: profileID), "ssh-secret")

        KeychainService.setSecret("private-ca", kind: .privateCACertificate, for: profileID)
        XCTAssertEqual(KeychainService.secret(.privateCACertificate, for: profileID), "private-ca")

        KeychainService.deleteAllSecrets(for: profileID)
        XCTAssertEqual(KeychainService.password(for: profileID), "")
        XCTAssertEqual(KeychainService.secret(.sshPassword, for: profileID), "")
        XCTAssertEqual(KeychainService.secret(.privateCACertificate, for: profileID), "")
    }

    func testConnectionProfileEncodingOmitsPlaintextSecrets() throws {
        let profile = ConnectionProfile(
            name: "Production",
            engine: .postgresql,
            host: "db.example.com",
            port: 5432,
            username: "app",
            password: "database-secret",
            database: "app",
            transportSecurityMode: .privateCA,
            privateCACertificate: "CA CERTIFICATE SECRET",
            usesSSHTunnel: true,
            sshHost: "bastion.example.com",
            sshUsername: "deploy",
            sshPassword: "ssh-secret",
            sshPrivateKey: "PRIVATE KEY",
            sshPassphrase: "passphrase"
        )

        let json = String(data: try JSONEncoder().encode(profile), encoding: .utf8) ?? ""

        XCTAssertFalse(json.contains("database-secret"))
        XCTAssertFalse(json.contains("ssh-secret"))
        XCTAssertFalse(json.contains("PRIVATE KEY"))
        XCTAssertFalse(json.contains("passphrase"))
        XCTAssertFalse(json.contains("CA CERTIFICATE SECRET"))
        XCTAssertTrue(json.contains("<keychain>"))
    }

    private func localizableStrings(for locale: String) throws -> [String: String] {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: locale
            ),
            "Missing Localizable.strings for \(locale)"
        )
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        return dictionary
    }

    private func localizablePluralRules(for locale: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "Localizable",
                withExtension: "stringsdict",
                subdirectory: nil,
                localization: locale
            ),
            "Missing Localizable.stringsdict for \(locale)"
        )
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    }

    private func pluralForms(for key: String, locale: String) throws -> [String: String] {
        let catalog = try localizablePluralRules(for: locale)
        let entry = try XCTUnwrap(catalog[key] as? [String: Any])
        let format = try XCTUnwrap(entry["NSStringLocalizedFormatKey"] as? String)
        let variableName = try XCTUnwrap(pluralVariableName(in: format))
        return try XCTUnwrap(entry[variableName] as? [String: String])
    }

    private func pluralVariableName(in format: String) -> String? {
        let pattern = #"%#@([^@]+)@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(format.startIndex ..< format.endIndex, in: format)
        guard let match = regex.firstMatch(in: format, range: range),
              let captureRange = Range(match.range(at: 1), in: format) else {
            return nil
        }
        return String(format[captureRange])
    }

    private func formatPlaceholderTypes(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(lld|ld|@|d|f)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)

        return regex.matches(in: value, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[captureRange])
        }.sorted()
    }
}
