import Foundation
import MCP
import SlopguardCore
import SlopguardCoverage

enum GetCrapReportTool {

    static let definition = ToolDefinition(
        name: "get_crap_report",
        title: "Get the cached CRAP report",
        description: """
            Return the most recent CrapReport cached by analyze_directory or analyze_file, \
            optionally filtered server-side by file substring, type name, method substring, \
            or threshold. Use this in tight agent loops to avoid re-running the analyzer.
            """,
        inputSchema: ToolSchemas.getCrapReport,
        handler: { args, _, cache in
            guard let report = await cache.get() else {
                return ToolUtilities.errorResult(.init(
                    code: "no_report",
                    message: "No CrapReport cached. Run analyze_directory or analyze_file first."
                ))
            }
            let filterFile = ToolUtilities.string(args, "filterFile")
            let filterClass = ToolUtilities.string(args, "filterClass")
            let filterMethod = ToolUtilities.string(args, "filterMethod")
            let threshold = ToolUtilities.double(args, "threshold")
            let limit = ToolUtilities.int(args, "limit") ?? 100

            var methods = report.methods
            if let filterFile, !filterFile.isEmpty {
                methods = methods.filter { $0.file.contains(filterFile) }
            }
            if let filterClass, !filterClass.isEmpty {
                methods = methods.filter { $0.typeName == filterClass }
            }
            if let filterMethod, !filterMethod.isEmpty {
                methods = methods.filter { $0.qualifiedName.contains(filterMethod) }
            }
            if let threshold {
                methods = methods.filter { $0.crap > threshold }
            }
            if methods.count > limit {
                methods = Array(methods.prefix(limit))
            }

            var types = report.types
            if let filterFile, !filterFile.isEmpty {
                types = types.filter { $0.file.contains(filterFile) }
            }
            if let filterClass, !filterClass.isEmpty {
                types = types.filter { $0.name == filterClass }
            }
            if let threshold {
                types = types.filter { $0.aggregatedCrap > threshold || $0.maxCrap > threshold }
            }

            let filtered = CrapReport(
                toolVersion: report.toolVersion,
                generatedAt: report.generatedAt,
                sourceRoot: report.sourceRoot,
                xcresultPath: report.xcresultPath,
                threshold: threshold ?? report.threshold,
                coverageAvailable: report.coverageAvailable,
                notes: report.notes,
                summary: report.summary,
                methods: methods,
                types: types
            )
            return try ToolUtilities.successResult(filtered)
        }
    )
}
