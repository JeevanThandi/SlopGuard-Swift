import Foundation

/// Pure renderers for `MutationReport`: a text block for people and canonical
/// JSON (sorted keys) for agents and CI. The layout is shared with every
/// slopguard port.
public enum MutationReportFormatter: Sendable {

    /// Longest `original` / `replacement` shown in the text listing, in code points.
    static let snippetLimit = 40

    /// Sections that list mutants, in display order.
    private static let sections: [(status: MutantStatus, title: @Sendable (Int) -> String)] = [
        (.survived, { "Survived (\($0)) — tests still pass with these changes" }),
        (.noCoverage, { "No coverage (\($0)) — no test runs these lines" }),
        (.timeout, { "Timed out (\($0)) — counted as killed" }),
        (.pending, { "Mutants (\($0), not run)" })
    ]

    public static func pretty(_ report: MutationReport) -> String {
        var out = header(report)
        out += "\n"
        if !report.notes.isEmpty {
            out += "Notes\n"
            for note in report.notes { out += "  • \(note)\n" }
            out += "\n"
        }
        out += summary(report.summary)
        for section in sections {
            let mutants = report.mutants.filter { $0.status == section.status }
            if mutants.isEmpty { continue }
            out += "\n\(section.title(mutants.count))\n"
            for mutant in mutants { out += "  \(listingLine(mutant))\n" }
        }
        return out
    }

    /// Canonical JSON encoding — sorted keys, explicit nulls, slashes
    /// unescaped, so the output diffs cleanly in CI.
    public static func json(_ report: MutationReport, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    /// `16` for whole seconds, `2.5` otherwise.
    public static func formatSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded(), abs(seconds) < 1e15 {
            return String(Int64(seconds))
        }
        return "\(seconds)"
    }

    /// Collapse whitespace runs to one space and cap the length at 40 code
    /// points (the first 39 plus `…`), so multi-line statements stay on one line.
    public static func snippet(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var inWhitespace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !inWhitespace { scalars.append(" ") }
                inWhitespace = true
            } else {
                scalars.append(scalar)
                inWhitespace = false
            }
        }
        if scalars.count > snippetLimit {
            scalars = Array(scalars.prefix(snippetLimit - 1)) + ["…"]
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        return String(out)
    }

    // MARK: - Text helpers

    private static func header(_ report: MutationReport) -> String {
        let notRun = "(not run)"
        let timeout = report.timeoutSeconds.map { "\(formatSeconds($0))s per mutant" } ?? notRun
        return """
        \(report.tool) \(report.toolVersion) — mutation report (schema \(report.schemaVersion))
        source:    \(report.sourceRoot)
        project:   \(report.projectRoot ?? notRun)
        runner:    \(report.runner ?? notRun)
        timeout:   \(timeout)

        """
    }

    private static func summary(_ s: MutationReport.Summary) -> String {
        var rows: [(String, String)] = [
            ("files:", "\(s.fileCount)"),
            ("mutants:", "\(s.mutantCount)"),
            ("killed:", "\(s.killed)"),
            ("timed out:", "\(s.timedOut)"),
            ("survived:", "\(s.survived)"),
            ("no coverage:", "\(s.noCoverage)"),
            ("compile errors:", "\(s.compileErrors)"),
            ("ignored:", "\(s.ignored)")
        ]
        if s.pending > 0 { rows.append(("pending:", "\(s.pending)")) }
        rows.append(("score:", s.mutationScore.map { String(format: "%.2f%%", $0) } ?? "n/a"))
        return "Summary\n" + rows.map { label, value in
            "  \(label.padding(toLength: max(16, label.count), withPad: " ", startingAt: 0))\(value)\n"
        }.joined()
    }

    private static func listingLine(_ mutant: MutantResult) -> String {
        let change = "`\(snippet(mutant.original))` → `\(snippet(mutant.replacement))`"
        let method = mutant.method.map { "  \($0)" } ?? ""
        return "\(mutant.file):\(mutant.line):\(mutant.column)  \(mutant.mutationOperator.rawValue)  \(change)\(method)"
    }
}
