import Foundation
import SwiftSyntax
import SwiftParser

/// One source file with its planned mutants.
public struct PlannedFile: Sendable, Hashable {
    public let absolutePath: String
    /// Path relative to the source root — the `file` of each mutant.
    public let relativePath: String
    /// The UTF-8 source the mutants were planned against.
    public let source: String
    /// Sorted by line, column and operator id.
    public let mutants: [PlannedMutant]

    public init(absolutePath: String, relativePath: String, source: String, mutants: [PlannedMutant]) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.source = source
        self.mutants = mutants
    }
}

/// Plans mutants: generates them, names each mutant's enclosing method (via
/// the complexity analyzer, so names match the CRAP report), applies ignore
/// markers, keeps the requested operators and sorts. Reads files; runs nothing.
public struct MutationPlanner: Sendable {

    private let generator: MutantGenerator
    private let directoryAnalyzer: DirectoryAnalyzer

    public init(generator: MutantGenerator = MutantGenerator(), directoryAnalyzer: DirectoryAnalyzer = DirectoryAnalyzer()) {
        self.generator = generator
        self.directoryAnalyzer = directoryAnalyzer
    }

    /// Mutants for one file's `source`, sorted by line, column and operator id.
    public func plan(source: String, reportedPath: String, operators: [MutationOperator]) -> [PlannedMutant] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: reportedPath, tree: tree)
        let complexity = ComplexityVisitor(filePath: reportedPath, converter: converter)
        complexity.walk(tree)
        let methods = complexity.methods
        let ignores = IgnoreMarkers.parse(lines: IgnoreMarkers.lines(of: source))
        let enabled = Set(operators)
        return generator.generate(tree: tree, source: source, reportedPath: reportedPath)
            .filter { enabled.contains($0.mutationOperator) }
            .sorted(by: MutantSite.precedes)
            .map { site in
                let method = Self.enclosingMethod(methods, line: site.line)
                return PlannedMutant(
                    site: site,
                    method: method?.qualifiedName,
                    methodLines: method.map { $0.startLine...$0.endLine },
                    ignored: IgnoreMarkers.isIgnored(ignores, line: site.line, operator: site.mutationOperator)
                )
            }
    }

    /// Walk `rootURL` (a directory or one `.swift` file) with the same rules as
    /// `analyze` and plan every file. Files come back sorted byte-wise by
    /// relative path, so the mutants are in report order.
    public func planFiles(
        rootURL: URL,
        options: AnalysisOptions = .default,
        operators: [MutationOperator] = MutationOperator.allCases
    ) throws -> [PlannedFile] {
        try directoryAnalyzer.sourceFiles(rootURL: rootURL, options: options)
            .sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
            .map { file in
                let absolutePath = file.url.standardizedFileURL.path
                let source = try Self.readSource(absolutePath)
                return PlannedFile(
                    absolutePath: absolutePath,
                    relativePath: file.relativePath,
                    source: source,
                    mutants: plan(source: source, reportedPath: file.relativePath, operators: operators)
                )
            }
    }

    /// Qualified name and span of the innermost method whose line range holds
    /// `line`: the smallest span wins, and on a tie the one that starts later.
    public static func enclosingMethod(_ methods: [MethodMetric], line: Int) -> MethodMetric? {
        var best: MethodMetric?
        for method in methods where method.startLine <= line && line <= method.endLine {
            guard let current = best else {
                best = method
                continue
            }
            let span = method.endLine - method.startLine
            let bestSpan = current.endLine - current.startLine
            if span < bestSpan || (span == bestSpan && method.startLine > current.startLine) {
                best = method
            }
        }
        return best
    }

    /// Read a file as UTF-8. Mutant offsets index these bytes, so a file that
    /// is not valid UTF-8 is an error rather than a lossy decode.
    private static func readSource(_ path: String) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw SlopguardError.unreadableFile(path: path, underlying: "\(error)")
        }
        // Decoding replaces invalid sequences, so a round trip that changes the
        // bytes means the file is not valid UTF-8. A byte-order mark survives.
        let source = String(decoding: data, as: UTF8.self)
        guard Data(source.utf8) == data else {
            throw SlopguardError.unreadableFile(path: path, underlying: "The file is not valid UTF-8.")
        }
        return source
    }
}
