import XCTest
@testable import SlopguardMCP
import SlopguardCore
import SlopguardCoverage
import MCP

final class ToolHandlerTests: XCTestCase {

    private func makeReport(method: MethodMetric, threshold: Double = 30) -> CrapReport {
        let file = FileReport(path: method.file, methods: [method], types: [])
        return CrapAggregator().aggregate(
            fileReports: [file],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: threshold,
            coverage: nil
        )
    }

    func testFindCrappyCodeReturnsTopOffenders() async throws {
        let cache = ReportCache()
        let m = MethodMetric(
            name: "f", qualifiedName: "X.f", typeName: "X", kind: .function,
            file: "X.swift", startLine: 1, endLine: 5, complexity: 12,
            cognitiveComplexity: 12
        )
        let report = makeReport(method: m)
        await cache.store(report: report, sourceRoot: "/tmp", xcresultPath: nil)

        let result = try await FindCrappyCodeTool.definition.handler(
            ["threshold": .double(30), "limit": .int(10), "level": .string("method")],
            AnalysisPipeline(),
            cache
        )
        XCTAssertEqual(result.isError, false)
        // Confirm structuredContent decodes back to a JSON object whose count is 1.
        let structured = try XCTUnwrap(result.structuredContent)
        let object = try XCTUnwrap(structured.objectValue)
        XCTAssertEqual(object["count"]?.intValue, 1)
    }

    func testGetCoverageGapsRequiresCoverage() async throws {
        let cache = ReportCache()
        let m = MethodMetric(
            name: "f", qualifiedName: "X.f", typeName: "X", kind: .function,
            file: "X.swift", startLine: 1, endLine: 5, complexity: 12,
            cognitiveComplexity: 12
        )
        // Report without coverage available.
        let report = makeReport(method: m)
        await cache.store(report: report, sourceRoot: "/tmp", xcresultPath: nil)

        let result = try await GetCoverageGapsTool.definition.handler(
            [:],
            AnalysisPipeline(),
            cache
        )
        XCTAssertEqual(result.isError, true)
    }

    func testSuggestRefactorReturnsHints() async throws {
        let cache = ReportCache()
        let m = MethodMetric(
            name: "huge", qualifiedName: "X.huge", typeName: "X", kind: .function,
            file: "X.swift", startLine: 1, endLine: 50, complexity: 20,
            cognitiveComplexity: 20
        )
        let report = makeReport(method: m)
        await cache.store(report: report, sourceRoot: "/tmp", xcresultPath: nil)

        let methodId = report.methods[0].id
        let result = try await SuggestRefactorTool.definition.handler(
            ["methodId": .string(methodId)],
            AnalysisPipeline(),
            cache
        )
        XCTAssertEqual(result.isError, false)
        let structured = try XCTUnwrap(result.structuredContent)
        let object = try XCTUnwrap(structured.objectValue)
        let suggestions = try XCTUnwrap(object["suggestions"]?.arrayValue)
        XCTAssertGreaterThan(suggestions.count, 0)
    }

    // MARK: - SuggestRefactorTool branch coverage

    private func suggestionCodes(for method: MethodCrap) -> Set<String> {
        Set(SuggestRefactorTool.makeSuggestions(for: method).map { $0.code })
    }

    private func methodCrap(
        complexity: Int,
        coverage: Double,
        cognitiveComplexity: Int? = nil,
        kind: MethodKind = .function,
        qualifiedName: String = "X.f"
    ) -> MethodCrap {
        // Default cognitive to cyclomatic so the GM blend equals the input —
        // preserves the heuristic-firing math for tests written before
        // schema-2's cognitive gating. Pass `cognitiveComplexity:` explicitly
        // for the flat-dispatch / skew tests.
        let cog = cognitiveComplexity ?? complexity
        let weighted = (Double(complexity) * Double(cog)).squareRoot()
        return MethodCrap(
            id: "X.swift#\(qualifiedName)@1",
            file: "X.swift",
            line: 1,
            endLine: 5,
            typeName: "X",
            name: "f",
            qualifiedName: qualifiedName,
            kind: kind,
            complexity: complexity,
            cognitiveComplexity: cog,
            weightedComplexity: weighted,
            coverage: coverage,
            crap: 0,
            isCrappy: false
        )
    }

    func testSuggestRefactorWriteTestsFirstFiresOnUncoveredComplexCode() {
        let codes = suggestionCodes(for: methodCrap(complexity: 8, coverage: 5))
        XCTAssertTrue(codes.contains("write_tests_first"))
    }

    func testSuggestRefactorExtractMethodFiresAtComplexityFifteen() {
        let codes = suggestionCodes(for: methodCrap(complexity: 15, coverage: 60))
        XCTAssertTrue(codes.contains("extract_method"))
    }

    func testSuggestRefactorTableDrivenForBranchyFunctions() {
        let codes = suggestionCodes(for: methodCrap(complexity: 9, coverage: 50, qualifiedName: "X.dispatch"))
        XCTAssertTrue(codes.contains("table_driven_dispatch"))
    }

    func testSuggestRefactorFactoryForBranchyInits() {
        let codes = suggestionCodes(for: methodCrap(
            complexity: 6, coverage: 50, kind: .initializer, qualifiedName: "X.init"
        ))
        XCTAssertTrue(codes.contains("factory_method"))
    }

    func testSuggestRefactorWellTestedButComplex() {
        let codes = suggestionCodes(for: methodCrap(complexity: 14, coverage: 92))
        XCTAssertTrue(codes.contains("well_tested_but_complex"))
    }

    /// When nothing matches the heuristic thresholds we still return a
    /// `no_action` placeholder so the agent can show *something*.
    func testSuggestRefactorNoActionFallback() {
        let codes = suggestionCodes(for: methodCrap(complexity: 2, coverage: 100))
        XCTAssertEqual(codes, ["no_action"])
    }

    /// Schema-2 regression: a high-cyclomatic / low-cognitive method (large
    /// flat switch, one-line returns) is *already* a clean dispatch shape.
    /// `extract_method` and `table_driven_dispatch` would be misdirection —
    /// the heuristic must skip them in favour of the no-op suggestion when
    /// nothing else fires.
    func testSuggestRefactorSkipsTableDispatchForFlatSwitchShape() {
        let codes = suggestionCodes(for: methodCrap(
            complexity: 85, coverage: 90, cognitiveComplexity: 2
        ))
        XCTAssertFalse(codes.contains("table_driven_dispatch"),
                       "flat dispatch (cyc=85, cog=2) should not be told to add a dispatch table")
        XCTAssertFalse(codes.contains("extract_method"),
                       "flat dispatch has nothing meaningful to extract")
    }

    /// Genuinely complex code — both cyc and cog elevated — still gets the
    /// extract / dispatch suggestions the agent expects.
    func testSuggestRefactorStillFiresForGenuinelyComplexCode() {
        let codes = suggestionCodes(for: methodCrap(
            complexity: 16, coverage: 50, cognitiveComplexity: 16
        ))
        XCTAssertTrue(codes.contains("extract_method"))
        XCTAssertTrue(codes.contains("table_driven_dispatch"))
    }

    func testSuggestRefactorSuggestionsSortedByPriority() {
        let suggestions = SuggestRefactorTool.makeSuggestions(
            for: methodCrap(complexity: 16, coverage: 5)
        )
        let priorities = suggestions.map { $0.priority }
        XCTAssertEqual(priorities, priorities.sorted(),
                       "suggestions should be sorted by ascending priority")
    }

    func testToolDescriptorHasInputSchema() {
        for tool in [
            AnalyzeDirectoryTool.definition,
            AnalyzeFileTool.definition,
            GetCrapReportTool.definition,
            FindCrappyCodeTool.definition,
            GetCoverageGapsTool.definition,
            SuggestRefactorTool.definition
        ] {
            let descriptor = tool.descriptor
            XCTAssertFalse(descriptor.name.isEmpty)
            XCTAssertNotNil(descriptor.description)
            XCTAssertNotNil(descriptor.inputSchema.objectValue?["type"])
        }
    }
}
