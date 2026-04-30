import XCTest
@testable import SlopguardCore

final class DirectoryAnalyzerTests: XCTestCase {

    /// Build a temporary directory with a controlled mix of `.swift` files,
    /// non-Swift files, and a hidden / excluded subtree. Cleaned up in tearDown.
    private var root: URL!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slopguard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.root = url
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ relative: String, _ source: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAnalyzesAllSwiftFilesUnderRoot() async throws {
        try write("Sources/A.swift", "func a() {}\n")
        try write("Sources/Nested/B.swift", "func b(_ x: Int) { if x > 0 {} }\n")
        try write("README.md", "not swift")

        let reports = try await DirectoryAnalyzer().analyze(rootURL: root)
        let paths = reports.map(\.path).sorted()
        XCTAssertEqual(paths, ["Sources/A.swift", "Sources/Nested/B.swift"])
        XCTAssertEqual(reports.count, 2)
    }

    func testExcludeGlobSkipsMatchingDirectory() async throws {
        try write("Sources/A.swift", "func a() {}\n")
        try write("ThirdParty/Vendor.swift", "func v() {}\n")

        let opts = AnalysisOptions(includeGlobs: [], excludeGlobs: ["**/ThirdParty/**"])
        let reports = try await DirectoryAnalyzer().analyze(rootURL: root, options: opts)
        XCTAssertEqual(reports.map(\.path), ["Sources/A.swift"])
    }

    func testIncludeGlobNarrowsToMatching() async throws {
        try write("Sources/A.swift", "func a() {}\n")
        try write("Sources/B.swift", "func b() {}\n")

        let opts = AnalysisOptions(includeGlobs: ["**/A.swift"], excludeGlobs: [])
        let reports = try await DirectoryAnalyzer().analyze(rootURL: root, options: opts)
        XCTAssertEqual(reports.map(\.path), ["Sources/A.swift"])
    }

    func testAnalyzesSingleFileWhenRootIsAFile() async throws {
        try write("Solo.swift", "func solo(_ x: Int) -> Int { return x > 0 ? 1 : 0 }\n")
        let single = root.appendingPathComponent("Solo.swift")
        let reports = try await DirectoryAnalyzer().analyze(rootURL: single)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].methods.first?.name, "solo(_:)")
    }

    func testMissingRootThrowsFileNotFound() async {
        let bogus = root.appendingPathComponent("does-not-exist")
        do {
            _ = try await DirectoryAnalyzer().analyze(rootURL: bogus)
            XCTFail("expected fileNotFound")
        } catch let SlopguardError.fileNotFound(path) {
            XCTAssertTrue(path.contains("does-not-exist"))
        } catch {
            XCTFail("expected SlopguardError.fileNotFound, got \(error)")
        }
    }

    func testNonSwiftFilesAreIgnored() async throws {
        try write("a.swift.bak", "ignored")
        try write("notes.txt", "ignored")
        try write("real.swift", "func r() {}")
        let reports = try await DirectoryAnalyzer().analyze(rootURL: root)
        XCTAssertEqual(reports.map(\.path), ["real.swift"])
    }

    // MARK: - Default-exclude behavior (iOS-shaped fixtures)

    /// Realistic old-iOS-app layout. With the default excludes, only
    /// production sources should come back — no test files, no Carthage,
    /// no codegen.
    func testDefaultExcludesSkipTestsSpecsCarthageAndGenerated() async throws {
        // Production source — should be analyzed.
        try write("MyApp/Foo.swift", "func a() {}\n")
        try write("MyApp/Models/Bar.swift", "func b() {}\n")
        // Apple-style test target dir + file naming.
        try write("MyAppTests/FooTests.swift", "func t1() {}\n")
        try write("MyApp/IntegrationTests/X.swift", "func t2() {}\n")
        try write("Tests/Unit/HelperTests.swift", "func t3() {}\n")
        // Quick / Nimble spec convention.
        try write("MyApp/Specs/FooSpec.swift", "func s1() {}\n")
        try write("MyApp/BarSpec.swift", "func s2() {}\n")
        try write("MyApp/QuxSpecs.swift", "func s3() {}\n")
        // Carthage build artifacts.
        try write("Carthage/Build/iOS/Thirdparty.swift", "func c() {}\n")
        // Generated code conventions.
        try write("Generated/R.generated.swift", "func g1() {}\n")
        try write("MyApp/Codegen/Strings.generated.swift", "func g2() {}\n")
        // False-positive guards — these should NOT be excluded.
        try write("MyApp/SettingsTester.swift", "func n1() {}\n")     // 'Tester' ≠ 'Tests'
        try write("MyApp/TestHelper.swift", "func n2() {}\n")         // singular 'Test'
        try write("MyApp/DescriptionLabel.swift", "func n3() {}\n")   // contains 'descrip'

        let reports = try await DirectoryAnalyzer().analyze(rootURL: root)
        let paths = reports.map(\.path).sorted()
        XCTAssertEqual(paths, [
            "MyApp/DescriptionLabel.swift",
            "MyApp/Foo.swift",
            "MyApp/Models/Bar.swift",
            "MyApp/SettingsTester.swift",
            "MyApp/TestHelper.swift"
        ])
    }

    /// Opting out of the defaults must include test code again.
    func testEmptyExcludesIncludesEverything() async throws {
        try write("MyApp/Foo.swift", "func a() {}\n")
        try write("MyAppTests/FooTests.swift", "func t() {}\n")
        try write("Carthage/Build/iOS/Thirdparty.swift", "func c() {}\n")

        let opts = AnalysisOptions(includeGlobs: [], excludeGlobs: [])
        let reports = try await DirectoryAnalyzer().analyze(rootURL: root, options: opts)
        XCTAssertEqual(reports.count, 3)
    }

    /// Caller-supplied excludes append to the defaults — both layers fire.
    func testCustomExcludesCompoundWithDefaults() async throws {
        try write("MyApp/Foo.swift", "func a() {}\n")
        try write("MyAppTests/FooTests.swift", "func t() {}\n")     // hit by default
        try write("Vendor/Thirdparty.swift", "func v() {}\n")        // hit by custom

        let opts = AnalysisOptions(
            includeGlobs: [],
            excludeGlobs: AnalysisOptions.defaultExcludeGlobs + ["**/Vendor/**"]
        )
        let reports = try await DirectoryAnalyzer().analyze(rootURL: root, options: opts)
        XCTAssertEqual(reports.map(\.path), ["MyApp/Foo.swift"])
    }
}
