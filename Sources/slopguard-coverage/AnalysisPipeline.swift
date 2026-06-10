import Foundation
import SlopguardCore

/// Orchestrates the full analyze → coverage-join → CRAP-report pipeline.
///
/// Coverage is treated as an *internal artifact*: in `.auto` mode the pipeline
/// drives `xcodebuild test` itself, ingests the resulting `.xcresult`, and
/// cleans up. Callers don't pass coverage in.
public struct AnalysisPipeline: Sendable {

    public var analyzer: DirectoryAnalyzer
    public var xccov: any XccovReporting
    public var xcresultProbe: any XcresultTestProbing
    public var xcodebuild: XcodebuildRunner
    public var aggregator: CrapAggregator

    public init(
        analyzer: DirectoryAnalyzer = DirectoryAnalyzer(),
        xccov: any XccovReporting = XccovRunner(),
        xcresultProbe: any XcresultTestProbing = XcresultProbe(),
        xcodebuild: XcodebuildRunner = XcodebuildRunner(),
        aggregator: CrapAggregator = CrapAggregator()
    ) {
        self.analyzer = analyzer
        self.xccov = xccov
        self.xcresultProbe = xcresultProbe
        self.xcodebuild = xcodebuild
        self.aggregator = aggregator
    }

    /// Knobs for the `.auto` coverage mode — what scheme / destination /
    /// working directory to drive `xcodebuild` against.
    ///
    /// `projectDirectory == nil` means "discover from the analyzed source URL"
    /// — the pipeline walks up from the source path looking for the nearest
    /// `Package.swift` / `.xcodeproj` / `.xcworkspace`. That's the right
    /// default when the user analyzes a subdirectory of a larger project. Set
    /// explicitly only when the caller knows better than the auto-discovery.
    public struct AutoCoverageOptions: Sendable {
        public var projectDirectory: URL?
        public var scheme: String?
        public var destination: String

        public init(
            projectDirectory: URL? = nil,
            scheme: String? = nil,
            destination: String = "platform=macOS"
        ) {
            self.projectDirectory = projectDirectory
            self.scheme = scheme
            self.destination = destination
        }
    }

    /// How the pipeline gets its coverage signal.
    ///
    /// `.auto` is the default and the only mode the CLI exposes — slopguard
    /// runs `xcodebuild test` itself. `.preBuilt` is an internal escape hatch
    /// for tests / CI fixtures that already have an `.xcresult`. `.none`
    /// short-circuits coverage entirely and reports every method at 0%.
    public enum CoverageSource: Sendable {
        case auto(AutoCoverageOptions = .init())
        case preBuilt(xcresultURL: URL)
        case none

        /// Resolve a `CoverageSource` from CLI-style flag values. Pure (the
        /// only filesystem touch is constructing URLs), so unit-testable
        /// without spinning up `AnalyzeCommand`.
        public static func fromFlags(
            noCoverage: Bool,
            xcresult: String?,
            scheme: String?,
            destination: String,
            projectDir: String?,
            cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ) -> CoverageSource {
            // `URL(fileURLWithPath: "x", relativeTo: cwd)` resolves "x" against
            // cwd's *parent* unless cwd is marked as a directory. Normalize here
            // so callers don't have to remember the `isDirectory: true` dance.
            let cwdDir = URL(fileURLWithPath: cwd.path, isDirectory: true)
            if noCoverage { return .none }
            if let xcresult { return .preBuilt(xcresultURL: resolveURL(xcresult, cwd: cwdDir)) }
            // Pass nil through when the caller didn't supply --project-dir; the
            // pipeline will discover the right project root from sourceURL.
            // Resolving relative paths still uses cwd when an explicit path is
            // given (e.g. `--project-dir subdir`).
            let projectDirectory = projectDir.map { resolveURL($0, cwd: cwdDir) }
            return .auto(.init(
                projectDirectory: projectDirectory,
                scheme: scheme,
                destination: destination
            ))
        }

        private static func resolveURL(_ raw: String, cwd: URL) -> URL {
            let expanded = (raw as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
            return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
        }
    }

    /// Run the full pipeline against a directory or single Swift file.
    public func run(
        sourceURL: URL,
        coverage: CoverageSource = .auto(),
        threshold: Double = CRAP.defaultThreshold,
        options: AnalysisOptions = .default,
        progress: ProgressReporter = .silent
    ) async throws -> CrapReport {
        progress.phase("walking \(sourceURL.path)")
        let fileReports = try await analyzer.analyze(rootURL: sourceURL, options: options)
        let methodCount = fileReports.reduce(0) { $0 + $1.methods.count }
        progress.phase("parsed \(fileReports.count) Swift file(s), \(methodCount) method(s)")

        let resolved = try await resolveCoverage(coverage, sourceURL: sourceURL, progress: progress)
        defer { resolved.cleanup() }

        let provider: (any CoverageProvider)?
        let xcresultPath: String?
        var notes: [String] = []
        if let url = resolved.xcresultURL {
            do {
                progress.phase("parsing xcresult coverage")
                let report = try await xccov.runReport(xcresultURL: url)
                provider = CoverageIndex(report: report)
                // Ephemeral xcresults (auto mode) are deleted on `defer` below — don't
                // surface a path that won't exist by the time the user reads the report.
                xcresultPath = resolved.isEphemeral ? nil : url.standardizedFileURL.path
            } catch SlopguardError.coverageDataMissing {
                // xccov collapses "no tests ran" and "tests-but-no-coverage" into
                // the same stderr signature. Probe the bundle to figure out which
                // case actually fired before deciding what note to attach. Either
                // way we fall through to provider-less analysis (every method 0%)
                // rather than abort — analysis is still useful, the user just
                // needs to know why coverage is zero.
                let resolvedReason = await disambiguateMissingCoverage(xcresultURL: url)
                notes.append(noteText(for: resolvedReason))
                provider = nil
                xcresultPath = nil
            }
        } else {
            provider = nil
            xcresultPath = nil
        }

        return aggregator.aggregate(
            fileReports: fileReports,
            sourceRootURL: sourceURL,
            xcresultPath: xcresultPath,
            threshold: threshold,
            coverage: provider,
            notes: notes
        )
    }

    /// Decide which `CoverageMissingReason` actually applies once xccov has
    /// reported "no coverage data". Probe failure (older Xcode, missing
    /// xcresulttool, decode error) collapses to `coverageNotGathered(testCount: nil)`
    /// — the safer default, since calling it "no tests" when we can't tell
    /// would silently misrepresent a real test suite as empty.
    private func disambiguateMissingCoverage(xcresultURL: URL) async -> CoverageMissingReason {
        guard let count = await xcresultProbe.testCount(xcresultURL: xcresultURL) else {
            return .coverageNotGathered(testCount: nil)
        }
        return count == 0 ? .noTestsDetected : .coverageNotGathered(testCount: count)
    }

    private func noteText(for reason: CoverageMissingReason) -> String {
        switch reason {
        case .noTestsDetected:
            return "No tests were detected in the xcresult — every method is reported at 0% coverage."
        case .coverageNotGathered(let count):
            let detail = count.map { "\($0) test(s) ran" } ?? "tests appear to have run"
            return "\(detail) but no coverage data was gathered. " +
                "Likely cause: the scheme's test plan has 'Gather code coverage' disabled. " +
                "All methods are being reported at 0%."
        }
    }

    /// Materialize the user's choice of `CoverageSource` into a concrete
    /// `.xcresult` URL on disk (or `nil` for `.none`). Returns a `Resolved`
    /// so the caller can clean up any temporary directory we created.
    ///
    /// When `.auto`'s `projectDirectory` is nil, walk up from `sourceURL` to
    /// find the nearest `Package.swift` / `.xcodeproj` / `.xcworkspace` —
    /// that's the right working directory for `xcodebuild test`. Without
    /// this, callers would build whatever package the current directory
    /// contains instead of the user's project, producing an xcresult whose
    /// paths never match the analyzed sources.
    private func resolveCoverage(_ source: CoverageSource, sourceURL: URL, progress: ProgressReporter) async throws -> Resolved {
        switch source {
        case .none:
            return .init(xcresultURL: nil, isEphemeral: false, cleanup: {})

        case .preBuilt(let url):
            return .init(xcresultURL: url, isEphemeral: false, cleanup: {})

        case .auto(let opts):
            let projectDirectory = opts.projectDirectory
                ?? ProjectRootDiscovery.discover(searchingFrom: sourceURL)
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("slopguard-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let bundleURL = tempDir.appendingPathComponent("coverage.xcresult", isDirectory: true)
            let outcome = try await xcodebuild.runTests(
                scheme: opts.scheme,
                destination: opts.destination,
                projectDirectory: projectDirectory,
                resultBundleURL: bundleURL,
                progress: progress
            )
            return .init(
                xcresultURL: outcome.resultBundle,
                isEphemeral: true,
                testsPassed: outcome.testsPassed,
                cleanup: { try? FileManager.default.removeItem(at: tempDir) }
            )
        }
    }

    /// The output of `resolveCoverage` — concrete xcresult plus a deferred
    /// cleanup hook for any temp dir we own. `isEphemeral` flags bundles that
    /// will vanish when `cleanup` runs, so the report can avoid printing paths
    /// the user can't actually visit.
    private struct Resolved {
        let xcresultURL: URL?
        let isEphemeral: Bool
        let testsPassed: Bool
        let cleanup: @Sendable () -> Void

        init(
            xcresultURL: URL?,
            isEphemeral: Bool,
            testsPassed: Bool = true,
            cleanup: @escaping @Sendable () -> Void
        ) {
            self.xcresultURL = xcresultURL
            self.isEphemeral = isEphemeral
            self.testsPassed = testsPassed
            self.cleanup = cleanup
        }
    }
}
