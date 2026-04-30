import XCTest
@testable import SlopguardMCP
import SlopguardCoverage

/// Pure-helper tests for ToolUtilities. Covers the value-coercion shims that
/// the MCP tool handlers use to parse loosely-typed `[String: JSONValue]` arguments.
final class ToolUtilitiesTests: XCTestCase {

    func testStringExtractsPresentValue() {
        let args: [String: JSONValue] = ["k": .string("hello")]
        XCTAssertEqual(ToolUtilities.string(args, "k"), "hello")
        XCTAssertNil(ToolUtilities.string(args, "missing"))
        XCTAssertNil(ToolUtilities.string(nil, "k"))
    }

    func testDoubleAcceptsBothNumberShapes() {
        // Some clients send `30` as int, others as double. The helper bridges.
        XCTAssertEqual(ToolUtilities.double(["k": .int(30)], "k"), 30.0)
        XCTAssertEqual(ToolUtilities.double(["k": .double(30.5)], "k"), 30.5)
        XCTAssertNil(ToolUtilities.double(["k": .string("nope")], "k"))
        XCTAssertNil(ToolUtilities.double(nil, "k"))
    }

    func testIntAcceptsBothNumberShapes() {
        XCTAssertEqual(ToolUtilities.int(["k": .int(7)], "k"), 7)
        XCTAssertEqual(ToolUtilities.int(["k": .double(7.9)], "k"), 7)  // truncates toward zero
        XCTAssertNil(ToolUtilities.int(["k": .string("nope")], "k"))
        XCTAssertNil(ToolUtilities.int(nil, "k"))
    }

    func testStringArrayFiltersNonStrings() {
        let args: [String: JSONValue] = [
            "k": .array([.string("a"), .int(2), .string("b")])
        ]
        XCTAssertEqual(ToolUtilities.stringArray(args, "k"), ["a", "b"])
    }

    /// Empty arrays return `nil` so callers can tell "missing" from "[]".
    func testStringArrayReturnsNilWhenEmpty() {
        XCTAssertNil(ToolUtilities.stringArray(["k": .array([])], "k"))
        XCTAssertNil(ToolUtilities.stringArray(["k": .array([.int(1)])], "k"))
        XCTAssertNil(ToolUtilities.stringArray(nil, "k"))
        XCTAssertNil(ToolUtilities.stringArray([:], "missing"))
    }

    func testResolvePathExpandsTilde() {
        let url = ToolUtilities.resolvePath("~/foo")
        XCTAssertTrue(url.path.hasSuffix("/foo"))
        XCTAssertFalse(url.path.contains("~"))
    }

    func testResolvePathHandlesAbsolute() {
        let url = ToolUtilities.resolvePath("/etc/hosts")
        XCTAssertEqual(url.path, "/etc/hosts")
    }

    func testResolvePathResolvesRelativeAgainstCwd() {
        let url = ToolUtilities.resolvePath("Sources")
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertTrue(url.path.hasSuffix("/Sources"))
    }

    /// `autoCoverage` always returns `.auto`; scheme/destination optional.
    /// `projectDirectory` MUST stay nil so the pipeline discovers the real
    /// project root from the analyzed source URL — pinning it to anything
    /// here (e.g. CWD) would resurrect the MCP "0% coverage" bug, where
    /// xcodebuild builds whatever package is next to the server process
    /// instead of the user's project.
    func testAutoCoverageBuildsAutoSourceWithDefaults() {
        let cov = ToolUtilities.autoCoverage(nil)
        guard case .auto(let opts) = cov else {
            return XCTFail("expected .auto")
        }
        XCTAssertNil(opts.projectDirectory)
        XCTAssertNil(opts.scheme)
        XCTAssertEqual(opts.destination, "platform=macOS")
    }

    func testAutoCoverageHonorsExplicitSchemeAndDestination() {
        let cov = ToolUtilities.autoCoverage([
            "scheme": .string("MyApp-Package"),
            "destination": .string("platform=iOS Simulator,name=iPhone 15")
        ])
        guard case .auto(let opts) = cov else {
            return XCTFail("expected .auto")
        }
        XCTAssertEqual(opts.scheme, "MyApp-Package")
        XCTAssertEqual(opts.destination, "platform=iOS Simulator,name=iPhone 15")
    }
}
