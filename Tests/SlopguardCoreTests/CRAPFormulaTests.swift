import XCTest
@testable import SlopguardCore

final class CRAPFormulaTests: XCTestCase {

    func testZeroComplexityIsZero() {
        XCTAssertEqual(CRAP.score(complexity: 0.0, coveragePercent: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(CRAP.score(complexity: 0.0, coveragePercent: 100), 0, accuracy: 1e-9)
    }

    func testFullCoverageCollapsesToComplexity() {
        // (1 - 100/100)^3 = 0 → score = comp
        for c in 1...20 {
            XCTAssertEqual(
                CRAP.score(complexity: Double(c), coveragePercent: 100),
                Double(c),
                accuracy: 1e-9,
                "comp=\(c)"
            )
        }
    }

    func testZeroCoverageQuadratic() {
        // (1 - 0/100)^3 = 1 → score = comp² + comp
        XCTAssertEqual(CRAP.score(complexity: 1.0, coveragePercent: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(CRAP.score(complexity: 5.0, coveragePercent: 0), 30, accuracy: 1e-9)
        XCTAssertEqual(CRAP.score(complexity: 10.0, coveragePercent: 0), 110, accuracy: 1e-9)
    }

    func testThresholdBoundaryAtComp5Cov0() {
        // comp=5, cov=0 → 25 + 5 = 30 → exactly the default threshold (not crappy under > rule)
        XCTAssertEqual(CRAP.score(complexity: 5.0, coveragePercent: 0), 30, accuracy: 1e-9)
    }

    func testCoverageClamping() {
        // Coverage outside [0, 100] is clamped.
        XCTAssertEqual(
            CRAP.score(complexity: 5.0, coveragePercent: -10),
            CRAP.score(complexity: 5.0, coveragePercent: 0),
            accuracy: 1e-9
        )
        XCTAssertEqual(
            CRAP.score(complexity: 5.0, coveragePercent: 200),
            CRAP.score(complexity: 5.0, coveragePercent: 100),
            accuracy: 1e-9
        )
    }

    func testNegativeComplexityClamped() {
        XCTAssertEqual(CRAP.score(complexity: -3.0, coveragePercent: 0), 0, accuracy: 1e-9)
    }

    func testHalfCoverage() {
        // (1 - 50/100)^3 = 0.125 → comp² * 0.125 + comp
        // comp=10, cov=50 → 100 * 0.125 + 10 = 22.5
        XCTAssertEqual(CRAP.score(complexity: 10.0, coveragePercent: 50), 22.5, accuracy: 1e-9)
    }

    /// Schema-2 weighted blend: when slopguard feeds `sqrt(cyc × cog)` as
    /// `comp`, the formula's `comp²` term simplifies to `cyc × cog` (the GM
    /// identity). The user-reported `mapToDevice` case (cyc=85, cog=1, cov=0)
    /// thus drops from a cyclomatic-driven 7310 to a weighted ~94. Lock that
    /// number in so a regression in the math is caught at the unit level.
    func testWeightedBlendIdentityForFlatDispatch() {
        let cyc = 85.0
        let cog = 1.0
        let weighted = (cyc * cog).squareRoot()
        let crap = CRAP.score(complexity: weighted, coveragePercent: 0)
        // Expected: cyc × cog × 1.0 + sqrt(cyc × cog) = 85 + 9.2195... = 94.22
        XCTAssertEqual(crap, 85.0 + weighted, accuracy: 1e-9)
        XCTAssertEqual(crap, 94.21954445729288, accuracy: 1e-6)
    }

    func testAggregate() {
        let agg = CRAP.aggregate([2.0, 30.0, 110.0, 5.0])
        XCTAssertEqual(agg.sum, 147.0, accuracy: 1e-9)
        XCTAssertEqual(agg.max, 110.0, accuracy: 1e-9)
        XCTAssertEqual(agg.methodCount, 4)
    }

    func testAggregateEmpty() {
        let agg = CRAP.aggregate([Double]())
        XCTAssertEqual(agg.sum, 0, accuracy: 1e-9)
        XCTAssertEqual(agg.max, 0, accuracy: 1e-9)
        XCTAssertEqual(agg.methodCount, 0)
    }

    func testDefaultThreshold() {
        XCTAssertEqual(CRAP.defaultThreshold, 30.0, accuracy: 1e-9)
    }
}
