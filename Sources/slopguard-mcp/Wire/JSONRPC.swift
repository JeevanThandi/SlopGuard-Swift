import Foundation

/// JSON-RPC 2.0 envelope types. We keep these internal to the MCP layer.

struct JSONRPCRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONValue?

    var isNotification: Bool {
        // JSON-RPC: a notification has no `id`. We treat absent and `null`
        // identically since some clients serialize null for notifications.
        switch id {
        case .none, .some(.null): return true
        default: return false
        }
    }
}

struct JSONRPCError: Encodable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

struct JSONRPCResponse: Encodable, Sendable {
    let jsonrpc: String
    let id: JSONValue?
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONValue?, result: JSONValue) -> JSONRPCResponse {
        .init(jsonrpc: "2.0", id: id ?? .null, result: result, error: nil)
    }

    static func failure(id: JSONValue?, error: JSONRPCError) -> JSONRPCResponse {
        .init(jsonrpc: "2.0", id: id ?? .null, result: nil, error: error)
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id ?? .null, forKey: .id)
        if let result = result { try c.encode(result, forKey: .result) }
        if let error = error { try c.encode(error, forKey: .error) }
    }
}
