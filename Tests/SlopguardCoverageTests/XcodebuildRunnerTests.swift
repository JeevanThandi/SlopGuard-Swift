import XCTest
@testable import SlopguardCoverage
import SlopguardCore

/// Pure-logic tests for XcodebuildRunner. The actual subprocess paths are
/// exercised end-to-end in CI by running the CLI against this very repo —
/// here we just lock down the scheme-discovery helpers so they don't drift.
final class XcodebuildRunnerTests: XCTestCase {

    func testDecodeSchemesFromWorkspaceListing() throws {
        let json = Data("""
        { "workspace": { "schemes": ["MyApp", "MyApp-Package", "MyAppKit"] } }
        """.utf8)
        XCTAssertEqual(try XcodebuildRunner.decodeSchemes(data: json),
                       ["MyApp", "MyApp-Package", "MyAppKit"])
    }

    /// `xcodebuild -list -json` against a `.xcodeproj` reports under "project"
    /// instead of "workspace" — make sure both shapes decode.
    func testDecodeSchemesFromProjectListing() throws {
        let json = Data("""
        { "project": { "schemes": ["Solo"] } }
        """.utf8)
        XCTAssertEqual(try XcodebuildRunner.decodeSchemes(data: json), ["Solo"])
    }

    func testDecodeSchemesEmpty() throws {
        let json = Data("{ \"workspace\": { \"schemes\": [] } }".utf8)
        XCTAssertEqual(try XcodebuildRunner.decodeSchemes(data: json), [])
    }

    func testDecodeSchemesGarbageThrowsTypedError() {
        let bad = Data("{ this is not json }".utf8)
        XCTAssertThrowsError(try XcodebuildRunner.decodeSchemes(data: bad)) { err in
            guard case SlopguardError.xcodebuildUnavailable = err else {
                XCTFail("expected xcodebuildUnavailable, got \(err)")
                return
            }
        }
    }

    /// Integration test: `xcodebuild -list -json` is fast (no build, just scheme
    /// inspection) and lets us cover the subprocess path against this repo's
    /// own Package.swift. Skipped on platforms without xcodebuild — and skipped
    /// when this very test binary is itself being run by `xcodebuild test`
    /// (which is what slopguard's auto-coverage path does), because nested
    /// xcodebuild invocations clobber `/tmp/action.xccovreport` and break the
    /// outer coverage collection.
    func testRunXcodebuildListAgainstThisRepo() throws {
        try Self.skipIfNestedUnderXcodebuild()
        let root = projectRoot()
        let data = try XcodebuildRunner.runXcodebuildList(projectDirectory: root.path)
        let schemes = try XcodebuildRunner.decodeSchemes(data: data)
        XCTAssertTrue(schemes.contains("slopguard-swift-Package"),
                      "expected `slopguard-swift-Package` umbrella scheme, got \(schemes)")
    }

    func testRunXcodebuildListBubblesUpFailureFromMissingDir() throws {
        try Self.skipIfNestedUnderXcodebuild()
        // No Package.swift / .xcodeproj here → xcodebuild exits non-zero, we
        // surface a typed error rather than swallowing stderr.
        XCTAssertThrowsError(
            try XcodebuildRunner.runXcodebuildList(projectDirectory: "/")
        ) { err in
            guard case SlopguardError.xcodebuildBuildFailed = err else {
                XCTFail("expected xcodebuildBuildFailed, got \(err)")
                return
            }
        }
    }

    /// `xcodebuild test` sets `XCODE_PRODUCT_BUILD_VERSION` for the test
    /// process; `swift test` does not. Use that to skip nested-xcodebuild
    /// integration tests when this binary is the inner half of slopguard's
    /// own auto-coverage run — otherwise we hose the outer coverage report.
    private static func skipIfNestedUnderXcodebuild(
        file: StaticString = #file, line: UInt = #line
    ) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/xcrun"),
                          "xcrun not available; skipping subprocess integration test",
                          file: file, line: line)
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            env["XCODE_PRODUCT_BUILD_VERSION"] != nil
                || env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil,
            "skipping nested xcodebuild call inside xcodebuild test",
            file: file, line: line
        )
    }

    /// Walk up from this test file to find the package root.
    private func projectRoot(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        XCTFail("could not find Package.swift starting from \(file)")
        return URL(fileURLWithPath: "/")
    }
}
