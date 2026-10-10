import Foundation
import PostgresNIO

/// Turns driver and transport errors into messages a person can act on.
///
/// Some drivers hide their details behind a generic description to avoid leaking query
/// data. Connection failures carry no query text, so their codes and underlying
/// transport errors are shown; query text is never included.
enum DatabaseErrorFormatter {
    static func message(for error: Error) -> String {
        if let error = error as? PSQLError {
            if let message = error.serverInfo?[.message] {
                return L10n.format("Database error %@: %@", error.serverInfo?[.sqlState] ?? "", message)
            }
            let code = error.code.description
            if let underlying = error.underlying {
                return message(for: underlying) + " (PostgreSQL \(code))"
            }
            return L10n.format("PostgreSQL connection error: %@", code)
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        // A Swift error without a description bridges to an NSError whose domain is its own type name,
        // and the system shows only "… (Module.Type error N.)". Describe the error value itself instead.
        let bridged = error as NSError
        if bridged.userInfo[NSLocalizedDescriptionKey] == nil, bridged.domain == String(reflecting: type(of: error)) {
            return String(reflecting: error)
        }
        return error.localizedDescription
    }
}
