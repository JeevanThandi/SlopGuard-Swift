import Foundation

/// Anything that can answer the small subset of MCP methods we care about:
/// `initialize`, `tools/list`, `tools/call`, `ping`. Everything else returns
/// "method not found".
public protocol MCPHandler: Sendable {
    var serverInfo: ServerInfo { get }
    var instructions: String? { get }
    func tools() async -> [ToolDescriptor]
    func callTool(name: String, arguments: [String: JSONValue]?) async -> ToolCallResult
}

/// Drives the MCP protocol against a `StdioTransport`. Each request is
/// dispatched on its own task so a long-running `analyze_directory` call
/// doesn't block a `tools/list` request that arrives mid-flight.
public actor MCPDispatcher {

    private let handler: any MCPHandler
    private let transport: StdioTransport
    private let supportedProtocolVersion = "2025-03-26"

    public init(handler: any MCPHandler, transport: StdioTransport = StdioTransport()) {
        self.handler = handler
        self.transport = transport
    }

    public func run() async throws {
        let stream = transport.receive()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await line in stream {
                let handler = self.handler
                let transport = self.transport
                let supportedVersion = self.supportedProtocolVersion
                group.addTask {
                    await Self.process(line: line, handler: handler, transport: transport, supportedVersion: supportedVersion)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func process(
        line: Data,
        handler: any MCPHandler,
        transport: StdioTransport,
        supportedVersion: String
    ) async {
        let decoder = JSONDecoder()
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: line)
        } catch {
            await send(
                response: .failure(id: nil, error: .init(
                    code: JSONRPCError.parseError,
                    message: "Invalid JSON: \(error)",
                    data: nil
                )),
                via: transport
            )
            return
        }

        let response = await handle(request: request, handler: handler, supportedVersion: supportedVersion)
        if let response { await send(response: response, via: transport) }
    }

    private static func handle(
        request: JSONRPCRequest,
        handler: any MCPHandler,
        supportedVersion: String
    ) async -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            let clientVersion = request.params?.objectValue?["protocolVersion"]?.stringValue
            let echoVersion = clientVersion ?? supportedVersion
            let info = handler.serverInfo
            var result: [String: JSONValue] = [
                "protocolVersion": .string(echoVersion),
                "serverInfo": .object([
                    "name": .string(info.name),
                    "version": .string(info.version)
                ]),
                "capabilities": .object([
                    "tools": .object(["listChanged": .bool(false)])
                ])
            ]
            if let instructions = handler.instructions {
                result["instructions"] = .string(instructions)
            }
            return .success(id: request.id, result: .object(result))

        case "notifications/initialized":
            return nil

        case "tools/list":
            let descriptors = await handler.tools()
            do {
                let json = try JSONValue(["tools": descriptors])
                return .success(id: request.id, result: json)
            } catch {
                return .failure(id: request.id, error: .init(
                    code: JSONRPCError.internalError,
                    message: "Failed to encode tools: \(error)",
                    data: nil
                ))
            }

        case "tools/call":
            guard let params = request.params?.objectValue,
                  let name = params["name"]?.stringValue
            else {
                return .failure(id: request.id, error: .init(
                    code: JSONRPCError.invalidParams,
                    message: "tools/call requires 'name'",
                    data: nil
                ))
            }
            let arguments = params["arguments"]?.objectValue
            let result = await handler.callTool(name: name, arguments: arguments)
            do {
                let json = try JSONValue(result)
                return .success(id: request.id, result: json)
            } catch {
                return .failure(id: request.id, error: .init(
                    code: JSONRPCError.internalError,
                    message: "Failed to encode tool result: \(error)",
                    data: nil
                ))
            }

        case "ping":
            return .success(id: request.id, result: .object([:]))

        default:
            if request.isNotification { return nil }
            return .failure(id: request.id, error: .init(
                code: JSONRPCError.methodNotFound,
                message: "Method not found: \(request.method)",
                data: nil
            ))
        }
    }

    private static func send(response: JSONRPCResponse, via transport: StdioTransport) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            let data = try encoder.encode(response)
            await transport.send(data)
        } catch {
            // Encoding the response itself failed; nothing safe to do here.
        }
    }
}
