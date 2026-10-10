import Foundation

enum HTTPDatabaseAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic, apiKey, bearer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basic: L10n.text("Username and password")
        case .apiKey: L10n.text("API Key")
        case .bearer: L10n.text("Access Token")
        }
    }
}

enum HTTPDatabaseError: LocalizedError {
    case invalidRequest, unsupportedRequest, invalidResponse, responseTooLarge, redirectRefused
    case status(Int), unsupportedParameters, clickHouseFormat, unconfirmedWrite

    var errorDescription: String? {
        switch self {
        case .invalidRequest: L10n.text("Invalid database HTTP request. Check the method, path and JSON body.")
        case .unsupportedRequest: L10n.text("This database command is not supported. Use a query or an individual document operation.")
        case .invalidResponse: L10n.text("The database returned an incomplete or invalid JSON response.")
        case .responseTooLarge: L10n.text("The database response exceeds 32 MiB. Reduce the query size or select fewer fields.")
        case .redirectRefused: L10n.text("The database redirected the request. Set the final server address in the bookmark.")
        case .status(let code): L10n.format("The database returned HTTP %d. Check the request and server permissions.", code)
        case .unsupportedParameters: L10n.text("This engine does not support bound parameters in Portbase yet.")
        case .clickHouseFormat: L10n.text("Run one ClickHouse statement without FORMAT, SETTINGS or INTO OUTFILE. Portbase controls the result format and limits.")
        case .unconfirmedWrite: L10n.text("The write was not confirmed. Check the server before retrying; it may have completed.")
        }
    }
}

struct HTTPDatabaseResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
}
