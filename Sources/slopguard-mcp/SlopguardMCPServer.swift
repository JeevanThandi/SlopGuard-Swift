import Foundation
import MCP
import SlopguardCore
import SlopguardCoverage

/// The slopguard MCP server. Wraps `MCP.Server` and registers all six slopguard tools.
public actor SlopguardMCPServer {

    private let server: Server
    private let cache: ReportCache
    private let pipeline: AnalysisPipeline
    private let tools: [ToolDefinition]

    public init(
        pipeline: AnalysisPipeline = AnalysisPipeline(),
        cache: ReportCache = ReportCache()
    ) {
        self.pipeline = pipeline
        self.cache = cache
        self.tools = [
            AnalyzeDirectoryTool.definition,
            AnalyzeFileTool.definition,
            GetCrapReportTool.definition,
            FindCrappyCodeTool.definition,
            GetCoverageGapsTool.definition,
            SuggestRefactorTool.definition
        ]
        self.server = Server(
            name: SlopguardVersion.toolName,
            version: SlopguardVersion.version,
            instructions: """
                slopguard-swift is the CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS. \
                Use analyze_directory or analyze_file first, then query find_crappy_code, \
                get_coverage_gaps, or get_crap_report. CRAP = comp² × (1 − cov/100)³ + comp; \
                the default crappy threshold is 30.
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    /// Connect the configured transport, register handlers, and run until the
    /// transport disconnects (e.g. EOF on stdio).
    public func run(transport: any Transport) async throws {
        try await registerHandlers()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    public func stop() async {
        await server.stop()
    }

    private func registerHandlers() async throws {
        let descriptors = tools.map(\.descriptor)
        let toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let pipeline = self.pipeline
        let cache = self.cache

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: descriptors)
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = toolMap[params.name] else {
                let envelope = SlopguardErrorEnvelope(
                    code: "unknown_tool",
                    message: "No tool registered with name '\(params.name)'"
                )
                return ToolUtilities.errorResult(envelope)
            }
            do {
                return try await tool.handler(params.arguments, pipeline, cache)
            } catch let error as SlopguardError {
                return ToolUtilities.errorResult(.init(error))
            } catch {
                return ToolUtilities.errorResult(.init(
                    code: "internal_error",
                    message: "\(error)"
                ))
            }
        }
    }
}
