import XCTest
@testable import SlopguardCore

final class CrapReportFormatterTests: XCTestCase {

    private func makeReport(
        methods: [MethodMetric] = [],
        threshold: Double = 30,
        coverage: (any CoverageProvider)? = nil,
        xcresult: String? = nil
    ) -> CrapReport {
        let file = FileReport(path: "F.swift", methods: methods, types: [])
        return CrapAggregator().aggregate(
            fileReports: [file],
            sourceRootURL: URL(fileURLWithPath: "/tmp/proj"),
            xcresultPath: xcresult,
            threshold: threshold,
            coverage: coverage
        )
    }

    private func method(name: String, complexity: Int, line: Int = 1, endLine: Int = 5) -> MethodMetric {
        MethodMetric(
            name: name, qualifiedName: "X.\(name)", typeName: "X",
            kind: .function, file: "F.swift",
            startLine: line, endLine: endLine, complexity: complexity,
            cognitiveComplexity: complexity
        )
    }

    func testPrettyHeaderAndSummary() {
        let report = makeReport(methods: [method(name: "f", complexity: 3)])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("slopguard-swift"))
        XCTAssertTrue(output.contains("source:"))
        XCTAssertTrue(output.contains("threshold: 30.0"))
        XCTAssertTrue(output.contains("Summary"))
        XCTAssertTrue(output.contains("methods:"))
    }

    func testPrettyShowsCoverageUnavailableWhenNoXcresult() {
        let report = makeReport(methods: [method(name: "f", complexity: 1)])
        XCTAssertTrue(CrapReportFormatter.pretty(report).contains("coverage:  unavailable"))
    }

    func testPrettyShowsCoveragePercentWhenAvailable() {
        struct StubCov: CoverageProvider {
            func methodCoverage(absolutePath: String, line: Int, endLine: Int) -> Double? { 75.0 }
            func fileCoverage(absolutePath: String) -> Double? { 75.0 }
        }
        let report = makeReport(
            methods: [method(name: "f", complexity: 1)],
            coverage: StubCov(),
            xcresult: "/tmp/x.xcresult"
        )
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("75.0%"))
    }

    /// Even when no method crosses the threshold, the report should still rank
    /// the top hotspots so the user/agent has somewhere to go next.
    func testPrettyShowsHotspotsWhenNothingCrappy() {
        let report = makeReport(methods: [method(name: "small", complexity: 1)])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("Top methods by wCRAP"))
        XCTAssertTrue(output.contains("none above threshold"))
        XCTAssertTrue(output.contains("X.small"),
                       "the lone method should still appear in the hotspots table")
    }

    func testPrettyListsCrappyMethods() {
        let crappy = method(name: "huge", complexity: 12, line: 7, endLine: 50)
        let report = makeReport(methods: [crappy])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("Top methods by wCRAP"))
        XCTAssertTrue(output.contains("above threshold"))
        XCTAssertTrue(output.contains("wCRAP"),
                       "heading should label the score as wCRAP so users don't confuse it with classic Pearson CRAP")
        XCTAssertTrue(output.contains("X.huge"))
        XCTAssertTrue(output.contains("F.swift:7"))
    }

    /// Crappy rows are prefixed with `!`; non-crappy rows with a space, so a
    /// glance at the table separates "fix now" from "watch".
    func testPrettyMarksCrappyRowsWithBang() {
        let crappy = method(name: "huge", complexity: 12, line: 7, endLine: 50)
        let clean = method(name: "tiny", complexity: 1, line: 60, endLine: 62)
        let report = makeReport(methods: [crappy, clean])
        let output = CrapReportFormatter.pretty(report)
        let crappyLine = try? XCTUnwrap(output.split(separator: "\n").first { $0.contains("X.huge") })
        let cleanLine = try? XCTUnwrap(output.split(separator: "\n").first { $0.contains("X.tiny") })
        XCTAssertTrue((crappyLine ?? "").trimmingCharacters(in: .whitespaces).hasPrefix("!"))
        XCTAssertFalse((cleanLine ?? "").trimmingCharacters(in: .whitespaces).hasPrefix("!"))
    }

    /// Per-row format renders `cyc=`, `cog=`, `wt=` so the agent can see why
    /// a high cyclomatic might still produce a small CRAP score (flat
    /// dispatch shape) vs. a genuinely complex method (cyc and cog both up).
    func testPrettyRowExposesCycCogWt() {
        let crappy = method(name: "huge", complexity: 12, line: 7, endLine: 50)
        let report = makeReport(methods: [crappy])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("cyc=12"))
        XCTAssertTrue(output.contains("cog=12"))
        XCTAssertTrue(output.contains("wt="))
    }

    /// Summary advertises the three averaged signals — cyclomatic, cognitive,
    /// and the weighted GM that drives the CRAP score.
    func testPrettySummaryAdvertisesCycCogWtAverages() {
        let report = makeReport(methods: [method(name: "f", complexity: 4)])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("avg cyc:"))
        XCTAssertTrue(output.contains("avg cog:"))
        XCTAssertTrue(output.contains("avg wt:"))
    }

    func testPrettyTopNRespectsLimit() {
        let methods = (0..<5).map { method(name: "m\($0)", complexity: 12, line: $0 + 1, endLine: $0 + 5) }
        let report = makeReport(methods: methods)
        let output = CrapReportFormatter.pretty(report, topN: 2)
        // Only 2 entries should appear after the header line.
        let crappyLines = output.split(separator: "\n").filter { $0.contains("X.m") }
        XCTAssertEqual(crappyLines.count, 2)
    }

    /// Every schema-2 report carries the standing note describing the weighted
    /// complexity blend, so the Notes block is always rendered. (Pre-schema-2
    /// reports used to omit it when no diagnostics were attached.)
    func testPrettyAlwaysRendersSchemaTwoNote() {
        let report = makeReport(methods: [method(name: "f", complexity: 1)])
        let output = CrapReportFormatter.pretty(report)
        XCTAssertTrue(output.contains("Notes\n"))
        XCTAssertTrue(output.contains("weightedComplexity"))
    }

    func testPrettyShowsNotesBlockWhenAttached() {
        let base = makeReport(methods: [method(name: "f", complexity: 1)])
        let withNote = CrapReport(
            toolVersion: base.toolVersion,
            sourceRoot: base.sourceRoot,
            xcresultPath: base.xcresultPath,
            threshold: base.threshold,
            coverageAvailable: base.coverageAvailable,
            notes: ["No tests were detected — every method is reported at 0% coverage."],
            summary: base.summary,
            methods: base.methods,
            types: base.types
        )
        let output = CrapReportFormatter.pretty(withNote)
        XCTAssertTrue(output.contains("Notes\n"))
        XCTAssertTrue(output.contains("No tests were detected"))
    }

    func testJSONIsValidAndRoundTrips() throws {
        let report = makeReport(methods: [method(name: "f", complexity: 4)])
        let data = try CrapReportFormatter.json(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CrapReport.self, from: data)
        XCTAssertEqual(decoded.methods.count, 1)
        XCTAssertEqual(decoded.threshold, 30)
    }

    func testJSONKeysAreSorted() throws {
        let report = makeReport(methods: [method(name: "f", complexity: 1)])
        let data = try CrapReportFormatter.json(report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        // sortedKeys means coverageAvailable < generatedAt < methods alphabetically.
        if let covIdx = text.range(of: "\"coverageAvailable\""),
           let methIdx = text.range(of: "\"methods\"") {
            XCTAssertLessThan(covIdx.lowerBound, methIdx.lowerBound)
        } else {
            XCTFail("expected both keys present")
        }
    }

    func testErrorTextSingleLine() {
        let env = SlopguardErrorEnvelope(.fileNotFound(path: "/x"))
        let text = CrapReportFormatter.errorText(env)
        XCTAssertEqual(text, "slopguard-swift: [file_not_found] File not found: /x")
        XCTAssertFalse(text.contains("\n"))
    }

    func testErrorJSONShape() throws {
        let env = SlopguardErrorEnvelope(.invalidArgument(name: "path", reason: "missing"))
        let data = try CrapReportFormatter.errorJSON(env)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_argument")
        XCTAssertEqual(error["message"] as? String, "Invalid argument 'path': missing")
    }
}
