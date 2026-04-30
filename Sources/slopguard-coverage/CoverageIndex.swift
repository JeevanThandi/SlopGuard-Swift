import Foundation
import SlopguardCore

/// Fast lookup over an `XccovReport`. Built once after running `xccov`, then queried
/// per method by `CrapAggregator`.
///
/// xccov reports `file.path` as an *absolute* path (the build machine's view of the
/// source tree). Our analyzer reports paths *relative* to the analysis root. The
/// caller is therefore expected to resolve a method's path back to an absolute path
/// (`rootURL + relativePath`) before calling `coverage(forAbsolutePath:line:endLine:)`.
/// We additionally keep a basename map to fall back when paths don't match exactly
/// (CI checkouts vs. local clones, symlinks, etc.).
public struct CoverageIndex: Sendable {

    public struct FileCoverage: Sendable, Hashable {
        public let path: String
        public let basename: String
        public let lineCoverage: Double      // [0, 1]
        public let executableLines: Int
        public let coveredLines: Int
        public let functions: [FunctionCoverage]
    }

    public struct FunctionCoverage: Sendable, Hashable {
        public let name: String
        public let lineNumber: Int
        public let executableLines: Int
        public let coveredLines: Int
        public let lineCoverage: Double      // [0, 1]
    }

    private let filesByAbsolutePath: [String: FileCoverage]
    private let filesByBasename: [String: [FileCoverage]]

    public let totalLineCoverage: Double
    public let totalCoveredLines: Int
    public let totalExecutableLines: Int

    public init(report: XccovReport) {
        var byPath: [String: FileCoverage] = [:]
        var byBasename: [String: [FileCoverage]] = [:]

        for target in report.targets {
            for file in target.files {
                let funcs = file.functions
                    .map {
                        FunctionCoverage(
                            name: $0.name,
                            lineNumber: $0.lineNumber,
                            executableLines: $0.executableLines,
                            coveredLines: $0.coveredLines,
                            lineCoverage: $0.lineCoverage
                        )
                    }
                    .sorted { $0.lineNumber < $1.lineNumber }
                let cov = FileCoverage(
                    path: file.path,
                    basename: file.name,
                    lineCoverage: file.lineCoverage,
                    executableLines: file.executableLines,
                    coveredLines: file.coveredLines,
                    functions: funcs
                )
                byPath[file.path] = cov
                byBasename[file.name, default: []].append(cov)
            }
        }

        self.filesByAbsolutePath = byPath
        self.filesByBasename = byBasename
        self.totalLineCoverage = report.lineCoverage
        self.totalCoveredLines = report.coveredLines
        self.totalExecutableLines = report.executableLines
    }

    /// Returns method-level coverage as a percentage in `[0, 100]`, or `nil` if no
    /// matching function was found in the xccov data. The caller can decide whether
    /// `nil` should fall back to file-level coverage or be treated as 0%.
    public func coverage(forAbsolutePath path: String, line: Int, endLine: Int) -> Double? {
        guard let file = lookupFile(absolutePath: path) else { return nil }

        // Strategy: prefer the function whose `lineNumber` lies inside the method's
        // [start, end] range. xccov's `lineNumber` is the function's first executable
        // line, which generally matches the SwiftSyntax `startLine` for the decl.
        // If multiple functions land in-range (e.g. nested closures lifted to
        // separate functions), pick the one closest to `line`.
        var best: FunctionCoverage?
        var bestDistance = Int.max
        for fn in file.functions where fn.lineNumber >= line && fn.lineNumber <= endLine {
            let d = abs(fn.lineNumber - line)
            if d < bestDistance {
                best = fn
                bestDistance = d
            }
        }
        if let best { return best.lineCoverage * 100.0 }
        return nil
    }

    /// Returns the file-level coverage as a percentage in `[0, 100]`, or `nil` if the
    /// file was not found in the xccov data.
    public func fileCoverage(forAbsolutePath path: String) -> Double? {
        lookupFile(absolutePath: path).map { $0.lineCoverage * 100.0 }
    }

    private func lookupFile(absolutePath: String) -> FileCoverage? {
        if let direct = filesByAbsolutePath[absolutePath] { return direct }
        let basename = (absolutePath as NSString).lastPathComponent
        let candidates = filesByBasename[basename] ?? []
        if candidates.count == 1 { return candidates[0] }
        // Multiple files with the same basename — pick the one whose path shares
        // the longest suffix with our query path. This handles common CI cases
        // (`/Users/runner/work/...` vs `/Users/dev/...`) without false positives
        // when there are genuinely-distinct files of the same name.
        var best: FileCoverage?
        var bestOverlap = 0
        for candidate in candidates {
            let overlap = sharedSuffixLength(absolutePath, candidate.path)
            if overlap > bestOverlap {
                best = candidate
                bestOverlap = overlap
            }
        }
        return best
    }
}

// MARK: - CoverageProvider conformance

extension CoverageIndex: CoverageProvider {
    public func methodCoverage(absolutePath: String, line: Int, endLine: Int) -> Double? {
        coverage(forAbsolutePath: absolutePath, line: line, endLine: endLine)
    }

    public func fileCoverage(absolutePath: String) -> Double? {
        fileCoverage(forAbsolutePath: absolutePath)
    }
}

private func sharedSuffixLength(_ a: String, _ b: String) -> Int {
    var ai = a.endIndex, bi = b.endIndex
    var count = 0
    while ai != a.startIndex && bi != b.startIndex {
        ai = a.index(before: ai)
        bi = b.index(before: bi)
        if a[ai] != b[bi] { break }
        count += 1
    }
    return count
}
