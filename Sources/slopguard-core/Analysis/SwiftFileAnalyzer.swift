import Foundation
import SwiftSyntax
import SwiftParser

/// Parses one Swift source file and produces a `FileReport`. Stateless and `Sendable` —
/// safe to call from concurrent tasks in `DirectoryAnalyzer`.
public struct SwiftFileAnalyzer: Sendable {

    public init() {}

    /// Analyze a file by URL. Reads UTF-8 source, parses with SwiftParser, walks
    /// with `ComplexityVisitor`, and returns the result.
    ///
    /// - Parameters:
    ///   - url: Absolute URL of a `.swift` file.
    ///   - reportedPath: Path to record on the resulting `FileReport` (typically
    ///                   relative to the analysis root). Defaults to `url.path`.
    public func analyze(url: URL, reportedPath: String? = nil) throws -> FileReport {
        let path = url.path
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SlopguardError.unreadableFile(path: path, underlying: "\(error)")
        }
        return try analyze(source: source, reportedPath: reportedPath ?? path)
    }

    /// Analyze a file's source string directly. Useful for tests and any
    /// caller that already has the source in memory.
    public func analyze(source: String, reportedPath: String) throws -> FileReport {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: reportedPath, tree: tree)
        let visitor = ComplexityVisitor(filePath: reportedPath, converter: converter)
        visitor.walk(tree)
        return FileReport(path: reportedPath, methods: visitor.methods, types: visitor.types)
    }
}
