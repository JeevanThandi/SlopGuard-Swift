import Foundation
import Darwin
import SlopguardCore

/// Per-line execution counts from an lcov export
/// (`xcrun llvm-cov export -format=lcov …`): `SF:<path>` opens a file,
/// `DA:<line>,<count>` records one executable line, `end_of_record` closes it.
///
/// Paths match exactly after resolving symlinks. There is no basename
/// fallback: a file the export does not name is unknown (`nil`), so its
/// mutants run instead of being called `no_coverage` on another file's data.
public struct LineCoverageIndex: Sendable, CoverageProvider {

    /// Canonical path → line → execution count.
    private let counts: [String: [Int: Int]]

    /// Number of source files with line data.
    public var fileCount: Int { counts.count }

    public init(lcov: String) {
        var counts: [String: [Int: Int]] = [:]
        var file: String?
        for rawLine in lcov.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") {
                file = Self.canonicalPath(String(line.dropFirst(3)))
            } else if line == "end_of_record" {
                file = nil
            } else if line.hasPrefix("DA:"), let file {
                let fields = line.dropFirst(3).split(separator: ",")
                guard fields.count >= 2, let number = Int(fields[0]), let hits = Int(fields[1]) else { continue }
                counts[file, default: [:]][number, default: 0] += hits
            }
        }
        self.counts = counts
    }

    /// Execution count of one line, or `nil` when the file is unknown or the
    /// line is not executable.
    public func count(absolutePath: String, line: Int) -> Int? {
        lookup(absolutePath).flatMap { $0[line] }
    }

    /// Percentage of the executable lines in `[line, endLine]` that ran, or
    /// `nil` when the file is unknown or no line in the range is executable.
    public func methodCoverage(absolutePath: String, line: Int, endLine: Int) -> Double? {
        guard let lines = lookup(absolutePath), line <= endLine else { return nil }
        let executable = (line...endLine).compactMap { lines[$0] }
        guard !executable.isEmpty else { return nil }
        return Double(executable.filter { $0 > 0 }.count) / Double(executable.count) * 100
    }

    public func fileCoverage(absolutePath: String) -> Double? {
        guard let lines = lookup(absolutePath), !lines.isEmpty else { return nil }
        return Double(lines.values.filter { $0 > 0 }.count) / Double(lines.count) * 100
    }

    private func lookup(_ absolutePath: String) -> [Int: Int]? {
        counts[Self.canonicalPath(absolutePath)]
    }

    /// The real path when the file exists (so `/tmp` and `/private/tmp`
    /// agree), else the standardized path.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
