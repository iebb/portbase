import Foundation

enum ElasticsearchQueryService {
    static func parse(_ text: String) throws -> ElasticsearchCommand {
        let json: HTTPJSONValue
        do { json = try HTTPJSONValue.parse(text) }
        catch { throw HTTPDatabaseError.invalidRequest }
        guard let fields = json.object, Set(fields.keys).isSubset(of: ["method", "path", "body"]),
              let method = fields["method"]?.string, ["GET", "POST", "PUT", "DELETE"].contains(method),
              let path = fields["path"]?.string, path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("%"), !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              fields["body"] == nil || fields["body"]?.object != nil else { throw HTTPDatabaseError.invalidRequest }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path == "/" || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw HTTPDatabaseError.invalidRequest }
        let body = fields["body"]
        let readOnly: Bool
        if method == "GET", path == "/" { readOnly = true }
        else if ["GET", "POST"].contains(method), readEndpoint(parts, method: method) { readOnly = true }
        else if writeEndpoint(parts, method: method) { readOnly = false }
        else { throw HTTPDatabaseError.unsupportedRequest }
        if readOnly, let body, containsUnsupportedExecution(body) { throw HTTPDatabaseError.unsupportedRequest }
        if method == "DELETE", body?.object?.isEmpty == false { throw HTTPDatabaseError.invalidRequest }
        if parts.contains("_update"), let object = body?.object {
            guard Set(object.keys).isSubset(of: ["doc", "doc_as_upsert", "upsert", "detect_noop"]),
                  object["doc"]?.object != nil || object["upsert"]?.object != nil else { throw HTTPDatabaseError.unsupportedRequest }
        }
        return ElasticsearchCommand(method: method, path: path, body: body, isReadOnly: readOnly)
    }

    private static func readEndpoint(_ parts: [String], method: String) -> Bool {
        let queryEndpoints: Set<String> = ["_search", "_count", "_field_caps"]
        if parts.count == 1, queryEndpoints.contains(parts[0]) { return true }
        if parts.count == 2, validIndex(parts[0], allowPattern: true), queryEndpoints.contains(parts[1]) { return true }
        if method == "GET", parts == ["_mapping"] { return true }
        if method == "GET", parts.count == 2, validIndex(parts[0], allowPattern: true), parts[1] == "_mapping" { return true }
        if method == "GET", parts.count == 3, validIndex(parts[0], allowPattern: false), ["_doc", "_source"].contains(parts[1]) { return true }
        if parts.count == 3, validIndex(parts[0], allowPattern: true), parts[1] == "_validate", parts[2] == "query" { return true }
        if parts.count == 3, validIndex(parts[0], allowPattern: false), parts[1] == "_explain" { return true }
        return false
    }

    private static func writeEndpoint(_ parts: [String], method: String) -> Bool {
        guard let index = parts.first, validIndex(index, allowPattern: false) else { return false }
        if parts.count == 1 { return ["PUT", "DELETE"].contains(method) }
        if parts.count == 2, parts[1] == "_doc" { return method == "POST" }
        if parts.count == 3, parts[1] == "_doc" { return ["POST", "PUT", "DELETE"].contains(method) }
        if parts.count == 3, parts[1] == "_create" { return ["POST", "PUT"].contains(method) }
        if parts.count == 3, parts[1] == "_update" { return method == "POST" }
        return false
    }

    static func validIndex(_ value: String, allowPattern: Bool) -> Bool {
        if allowPattern, value == "_all" { return true }
        let names = allowPattern ? value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) : [value]
        let forbidden = CharacterSet(charactersIn: "\\/?\"<>|,#:%").union(.whitespacesAndNewlines).union(.controlCharacters)
        return names.allSatisfy { name in
            !name.isEmpty && name != "." && name != ".." && !name.hasPrefix("_") && !name.hasPrefix("-") && !name.hasPrefix("+") &&
            name.utf8.count <= 255 && name.lowercased() == name &&
            name.unicodeScalars.allSatisfy { !forbidden.contains($0) && ($0.value != 42 || allowPattern) }
        }
    }

    private static func containsUnsupportedExecution(_ value: HTTPJSONValue) -> Bool {
        switch value {
        case .object(let fields):
            let unsupported: Set<String> = ["script", "script_fields", "script_score", "scripted_metric", "_script", "runtime_mappings", "pit", "scroll"]
            return fields.keys.contains(where: unsupported.contains) || fields.values.contains(where: containsUnsupportedExecution)
        case .array(let values): return values.contains(where: containsUnsupportedExecution)
        default: return false
        }
    }

    static func browse(index: String, limit: Int, offset: Int) -> String {
        ElasticsearchCommand(method: "POST", path: "/\(index)/_search",
            body: .object(["query": .object(["match_all": .object([:])]), "size": .number(String(min(10_000, max(1, limit)))),
                           "from": .number(String(max(0, offset)))]), isReadOnly: true).preview
    }

    static func assessment(for text: String, readOnly: Bool) -> SQLSafetyAssessment? {
        do {
            let command = try parse(text)
            if readOnly && !command.isReadOnly {
                return SQLSafetyAssessment(title: L10n.text("Read-only connection"),
                    message: L10n.text("This server is marked read-only. Disable read-only mode in the server bookmark before running write or schema statements."),
                    requiresConfirmation: false, blocksExecution: true)
            }
            guard !command.isReadOnly else { return nil }
            return SQLSafetyAssessment(title: L10n.text("Confirm write"),
                message: command.preview, requiresConfirmation: true, blocksExecution: false)
        } catch {
            return SQLSafetyAssessment(title: L10n.text("Query"), message: error.localizedDescription,
                requiresConfirmation: false, blocksExecution: true)
        }
    }
}
