import Foundation

struct ElasticsearchCommand: Sendable, Equatable {
    let method: String
    let path: String
    let body: HTTPJSONValue?
    let isReadOnly: Bool

    var isSearch: Bool { path == "/_search" || path.hasSuffix("/_search") }
    var preview: String {
        var fields: [String: HTTPJSONValue] = ["method": .string(method), "path": .string(path)]
        if let body { fields["body"] = body }
        return HTTPJSONValue.object(fields).json(pretty: true)
    }
}
