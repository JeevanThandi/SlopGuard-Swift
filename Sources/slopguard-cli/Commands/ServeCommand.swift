import Foundation
import ArgumentParser
import MCP
import SlopguardCore
import SlopguardMCP

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the slopguard-swift MCP server.",
        discussion: """
            Default transport is stdio — the form expected by Claude Code, Cursor, and \
            most other MCP clients. The 'http' transport is reserved for v0.2; the \
            stateful HTTP transport in the MCP SDK requires hosting an HTTP framework \
            (NIO/Hummingbird), which is out of scope for v0.1.
            """
    )

    enum Transport: String, ExpressibleByArgument, CaseIterable {
        case stdio
        case http
    }

    @Option(name: .long, help: "Transport: stdio (default) or http (v0.2).")
    var transport: Transport = .stdio

    @Option(name: .long, help: "(http only) Bind host. Reserved for v0.2.")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "(http only) Bind port. Reserved for v0.2.")
    var port: Int = 8123

    mutating func run() async throws {
        switch transport {
        case .stdio:
            try await runStdio()
        case .http:
            FileHandle.standardError.write(Data(
                "slopguard-swift: HTTP transport is not yet wired up in v0.1. Use --transport stdio.\n".utf8
            ))
            throw ExitCode(2)
        }
    }

    private func runStdio() async throws {
        let server = SlopguardMCPServer()
        let stdio = StdioTransport()
        do {
            try await server.run(transport: stdio)
        } catch {
            FileHandle.standardError.write(Data("slopguard-swift: MCP server error: \(error)\n".utf8))
            throw ExitCode(1)
        }
    }
}
