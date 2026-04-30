import Foundation
import MCP
import SlopguardCore
import SlopguardCoverage

enum FindCrappyCodeTool {

    static let definition = ToolDefinition(
        name: "find_crappy_code",
        title: "Find the worst CRAP offenders",
        description: """
            Return the top-N methods (or types) whose CRAP score exceeds a threshold, \
            sorted descending. The hero query for agentic refactor sessions: "show me \
            what to fix first". Defaults: threshold=30, limit=20, level=method.
            """,
        inputSchema: ToolSchemas.findCrappyCode,
        handler: { args, _, cache in
            guard let report = await cache.get() else {
                return ToolUtilities.errorResult(.init(
                    code: "no_report",
                    message: "No CrapReport cached. Run analyze_directory first."
                ))
            }
            let threshold = ToolUtilities.double(args, "threshold") ?? CRAP.defaultThreshold
            let limit = ToolUtilities.int(args, "limit") ?? 20
            let level = ToolUtilities.string(args, "level") ?? "method"

            switch level {
            case "method":
                let hits = report.methods
                    .filter { $0.crap > threshold }
                    .prefix(limit)
                let payload = FindCrappyCodeMethodResponse(
                    threshold: threshold,
                    level: "method",
                    count: hits.count,
                    methods: Array(hits)
                )
                return try ToolUtilities.successResult(payload)
            case "class":
                let hits = report.types
                    .filter { $0.aggregatedCrap > threshold || $0.maxCrap > threshold }
                    .prefix(limit)
                let payload = FindCrappyCodeTypeResponse(
                    threshold: threshold,
                    level: "class",
                    count: hits.count,
                    types: Array(hits)
                )
                return try ToolUtilities.successResult(payload)
            default:
                return ToolUtilities.errorResult(.init(
                    .invalidArgument(name: "level", reason: "must be \"method\" or \"class\"")
                ))
            }
        }
    )
}

private struct FindCrappyCodeMethodResponse: Codable, Sendable {
    let threshold: Double
    let level: String
    let count: Int
    let methods: [MethodCrap]
}

private struct FindCrappyCodeTypeResponse: Codable, Sendable {
    let threshold: Double
    let level: String
    let count: Int
    let types: [TypeCrap]
}
