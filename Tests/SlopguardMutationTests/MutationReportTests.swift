import Foundation
import Testing
@testable import SlopguardCore

private func mutant(
    _ status: MutantStatus,
    file: String = "Store.swift",
    line: Int = 16,
    column: Int = 25,
    op: MutationOperator = .negateConditional,
    original: String = "==",
    replacement: String = "!=",
    method: String? = "Store.toggle(id:)"
) -> MutantResult {
    MutantResult(
        id: "\(file):\(line):\(column):\(op.rawValue)",
        file: file,
        line: line,
        column: column,
        mutationOperator: op,
        original: original,
        replacement: replacement,
        method: method,
        status: status
    )
}

private func report(
    _ mutants: [MutantResult],
    fileCount: Int = 3,
    projectRoot: String? = "/abs/project",
    runner: String? = "swift test",
    timeoutSeconds: Double? = 76,
    coverageAvailable: Bool = true,
    notes: [String] = []
) -> MutationReport {
    MutationReport(
        generatedAt: Date(timeIntervalSince1970: 1_790_000_000.25),
        sourceRoot: "/abs/project/Sources",
        projectRoot: projectRoot,
        runner: runner,
        timeoutSeconds: timeoutSeconds,
        coverageAvailable: coverageAvailable,
        operators: MutationOperator.allCases,
        notes: notes,
        summary: MutationReport.Summary(mutants: mutants, fileCount: fileCount),
        mutants: mutants
    )
}

@Suite("summary and score")
struct MutationSummaryTests {

    @Test("score = (killed + timeout) / (killed + timeout + survived + no_coverage) × 100, unrounded")
    func score() {
        let mutants = [MutantStatus.killed, .killed, .timeout, .survived, .noCoverage, .compileError, .ignored, .pending]
            .map { mutant($0) }
        let summary = MutationReport.Summary(mutants: mutants, fileCount: 2)
        #expect(summary.mutationScore == 3.0 / 5.0 * 100)
        let third = MutationReport.Summary(mutants: [mutant(.killed), mutant(.survived), mutant(.survived)], fileCount: 1)
        #expect(third.mutationScore == 1.0 / 3.0 * 100)
    }

    @Test("score is nil when nothing counts: dry run, all ignored, only compile errors")
    func nilScore() {
        #expect(MutationReport.Summary(mutants: [], fileCount: 0).mutationScore == nil)
        #expect(MutationReport.Summary(mutants: [mutant(.pending), mutant(.ignored)], fileCount: 1).mutationScore == nil)
        #expect(MutationReport.Summary(mutants: [mutant(.compileError)], fileCount: 1).mutationScore == nil)
    }

    @Test("status counts always sum to mutantCount")
    func sums() {
        let statuses = MutantStatus.allCases + [.killed, .killed, .survived]
        let s = MutationReport.Summary(mutants: statuses.map { mutant($0) }, fileCount: 5)
        #expect(s.mutantCount == statuses.count)
        let sum = s.killed + s.survived + s.timedOut + s.noCoverage + s.compileErrors + s.ignored + s.pending
        #expect(sum == s.mutantCount)
        let counts: [Int] = [s.killed, s.survived, s.timedOut, s.noCoverage, s.compileErrors, s.ignored, s.pending]
        #expect(counts == [3, 2, 1, 1, 1, 1, 1])
        #expect(s.fileCount == 5)
    }

    @Test("result notes: every tested mutant survived; compile errors")
    func notes() {
        let survivedOnly = MutationReport.Summary(mutants: [mutant(.survived), mutant(.compileError), mutant(.compileError)], fileCount: 1)
        #expect(MutationNotes.resultNotes(survivedOnly) == [
            "Every tested mutant survived. Check that the tests import the source under --path.",
            "2 mutant(s) did not compile and are excluded from the score."
        ])
        let someKilled = MutationReport.Summary(mutants: [mutant(.survived), mutant(.timeout)], fileCount: 1)
        #expect(MutationNotes.resultNotes(someKilled).isEmpty)
        #expect(MutationNotes.coverageRunFailed(exitCode: 1) == "The coverage run exited with code 1; its coverage data was still used.")
        #expect(MutationNotes.noCoverageData == "The baseline test run produced no coverage data, so every mutant was run.")
    }
}

@Suite("JSON report")
struct MutationJSONTests {

    private func object(_ report: MutationReport) throws -> [String: Any] {
        let data = try MutationReportFormatter.json(report)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("top-level and nested keys are sorted; the shape matches the contract")
    func shape() throws {
        let data = try MutationReportFormatter.json(report([mutant(.killed)], notes: ["n"]))
        let text = String(decoding: data, as: UTF8.self)
        let topLevel = ["coverageAvailable", "generatedAt", "mutants", "notes", "operators", "projectRoot",
                        "reportType", "runner", "schemaVersion", "sourceRoot", "summary", "timeoutSeconds",
                        "tool", "toolVersion"]
        let positions = topLevel.map { text.range(of: "\n  \"\($0)\"")?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        let json = try object(report([mutant(.killed)]))
        #expect(Set(json.keys) == Set(topLevel))
        #expect(json["reportType"] as? String == "mutation")
        #expect(json["schemaVersion"] as? String == "1")
        #expect(json["tool"] as? String == "slopguard-swift")
        #expect(json["runner"] as? String == "swift test")
        #expect(json["operators"] as? [String] == [
            "arithmetic", "boolean_literal", "boundary", "increment", "invert_negative",
            "logical", "negate_conditional", "remove_call", "remove_not"
        ])
        let first = try #require((json["mutants"] as? [[String: Any]])?.first)
        #expect(Set(first.keys) == ["column", "file", "id", "line", "method", "operator", "original", "replacement", "status"])
        #expect(first["operator"] as? String == "negate_conditional")
        #expect(first["status"] as? String == "killed")
        let summary = try #require(json["summary"] as? [String: Any])
        #expect(Set(summary.keys) == ["compileErrors", "fileCount", "ignored", "killed", "mutantCount", "mutationScore",
                                      "noCoverage", "pending", "survived", "timedOut"])
    }

    @Test("dry-run nulls are explicit, not omitted")
    func explicitNulls() throws {
        let dry = report([mutant(.pending, method: nil)], projectRoot: nil, runner: nil, timeoutSeconds: nil, coverageAvailable: false)
        let text = String(decoding: try MutationReportFormatter.json(dry), as: UTF8.self)
        #expect(text.contains("\"projectRoot\" : null"))
        #expect(text.contains("\"runner\" : null"))
        #expect(text.contains("\"timeoutSeconds\" : null"))
        #expect(text.contains("\"mutationScore\" : null"))
        #expect(text.contains("\"method\" : null"))
        #expect(text.contains("\"coverageAvailable\" : false"))
    }

    @Test("whole numbers print without .0; generatedAt is UTC with milliseconds")
    func numbersAndDates() throws {
        let text = String(decoding: try MutationReportFormatter.json(report([mutant(.killed)])), as: UTF8.self)
        #expect(text.contains("\"timeoutSeconds\" : 76,") || text.contains("\"timeoutSeconds\" : 76\n"))
        #expect(text.contains("\"mutationScore\" : 100"))
        #expect(text.contains("\"generatedAt\" : \"2026-09-21T14:13:20.250Z\""))
        let given = String(decoding: try MutationReportFormatter.json(report([], timeoutSeconds: 2.5)), as: UTF8.self)
        #expect(given.contains("\"timeoutSeconds\" : 2.5"))
    }

    @Test("the report round-trips through JSON")
    func roundTrip() throws {
        let original = report([mutant(.survived), mutant(.pending, method: nil)], notes: ["a note"])
        let decoded = try JSONDecoder().decode(MutationReport.self, from: MutationReportFormatter.json(original))
        #expect(decoded == original)
    }
}

@Suite("text report")
struct MutationTextTests {

    @Test("header, notes, summary and the sections that list mutants")
    func fullReport() {
        let mutants = [
            mutant(.killed),
            mutant(.survived),
            mutant(.noCoverage, file: "Filter.swift", line: 12, column: 3, op: .removeCall,
                   original: "notify(\n    x\n)", replacement: "", method: nil),
            mutant(.timeout, line: 3, column: 9, op: .boundary, original: "<", replacement: "<="),
            mutant(.ignored)
        ]
        let text = MutationReportFormatter.pretty(report(mutants, notes: ["First note."]))
        #expect(text == """
        slopguard-swift \(SlopguardVersion.version) — mutation report (schema 1)
        source:    /abs/project/Sources
        project:   /abs/project
        runner:    swift test
        timeout:   76s per mutant

        Notes
          • First note.

        Summary
          files:          3
          mutants:        5
          killed:         1
          timed out:      1
          survived:       1
          no coverage:    1
          compile errors: 0
          ignored:        1
          score:          50.00%

        Survived (1) — tests still pass with these changes
          Store.swift:16:25  negate_conditional  `==` → `!=`  Store.toggle(id:)

        No coverage (1) — no test runs these lines
          Filter.swift:12:3  remove_call  `notify( x )` → ``

        Timed out (1) — counted as killed
          Store.swift:3:9  boundary  `<` → `<=`  Store.toggle(id:)

        """)
    }

    @Test("dry run: (not run) headers, a pending row, score n/a and the Mutants section")
    func dryRun() {
        let text = MutationReportFormatter.pretty(report(
            [mutant(.pending), mutant(.ignored)],
            fileCount: 1, projectRoot: nil, runner: nil, timeoutSeconds: nil, coverageAvailable: false
        ))
        #expect(text.contains("project:   (not run)\nrunner:    (not run)\ntimeout:   (not run)\n"))
        #expect(text.contains("  ignored:        1\n  pending:        1\n  score:          n/a\n"))
        #expect(text.contains("\nMutants (1, not run)\n  Store.swift:16:25  negate_conditional  `==` → `!=`  Store.toggle(id:)\n"))
        #expect(!text.contains("Notes"))
    }

    @Test("no pending row without pending mutants")
    func noPendingRow() {
        #expect(!MutationReportFormatter.pretty(report([mutant(.killed)])).contains("pending:"))
    }

    @Test("snippets collapse whitespace and keep 39 code points plus …")
    func snippets() {
        #expect(MutationReportFormatter.snippet("a  \n\t b") == "a b")
        let long = String(repeating: "x", count: 45)
        #expect(MutationReportFormatter.snippet(long) == String(repeating: "x", count: 39) + "…")
        #expect(MutationReportFormatter.snippet(String(repeating: "é", count: 40)) == String(repeating: "é", count: 40))
        #expect(MutationReportFormatter.snippet(String(repeating: "🎉", count: 41)).unicodeScalars.count == 40)
    }

    @Test("seconds print as integers when whole")
    func seconds() {
        #expect(MutationReportFormatter.formatSeconds(16) == "16")
        #expect(MutationReportFormatter.formatSeconds(2.5) == "2.5")
    }
}
