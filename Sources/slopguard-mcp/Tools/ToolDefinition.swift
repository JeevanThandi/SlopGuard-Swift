import Foundation
import SlopguardCore
import SlopguardCoverage

/// Internal helper bundling everything we need to register a tool with the MCP dispatcher.
struct ToolDefinition: Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: JSONValue
    let handler: @Sendable (
        _ arguments: [String: JSONValue]?,
        _ pipeline: AnalysisPipeline,
        _ cache: ReportCache
    ) async throws -> ToolCallResult

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            annotations: ToolAnnotations(
                title: title,
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        )
    }
}

/// Helpers for tool handlers.
enum ToolUtilities {

    /// Encode a Codable value to a `JSONValue` and to a JSON text fallback so it appears
    /// in both `structuredContent` (machine-readable) and `content` (text-rendering
    /// clients).
    static func successResult<Output: Codable & Sendable>(_ value: Output) throws -> ToolCallResult {
        let structured = try JSONValue(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return ToolCallResult(
            content: [.text(text)],
            structuredContent: structured,
            isError: false
        )
    }

    static func errorResult(_ envelope: SlopguardErrorEnvelope) -> ToolCallResult {
        let payload: JSONValue = .object([
            "error": .object([
                "code": .string(envelope.code),
                "message": .string(envelope.message)
            ])
        ])
        let text = "[\(envelope.code)] \(envelope.message)"
        return ToolCallResult(
            content: [.text(text)],
            structuredContent: payload,
            isError: true
        )
    }

    /// Resolve an argument as a path. Tilde (`~`) is expanded; relative paths are
    /// resolved against the current working directory.
    static func resolvePath(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    static func string(_ args: [String: JSONValue]?, _ key: String) -> String? {
        args?[key]?.stringValue
    }

    static func double(_ args: [String: JSONValue]?, _ key: String) -> Double? {
        if let d = args?[key]?.doubleValue { return d }
        if let i = args?[key]?.intValue { return Double(i) }
        return nil
    }

    static func int(_ args: [String: JSONValue]?, _ key: String) -> Int? {
        if let i = args?[key]?.intValue { return i }
        if let d = args?[key]?.doubleValue { return Int(d) }
        return nil
    }

    static func bool(_ args: [String: JSONValue]?, _ key: String) -> Bool? {
        args?[key]?.boolValue
    }

    static func stringArray(_ args: [String: JSONValue]?, _ key: String) -> [String]? {
        guard let arr = args?[key]?.arrayValue else { return nil }
        let strs = arr.compactMap { $0.stringValue }
        return strs.isEmpty ? nil : strs
    }

    /// Build the `.auto` coverage knobs from MCP tool arguments. Coverage is
    /// always auto-generated for MCP callers — `xcresult` is no longer a
    /// public input.
    static func autoCoverage(_ args: [String: JSONValue]?) -> AnalysisPipeline.CoverageSource {
        var opts = AnalysisPipeline.AutoCoverageOptions()
        if let scheme = string(args, "scheme") { opts.scheme = scheme }
        if let dest = string(args, "destination") { opts.destination = dest }
        return .auto(opts)
    }
}
