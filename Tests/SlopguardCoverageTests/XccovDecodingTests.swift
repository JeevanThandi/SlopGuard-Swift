import XCTest
@testable import SlopguardCoverage
import SlopguardCore

final class XccovDecodingTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name.replacingOccurrences(of: ".json", with: ""), withExtension: "json", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    func testDecode() throws {
        let data = try loadFixture("sample.xccov.json")
        let report = try JSONDecoder().decode(XccovReport.self, from: data)
        XCTAssertEqual(report.lineCoverage, 0.4, accuracy: 1e-6)
        XCTAssertEqual(report.targets.count, 1)
        XCTAssertEqual(report.targets[0].files.count, 2)
        XCTAssertEqual(report.targets[0].files[0].functions.count, 2)
        XCTAssertEqual(report.targets[0].files[0].functions[0].lineCoverage, 0.5, accuracy: 1e-6)
    }

    func testCoverageIndexLookup() throws {
        let data = try loadFixture("sample.xccov.json")
        let report = try JSONDecoder().decode(XccovReport.self, from: data)
        let index = CoverageIndex(report: report)

        // Function at line 10 → 50% coverage; query inside its range.
        let pct = index.coverage(forAbsolutePath: "/Users/dev/MyApp/Sources/Foo.swift", line: 10, endLine: 20)
        XCTAssertEqual(try XCTUnwrap(pct), 50.0, accuracy: 1e-6)

        // Function at line 30 → 0% coverage.
        let pct2 = index.coverage(forAbsolutePath: "/Users/dev/MyApp/Sources/Foo.swift", line: 30, endLine: 50)
        XCTAssertEqual(try XCTUnwrap(pct2), 0.0, accuracy: 1e-6)

        // No matching function range → nil (caller should fall back to file-level).
        let pct3 = index.coverage(forAbsolutePath: "/Users/dev/MyApp/Sources/Foo.swift", line: 100, endLine: 200)
        XCTAssertNil(pct3)

        // File-level fallback.
        let fileCov = index.fileCoverage(forAbsolutePath: "/Users/dev/MyApp/Sources/Foo.swift")
        XCTAssertEqual(try XCTUnwrap(fileCov), 30.0, accuracy: 1e-6)
    }

    func testBasenameFallbackWhenAbsolutePathDiffers() throws {
        let data = try loadFixture("sample.xccov.json")
        let report = try JSONDecoder().decode(XccovReport.self, from: data)
        let index = CoverageIndex(report: report)

        // CI checkout has a different prefix but the same suffix; the index should still find it.
        let pct = index.coverage(
            forAbsolutePath: "/Users/runner/work/MyApp/MyApp/Sources/Foo.swift",
            line: 10,
            endLine: 20
        )
        XCTAssertEqual(try XCTUnwrap(pct), 50.0, accuracy: 1e-6)
    }

    func testMissingFileReturnsNil() throws {
        let data = try loadFixture("sample.xccov.json")
        let report = try JSONDecoder().decode(XccovReport.self, from: data)
        let index = CoverageIndex(report: report)

        let pct = index.coverage(forAbsolutePath: "/no/such/file.swift", line: 1, endLine: 1)
        XCTAssertNil(pct)
    }

    /// When two distinct files share a basename (e.g. `Models/User.swift` and
    /// `Mocks/User.swift`), `lookupFile` falls through to the suffix-overlap
    /// tie-breaker. The query path's longer shared suffix wins.
    func testSuffixTieBreakerPicksLongestOverlap() throws {
        let json = #"""
        {
          "coveredLines": 30, "executableLines": 100, "lineCoverage": 0.3,
          "targets": [{
            "name": "T", "coveredLines": 30, "executableLines": 100, "lineCoverage": 0.3,
            "files": [
              {
                "name": "User.swift",
                "path": "/A/Sources/Models/User.swift",
                "coveredLines": 20, "executableLines": 50, "lineCoverage": 0.4,
                "functions": [{
                  "name": "User.init", "lineNumber": 5, "executionCount": 1,
                  "coveredLines": 4, "executableLines": 5, "lineCoverage": 0.8
                }]
              },
              {
                "name": "User.swift",
                "path": "/A/Tests/Mocks/User.swift",
                "coveredLines": 10, "executableLines": 50, "lineCoverage": 0.2,
                "functions": [{
                  "name": "MockUser.init", "lineNumber": 5, "executionCount": 1,
                  "coveredLines": 1, "executableLines": 5, "lineCoverage": 0.2
                }]
              }
            ]
          }]
        }
        """#
        let report = try JSONDecoder().decode(XccovReport.self, from: Data(json.utf8))
        let index = CoverageIndex(report: report)

        // CI-style prefix; longer shared suffix is `/Models/User.swift` → first file (80%).
        let modelsHit = index.coverage(
            forAbsolutePath: "/runner/checkout/Sources/Models/User.swift",
            line: 5, endLine: 10
        )
        XCTAssertEqual(try XCTUnwrap(modelsHit), 80.0, accuracy: 1e-6)

        // Different prefix; longer shared suffix is `/Mocks/User.swift` → second file (20%).
        let mocksHit = index.coverage(
            forAbsolutePath: "/runner/checkout/Tests/Mocks/User.swift",
            line: 5, endLine: 10
        )
        XCTAssertEqual(try XCTUnwrap(mocksHit), 20.0, accuracy: 1e-6)
    }
}
