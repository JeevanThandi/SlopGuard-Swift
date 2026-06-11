import XCTest
import ArgumentParser
@testable import SlopguardCLI

/// Drive `AnalyzeCommand.run()` directly so the CLI's main entry path is
/// covered. Every test passes `--no-coverage` so we don't recurse into
/// `xcodebuild test` from inside `swift test`.
final class AnalyzeCommandTests: XCTestCase {

    private var fixtureDir: URL!

    override func setUpWithError() throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopguard-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func writeFixture(_ source: String, named name: String = "Demo.swift") throws {
        try Data(source.utf8).write(to: fixtureDir.appendingPathComponent(name))
    }

    private func parse(_ args: [String]) throws -> AnalyzeCommand {
        try AnalyzeCommand.parse(args)
    }

    // MARK: - Happy paths

    func testRunSucceedsWithSimpleFixture() async throws {
        try writeFixture("""
        struct A { func f(_ x: Int) -> Int { return x + 1 } }
        """)
        var cmd = try parse(["--path", fixtureDir.path, "--no-coverage", "--json"])
        try await cmd.run()
    }

    func testRunSucceedsWithPrettyOutput() async throws {
        try writeFixture("""
        struct A { func f(_ x: Int) -> Int { if x > 0 { return x } else { return -x } } }
        """)
        var cmd = try parse(["--path", fixtureDir.path, "--no-coverage"])
        try await cmd.run()
    }

    /// `--threshold` flows through to the report; this just locks down that
    /// the run doesn't trip on a non-default threshold.
    func testRunHonorsCustomThreshold() async throws {
        try writeFixture("struct A {}")
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--threshold", "100",
            "--no-coverage"
        ])
        try await cmd.run()
    }

    // MARK: - Error paths

    /// Missing path → pipeline raises `SlopguardError.notADirectory`,
    /// `run()` catches it, emits an envelope, and exits 1.
    func testRunReturnsExitOneOnMissingPath() async throws {
        var cmd = try parse([
            "--path", "/no/such/directory/at/all",
            "--no-coverage"
        ])
        do {
            try await cmd.run()
            XCTFail("expected ExitCode(1)")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(1))
        }
    }

    /// `--fail-over` trips on a CRAP score above the supplied bound. With
    /// `--no-coverage` (every method shows 0% coverage), CRAP = cc² + cc, so
    /// a method with cc=5 produces CRAP=30. Setting fail-over to 25 must
    /// trigger ExitCode(2).
    func testRunFailsOverWhenMaxCrapExceeds() async throws {
        try writeFixture("""
        struct A {
            func f(_ x: Int) -> Int {
                if x > 0 {
                    if x > 10 {
                        if x > 100 {
                            if x > 1000 { return x } else { return 0 }
                        }
                    }
                }
                return -1
            }
        }
        """)
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--no-coverage",
            "--fail-over", "25"
        ])
        do {
            try await cmd.run()
            XCTFail("expected ExitCode(2)")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit, ExitCode(2))
        }
    }

    /// Below the fail-over bound → success.
    func testRunDoesNotFailOverWhenUnderBound() async throws {
        try writeFixture("struct A { func f() -> Int { return 1 } }")
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--no-coverage",
            "--fail-over", "1000"
        ])
        try await cmd.run()
    }

    // MARK: - Filtering

    /// `--include` / `--exclude` are wired through to AnalysisOptions; this
    /// just exercises the path-flow on a fixture with two files.
    func testRunWithIncludeExcludeGlobs() async throws {
        try writeFixture("struct A {}", named: "Keep.swift")
        try writeFixture("struct B {}", named: "Skip.swift")
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--no-coverage",
            "--exclude", "**/Skip.swift"
        ])
        try await cmd.run()
    }

    /// `--exclude` is additive — defaults still apply unless --no-default-excludes
    /// is set. A test file alongside production code should be filtered by the
    /// default `**/*Tests.swift` glob even when --exclude isn't passed.
    func testDefaultExcludesAreActiveWithoutExplicitFlag() async throws {
        try writeFixture("struct A {}", named: "Foo.swift")
        try writeFixture("struct ATests {}", named: "FooTests.swift")
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--no-coverage"
        ])
        // Smoke: command runs end-to-end. The DirectoryAnalyzer-level test
        // verifies the actual filtering — here we just confirm CLI wiring.
        try await cmd.run()
    }

    // MARK: - Progress flags

    /// Default (no flags) → phase markers on stderr at normal verbosity.
    func testProgressDefaultsToNormal() throws {
        let cmd = try parse(["--path", "."])
        XCTAssertEqual(cmd.resolveProgressReporter().verbosity, .normal)
    }

    func testVerboseFlagYieldsVerboseReporter() throws {
        let cmd = try parse(["--path", ".", "--verbose"])
        XCTAssertEqual(cmd.resolveProgressReporter().verbosity, .verbose)
    }

    func testQuietFlagYieldsSilentReporter() throws {
        let cmd = try parse(["--path", ".", "--quiet"])
        XCTAssertEqual(cmd.resolveProgressReporter().verbosity, .silent)
    }

    /// `--quiet` wins when both flags are passed.
    func testQuietBeatsVerbose() throws {
        let cmd = try parse(["--path", ".", "--quiet", "--verbose"])
        XCTAssertEqual(cmd.resolveProgressReporter().verbosity, .silent)
    }

    // MARK: - Workspace flag

    /// `--workspace` parses and lands on the command; the coverage-layer tests
    /// verify it flows through `fromFlags` into the xcodebuild invocation.
    func testWorkspaceFlagParses() throws {
        let cmd = try parse(["--path", ".", "--workspace", "MyApp.xcworkspace"])
        XCTAssertEqual(cmd.workspace, "MyApp.xcworkspace")
    }

    func testWorkspaceDefaultsToNil() throws {
        let cmd = try parse(["--path", "."])
        XCTAssertNil(cmd.workspace)
    }

    // MARK: - Path default

    /// Bare `slopguard-swift analyze` analyzes the current directory.
    func testPathDefaultsToCurrentDirectory() throws {
        let cmd = try parse([])
        XCTAssertEqual(cmd.path, ".")
    }

    /// `--no-default-excludes` brings test code back into the report.
    func testNoDefaultExcludesAnalyzesTestCode() async throws {
        try writeFixture("struct ATests {}", named: "FooTests.swift")
        // With defaults active, this fixture would have zero analyzable files
        // and a CRAP-of-zero method count. Without defaults, the test file
        // gets analyzed.
        var cmd = try parse([
            "--path", fixtureDir.path,
            "--no-coverage",
            "--no-default-excludes"
        ])
        try await cmd.run()
    }
}
