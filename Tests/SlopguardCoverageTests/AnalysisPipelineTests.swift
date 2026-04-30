import XCTest
@testable import SlopguardCoverage
import SlopguardCore

/// End-to-end tests for `AnalysisPipeline.run` that don't require spawning
/// `xcodebuild` (the auto-coverage path is exercised in CI and via the smoke
/// test `XcodebuildRunnerTests` — here we lock down the `.none` and
/// `CoverageSource.fromFlags` plumbing).
final class AnalysisPipelineTests: XCTestCase {

    /// Stub xccov that throws whatever the test wants. Used to exercise the
    /// `coverageDataMissing` fall-through without spawning a real subprocess.
    private struct StubXccov: XccovReporting {
        let result: Result<XccovReport, Error>
        func runReport(xcresultURL: URL) async throws -> XccovReport {
            try result.get()
        }
    }

    /// Stub probe that returns a fixed test count (or nil to simulate the
    /// "couldn't determine" case on older Xcode).
    private struct StubProbe: XcresultTestProbing {
        let count: Int?
        func testCount(xcresultURL: URL) async -> Int? { count }
    }

    /// Build a `.preBuilt` source pointing at a placeholder xcresult path. The
    /// stub xccov ignores the URL — it only needs to exist on disk for the
    /// path validation that `XccovRunner` does (the stub bypasses that, but
    /// keeping it real keeps the test honest if we change the contract later).
    private func makePreBuiltCoverage() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopguard-pipeline-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent("Stub.xcresult", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return (bundle, { try? FileManager.default.removeItem(at: dir) })
    }

    /// `.none` short-circuits both xcodebuild and xccov: every method comes
    /// back with 0% coverage and the report flags coverage as unavailable.
    func testRunWithNoneCoverageProducesReport() async throws {
        let tmp = try makeFixtureSourceDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pipeline = AnalysisPipeline()
        let report = try await pipeline.run(
            sourceURL: tmp,
            coverage: .none,
            threshold: 30
        )

        XCTAssertFalse(report.coverageAvailable)
        XCTAssertNil(report.xcresultPath)
        XCTAssertGreaterThan(report.summary.methodCount, 0)
        XCTAssertTrue(report.methods.allSatisfy { $0.coverage == 0 })
    }

    // MARK: - coverageDataMissing fall-through

    /// When the bundle has zero test runs, the pipeline should treat 0%
    /// coverage as honest, mark coverage unavailable, and explain *why* in
    /// a note — analysis still runs.
    func testCoverageDataMissingWithZeroTestsReportsNoTestsNote() async throws {
        let tmp = try makeFixtureSourceDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (bundle, cleanup) = try makePreBuiltCoverage()
        defer { cleanup() }

        let pipeline = AnalysisPipeline(
            xccov: StubXccov(result: .failure(
                SlopguardError.coverageDataMissing(reason: .coverageNotGathered(testCount: nil))
            )),
            xcresultProbe: StubProbe(count: 0)
        )

        let report = try await pipeline.run(
            sourceURL: tmp,
            coverage: .preBuilt(xcresultURL: bundle),
            threshold: 30
        )

        XCTAssertFalse(report.coverageAvailable)
        XCTAssertNil(report.xcresultPath)
        XCTAssertTrue(report.methods.allSatisfy { $0.coverage == 0 })
        // notes[0] is the standing schema-2 note; the diagnostic note we want
        // is the caller-supplied one that comes after.
        let diagnosticNotes = report.notes.dropFirst()
        XCTAssertEqual(diagnosticNotes.count, 1)
        XCTAssertTrue(
            diagnosticNotes.first?.localizedCaseInsensitiveContains("no tests") ?? false,
            "expected a 'no tests' note, got: \(diagnosticNotes.first ?? "nil")"
        )
    }

    /// When the probe sees tests but xccov found no coverage, the note must
    /// explicitly call out the configuration mismatch — masking it as 0%
    /// would silently misrepresent a tested codebase.
    func testCoverageDataMissingWithTestsReportsConfigNote() async throws {
        let tmp = try makeFixtureSourceDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (bundle, cleanup) = try makePreBuiltCoverage()
        defer { cleanup() }

        let pipeline = AnalysisPipeline(
            xccov: StubXccov(result: .failure(
                SlopguardError.coverageDataMissing(reason: .coverageNotGathered(testCount: nil))
            )),
            xcresultProbe: StubProbe(count: 42)
        )

        let report = try await pipeline.run(
            sourceURL: tmp,
            coverage: .preBuilt(xcresultURL: bundle),
            threshold: 30
        )

        XCTAssertFalse(report.coverageAvailable)
        // notes[0] is the standing schema-2 note; the caller-supplied
        // diagnostic comes after.
        let diagnosticNotes = report.notes.dropFirst()
        XCTAssertEqual(diagnosticNotes.count, 1)
        let note = try XCTUnwrap(diagnosticNotes.first)
        XCTAssertTrue(note.contains("42 test(s) ran"), "expected test count in note, got: \(note)")
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("gather code coverage"),
            "expected guidance about the test plan setting, got: \(note)"
        )
    }

    /// Probe failure (older Xcode, missing xcresulttool, etc.) must collapse
    /// to the *cautious* note, not the "no tests" one — calling a real test
    /// suite empty just because we couldn't probe would be a worse failure
    /// than admitting we don't know.
    func testCoverageDataMissingFallsBackWhenProbeReturnsNil() async throws {
        let tmp = try makeFixtureSourceDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (bundle, cleanup) = try makePreBuiltCoverage()
        defer { cleanup() }

        let pipeline = AnalysisPipeline(
            xccov: StubXccov(result: .failure(
                SlopguardError.coverageDataMissing(reason: .coverageNotGathered(testCount: nil))
            )),
            xcresultProbe: StubProbe(count: nil)
        )

        let report = try await pipeline.run(
            sourceURL: tmp,
            coverage: .preBuilt(xcresultURL: bundle),
            threshold: 30
        )

        XCTAssertFalse(report.coverageAvailable)
        // notes[0] is the standing schema-2 note; the cautious config-issue
        // diagnostic comes after.
        let diagnosticNotes = report.notes.dropFirst()
        XCTAssertEqual(diagnosticNotes.count, 1)
        let note = try XCTUnwrap(diagnosticNotes.first)
        XCTAssertFalse(
            note.localizedCaseInsensitiveContains("no tests"),
            "must not claim 'no tests' when the probe couldn't decide"
        )
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("gather code coverage"),
            "expected the cautious config-issue note, got: \(note)"
        )
    }

    /// Other xccov failures (genuine launch / decode breakage) must still
    /// propagate — we only swallow `coverageDataMissing`.
    func testOtherXccovErrorsStillPropagate() async throws {
        let tmp = try makeFixtureSourceDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (bundle, cleanup) = try makePreBuiltCoverage()
        defer { cleanup() }

        let pipeline = AnalysisPipeline(
            xccov: StubXccov(result: .failure(
                SlopguardError.xccovInvocationFailed(exitCode: 99, stderr: "real failure")
            )),
            xcresultProbe: StubProbe(count: 0)
        )

        do {
            _ = try await pipeline.run(
                sourceURL: tmp,
                coverage: .preBuilt(xcresultURL: bundle),
                threshold: 30
            )
            XCTFail("expected xccovInvocationFailed to propagate")
        } catch SlopguardError.xccovInvocationFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - CoverageSource.fromFlags

    func testFromFlagsNoCoverageWins() {
        let cov = AnalysisPipeline.CoverageSource.fromFlags(
            noCoverage: true,
            xcresult: "/anything.xcresult",
            scheme: "X",
            destination: "platform=macOS",
            projectDir: "/x"
        )
        guard case .none = cov else { return XCTFail("expected .none") }
    }

    func testFromFlagsPreBuiltWhenXcresultProvided() {
        let cov = AnalysisPipeline.CoverageSource.fromFlags(
            noCoverage: false,
            xcresult: "/path/to/Result.xcresult",
            scheme: nil,
            destination: "platform=macOS",
            projectDir: nil
        )
        guard case .preBuilt(let url) = cov else { return XCTFail("expected .preBuilt") }
        XCTAssertEqual(url.path, "/path/to/Result.xcresult")
    }

    /// When `--project-dir` is omitted, `fromFlags` no longer pins
    /// `projectDirectory` to the CWD — it leaves it nil so the pipeline can
    /// walk up from the analyzed source URL to find the real project root.
    /// Pinning to CWD was the source of the MCP "0% coverage" bug: an MCP
    /// server's CWD has no relationship to where the user's project lives.
    func testFromFlagsAutoLeavesProjectDirectoryNilWhenOmitted() {
        let cwd = URL(fileURLWithPath: "/work/proj")
        let cov = AnalysisPipeline.CoverageSource.fromFlags(
            noCoverage: false,
            xcresult: nil,
            scheme: nil,
            destination: "platform=macOS",
            projectDir: nil,
            cwd: cwd
        )
        guard case .auto(let opts) = cov else { return XCTFail("expected .auto") }
        XCTAssertNil(opts.projectDirectory,
                     "projectDirectory must be nil so the pipeline can discover from sourceURL")
        XCTAssertNil(opts.scheme)
        XCTAssertEqual(opts.destination, "platform=macOS")
    }

    func testFromFlagsAutoHonorsExplicitOverrides() {
        let cwd = URL(fileURLWithPath: "/work/proj")
        let cov = AnalysisPipeline.CoverageSource.fromFlags(
            noCoverage: false,
            xcresult: nil,
            scheme: "MyApp-Package",
            destination: "platform=iOS Simulator,name=iPhone 15",
            projectDir: "subdir",
            cwd: cwd
        )
        guard case .auto(let opts) = cov else { return XCTFail("expected .auto") }
        XCTAssertEqual(opts.projectDirectory?.path, "/work/proj/subdir")
        XCTAssertEqual(opts.scheme, "MyApp-Package")
        XCTAssertEqual(opts.destination, "platform=iOS Simulator,name=iPhone 15")
    }

    func testFromFlagsAbsoluteProjectDirIsRespected() {
        let cov = AnalysisPipeline.CoverageSource.fromFlags(
            noCoverage: false,
            xcresult: nil,
            scheme: nil,
            destination: "platform=macOS",
            projectDir: "/abs/elsewhere"
        )
        guard case .auto(let opts) = cov else { return XCTFail("expected .auto") }
        XCTAssertEqual(opts.projectDirectory?.path, "/abs/elsewhere")
    }

    // MARK: - Helpers

    private func makeFixtureSourceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopguard-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let swift = """
        struct Demo {
            func go(_ x: Int) -> Int {
                if x > 0 { return x + 1 }
                if x < 0 { return -x }
                return 0
            }
        }
        """
        try Data(swift.utf8).write(to: dir.appendingPathComponent("Demo.swift"))
        return dir
    }
}
