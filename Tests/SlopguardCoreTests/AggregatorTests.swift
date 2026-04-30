import XCTest
@testable import SlopguardCore

final class AggregatorTests: XCTestCase {

    private struct StubCoverage: CoverageProvider {
        let methodPercent: Double
        let filePercent: Double
        func methodCoverage(absolutePath: String, line: Int, endLine: Int) -> Double? { methodPercent }
        func fileCoverage(absolutePath: String) -> Double? { filePercent }
    }

    private func makeMethod(
        name: String = "f",
        type: String? = nil,
        kind: MethodKind = .function,
        startLine: Int = 1,
        endLine: Int = 5,
        complexity: Int,
        cognitiveComplexity: Int? = nil
    ) -> MethodMetric {
        let qualified = type.map { "\($0).\(name)" } ?? name
        // Default cognitive to `complexity` so the weighted GM equals
        // cyclomatic — preserves the math for tests written before schema 2
        // that assert specific CRAP values. Explicit `cognitiveComplexity:`
        // overrides for the new "cyc != cog" regression tests.
        let cog = cognitiveComplexity ?? complexity
        return MethodMetric(
            name: name,
            qualifiedName: qualified,
            typeName: type,
            kind: kind,
            file: "F.swift",
            startLine: startLine,
            endLine: endLine,
            complexity: complexity,
            cognitiveComplexity: cog
        )
    }

    func testNoCoverageDefaultsToZeroPercent() {
        let m = makeMethod(complexity: 5)
        let report = FileReport(path: "F.swift", methods: [m], types: [])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        XCTAssertEqual(crap.methods.count, 1)
        XCTAssertEqual(crap.methods[0].coverage, 0, accuracy: 1e-9)
        XCTAssertEqual(crap.methods[0].crap, 30, accuracy: 1e-9)
        XCTAssertFalse(crap.methods[0].isCrappy) // 30 > 30 is false
        XCTAssertNil(crap.summary.weightedCoverage)
        XCTAssertFalse(crap.coverageAvailable)
    }

    func testCoverageIsApplied() {
        let m = makeMethod(complexity: 10)
        let report = FileReport(path: "F.swift", methods: [m], types: [])
        let cov = StubCoverage(methodPercent: 50, filePercent: 50)
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: "/tmp/x.xcresult",
            threshold: 30,
            coverage: cov
        )
        XCTAssertEqual(crap.methods[0].coverage, 50, accuracy: 1e-9)
        XCTAssertEqual(crap.methods[0].crap, 22.5, accuracy: 1e-9)
        XCTAssertFalse(crap.methods[0].isCrappy)
        XCTAssertTrue(crap.coverageAvailable)
    }

    func testCrappyClassification() {
        // comp=10, cov=0 → crap=110 → above threshold 30
        let m = makeMethod(complexity: 10)
        let report = FileReport(path: "F.swift", methods: [m], types: [])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        XCTAssertTrue(crap.methods[0].isCrappy)
        XCTAssertEqual(crap.summary.crappyMethodCount, 1)
    }

    func testTypeAggregationSumsAndMax() {
        let m1 = makeMethod(name: "a", type: "C", complexity: 10)
        let m2 = makeMethod(name: "b", type: "C", startLine: 6, endLine: 8, complexity: 3)
        let typeMetric = TypeMetric(
            kind: .class,
            name: "C",
            file: "F.swift",
            startLine: 1,
            endLine: 10,
            methodIDs: [m1.id, m2.id],
            methodCount: 2,
            totalComplexity: 13,
            maxComplexity: 10,
            // Cognitive defaults equal cyclomatic in the helper so the weighted
            // GM equals the input — preserves pre-schema-2 expected CRAP math.
            totalCognitiveComplexity: 13,
            maxCognitiveComplexity: 10
        )
        let report = FileReport(path: "F.swift", methods: [m1, m2], types: [typeMetric])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        XCTAssertEqual(crap.types.count, 1)
        let t = crap.types[0]
        XCTAssertEqual(t.methodCount, 2)
        XCTAssertEqual(t.totalComplexity, 13)
        XCTAssertEqual(t.maxComplexity, 10)
        // Methods at 0% coverage: crap(10) = 110, crap(3) = 12 → sum 122, max 110
        XCTAssertEqual(t.sumCrap, 122, accuracy: 1e-9)
        XCTAssertEqual(t.maxCrap, 110, accuracy: 1e-9)
        XCTAssertTrue(t.isCrappy)
    }

    func testMethodsSortedByCrapDescending() {
        let m1 = makeMethod(name: "small", complexity: 2)
        let m2 = makeMethod(name: "huge", startLine: 6, endLine: 10, complexity: 12)
        let report = FileReport(path: "F.swift", methods: [m1, m2], types: [])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        XCTAssertEqual(crap.methods.first?.name, "huge")
        XCTAssertEqual(crap.methods.last?.name, "small")
    }

    /// Schema-2 regression: the user-reported `UIDevice.mapToDevice(identifier:)`
    /// shape — a 50-case flat dispatch with one-line returns — used to score
    /// CRAP ≈ 7310 (cyc=85 squared into the formula). Under schema 2 the
    /// weighted GM = sqrt(85 × 1) ≈ 9.22, dropping the score to ≈ 94. Lock
    /// that number in so the math regression is caught at the aggregator level
    /// (not just in the formula unit test).
    func testMapToDeviceFlatDispatchScoresAroundNinetyFour() {
        let m = makeMethod(complexity: 85, cognitiveComplexity: 1)
        let report = FileReport(path: "F.swift", methods: [m], types: [])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        XCTAssertEqual(crap.methods[0].weightedComplexity, 9.219544457292887, accuracy: 1e-6)
        // (1 - 0/100)^3 = 1, so crap = (cyc × cog) + sqrt(cyc × cog) = 85 + 9.22
        XCTAssertEqual(crap.methods[0].crap, 94.21954445729288, accuracy: 1e-6)
        XCTAssertTrue(crap.methods[0].isCrappy) // 94 > 30 — still penalised at 0% coverage
    }

    func testReportIsRoundTripCodable() throws {
        let m = makeMethod(complexity: 7)
        let report = FileReport(path: "F.swift", methods: [m], types: [])
        let crap = CrapAggregator().aggregate(
            fileReports: [report],
            sourceRootURL: URL(fileURLWithPath: "/tmp"),
            xcresultPath: nil,
            threshold: 30,
            coverage: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(crap)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CrapReport.self, from: data)
        XCTAssertEqual(decoded.methods.count, crap.methods.count)
        XCTAssertEqual(decoded.threshold, crap.threshold)
    }
}
