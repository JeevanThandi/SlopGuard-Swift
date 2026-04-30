import Foundation
import SlopguardCore
import SlopguardCoverage

enum AnalyzeFileTool {

    static let definition = ToolDefinition(
        name: "analyze_file",
        title: "Analyze a single file",
        description: """
            Analyze one Swift file and return a CrapReport scoped to its declarations. \
            Useful for agentic flows where the agent edits a file and wants to immediately \
            check whether the change introduced any new crappy code.
            """,
        inputSchema: ToolSchemas.analyzeFile,
        handler: { args, pipeline, cache in
            guard let path = ToolUtilities.string(args, "path") else {
                return ToolUtilities.errorResult(.init(.invalidArgument(name: "path", reason: "required string argument")))
            }
            let url = ToolUtilities.resolvePath(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ToolUtilities.errorResult(.init(.fileNotFound(path: url.path)))
            }
            let threshold = ToolUtilities.double(args, "threshold") ?? CRAP.defaultThreshold
            let coverage = ToolUtilities.autoCoverage(args)

            do {
                let report = try await pipeline.run(
                    sourceURL: url,
                    coverage: coverage,
                    threshold: threshold,
                    options: .default
                )
                // Single-file analysis caches a narrow report; that's fine — agents
                // typically pair analyze_file with subsequent direct queries.
                await cache.store(
                    report: report,
                    sourceRoot: url.deletingLastPathComponent().path,
                    xcresultPath: report.xcresultPath
                )
                return try ToolUtilities.successResult(report)
            } catch let error as SlopguardError {
                return ToolUtilities.errorResult(.init(error))
            } catch {
                return ToolUtilities.errorResult(.init(code: "internal_error", message: "\(error)"))
            }
        }
    )
}
