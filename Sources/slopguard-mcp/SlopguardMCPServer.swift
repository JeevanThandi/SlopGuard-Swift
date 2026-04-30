import Foundation
import SlopguardCore
import SlopguardCoverage

/// The slopguard MCP server. Implements `MCPHandler` against our hand-rolled
/// JSON-RPC dispatcher and delegates each `tools/call` to the matching
/// `ToolDefinition`.
public actor SlopguardMCPServer: MCPHandler {

    private let cache: ReportCache
    private let pipeline: AnalysisPipeline
    private let tools_: [ToolDefinition]
    private let toolMap: [String: ToolDefinition]

    public nonisolated let serverInfo: ServerInfo
    public nonisolated let instructions: String?

    public init(
        pipeline: AnalysisPipeline = AnalysisPipeline(),
        cache: ReportCache = ReportCache()
    ) {
        self.pipeline = pipeline
        self.cache = cache
        let tools: [ToolDefinition] = [
            AnalyzeDirectoryTool.definition,
            AnalyzeFileTool.definition,
            GetCrapReportTool.definition,
            FindCrappyCodeTool.definition,
            GetCoverageGapsTool.definition,
            SuggestRefactorTool.definition
        ]
        self.tools_ = tools
        self.toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.serverInfo = ServerInfo(
            name: SlopguardVersion.toolName,
            version: SlopguardVersion.version
        )
        self.instructions = """
            slopguard-swift is the CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS. \
            Use analyze_directory or analyze_file first, then query find_crappy_code, \
            get_coverage_gaps, or get_crap_report. CRAP = comp² × (1 − cov/100)³ + comp; \
            the default crappy threshold is 30.
            """
    }

    public func tools() async -> [ToolDescriptor] {
        tools_.map(\.descriptor)
    }

    public func callTool(name: String, arguments: [String: JSONValue]?) async -> ToolCallResult {
        guard let tool = toolMap[name] else {
            return ToolUtilities.errorResult(
                SlopguardErrorEnvelope(
                    code: "unknown_tool",
                    message: "No tool registered with name '\(name)'"
                )
            )
        }
        do {
            return try await tool.handler(arguments, pipeline, cache)
        } catch let error as SlopguardError {
            return ToolUtilities.errorResult(.init(error))
        } catch {
            return ToolUtilities.errorResult(
                SlopguardErrorEnvelope(code: "internal_error", message: "\(error)")
            )
        }
    }

    /// Run the MCP server over the given transport (default: stdio) until the
    /// transport disconnects.
    public func run(transport: StdioTransport = StdioTransport()) async throws {
        let dispatcher = MCPDispatcher(handler: self, transport: transport)
        try await dispatcher.run()
    }
}
