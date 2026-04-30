import Foundation
import SlopguardCore
import SlopguardCoverage

enum GetCoverageGapsTool {

    static let definition = ToolDefinition(
        name: "get_coverage_gaps",
        title: "Find complex methods with low coverage",
        description: """
            Return methods that are both complex (>= minComplexity) and undertested \
            (<= maxCoverage%). This is the actionable backlog for agents asked to \
            "improve testing where it matters most" — high CRAP isn't always the right \
            target, but high complexity + low coverage always is.
            """,
        inputSchema: ToolSchemas.getCoverageGaps,
        handler: { args, _, cache in
            guard let report = await cache.get() else {
                return ToolUtilities.errorResult(.init(
                    code: "no_report",
                    message: "No CrapReport cached. Run analyze_directory first."
                ))
            }
            guard report.coverageAvailable else {
                return ToolUtilities.errorResult(.init(
                    code: "coverage_unavailable",
                    message: "Last analysis ran without coverage data — gaps cannot be computed. Re-run analyze_directory (it will drive `xcodebuild test` itself)."
                ))
            }
            let minComplexity = ToolUtilities.int(args, "minComplexity") ?? 5
            let maxCoverage = ToolUtilities.double(args, "maxCoverage") ?? 50
            let limit = ToolUtilities.int(args, "limit") ?? 20

            let hits = report.methods
                .filter { $0.complexity >= minComplexity && $0.coverage <= maxCoverage }
                .sorted { lhs, rhs in
                    if lhs.complexity != rhs.complexity { return lhs.complexity > rhs.complexity }
                    return lhs.coverage < rhs.coverage
                }
                .prefix(limit)

            let payload = CoverageGapsResponse(
                minComplexity: minComplexity,
                maxCoverage: maxCoverage,
                count: hits.count,
                methods: Array(hits)
            )
            return try ToolUtilities.successResult(payload)
        }
    )
}

private struct CoverageGapsResponse: Codable, Sendable {
    let minComplexity: Int
    let maxCoverage: Double
    let count: Int
    let methods: [MethodCrap]
}
