import XCTest
@testable import SlopguardCoverage

/// Pure-decode tests for the JSON walkers. The subprocess paths are exercised
/// integration-style only — here we just lock down that the JSON shapes
/// modern + legacy xcresulttool produce map to a sensible test count.
final class XcresultProbeTests: XCTestCase {

    func testModernJSONWalksTestNodes() throws {
        let json = """
        {
          "testNodes": [
            { "nodeType": "Test Plan",
              "children": [
                { "nodeType": "Test Bundle",
                  "children": [
                    { "nodeType": "Test Suite",
                      "children": [
                        { "nodeType": "Test Case", "name": "a" },
                        { "nodeType": "Test Case", "name": "b" }
                      ]}
                  ]}
              ]}
          ]
        }
        """.data(using: .utf8)!
        XCTAssertEqual(XcresultProbe.countTestCases(modernJSON: json), 2)
    }

    func testModernJSONWithEmptyNodesReportsZero() throws {
        let json = #"{"testNodes": []}"#.data(using: .utf8)!
        XCTAssertEqual(XcresultProbe.countTestCases(modernJSON: json), 0)
    }

    func testModernJSONUnrecognisedShapeReturnsNil() throws {
        let json = #"{"unrelated": "shape"}"#.data(using: .utf8)!
        // Missing testNodes field — be conservative, count = 0 (genuinely empty).
        XCTAssertEqual(XcresultProbe.countTestCases(modernJSON: json), 0)
    }

    func testModernJSONGarbageReturnsNil() {
        let bad = Data("not json".utf8)
        XCTAssertNil(XcresultProbe.countTestCases(modernJSON: bad))
    }

    func testLegacyJSONWithTestsRefIsTreatedAsAtLeastOne() throws {
        let json = """
        {
          "actions": {
            "_values": [
              { "actionResult": { "testsRef": { "id": "abc" } } }
            ]
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(XcresultProbe.countTestCases(legacyJSON: json), 1)
    }

    func testLegacyJSONWithoutTestsRefReportsZero() throws {
        let json = """
        {
          "actions": {
            "_values": [
              { "actionResult": { } }
            ]
          }
        }
        """.data(using: .utf8)!
        XCTAssertEqual(XcresultProbe.countTestCases(legacyJSON: json), 0)
    }
}
