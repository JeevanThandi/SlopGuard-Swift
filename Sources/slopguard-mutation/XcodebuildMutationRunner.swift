import Foundation
import SlopguardCore
import SlopguardCoverage

/// Drives xcodebuild for `mutate`, with the same scheme / workspace /
/// destination / `--only-testing` plumbing as `analyze`.
///
/// - Mutant run (and the plain baseline): `xcodebuild build-for-testing` — a
///   non-zero exit means the mutant does not compile — then
///   `xcodebuild test-without-building`; a non-zero exit is a kill. Both pass
///   `-enableCodeCoverage NO`, so a scheme that gathers coverage cannot slow or
///   fail mutant runs.
/// - Coverage baseline: `analyze`'s `xcodebuild test -enableCodeCoverage YES`
///   and `xccov` path, read into a `CoverageIndex`.
public struct XcodebuildMutationRunner: MutationTestRunner {

    public let projectDirectory: String
    public let workspace: String?
    public let scheme: String
    public let destination: String
    public let onlyTesting: [String]
    private let commands: any CommandRunning
    /// Reads an `.xcresult` bundle's coverage (`xcrun xccov view --report --json`).
    private let readCoverage: @Sendable (String) throws -> XccovReport
    private let temporaryDirectory: URL

    public init(
        projectDirectory: String,
        workspace: String?,
        scheme: String,
        destination: String,
        onlyTesting: [String] = [],
        commands: any CommandRunning = ProcessGroupCommandRunner(),
        readCoverage: @escaping @Sendable (String) throws -> XccovReport = XcodebuildMutationRunner.readXccov,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.projectDirectory = projectDirectory
        self.workspace = workspace
        self.scheme = scheme
        self.destination = destination
        self.onlyTesting = onlyTesting
        self.commands = commands
        self.readCoverage = readCoverage
        self.temporaryDirectory = temporaryDirectory
    }

    /// A runner for `projectDirectory`, discovering the scheme the way
    /// `analyze` does when `scheme` is `nil`.
    public static func make(
        projectDirectory: String,
        workspace: String?,
        scheme: String?,
        destination: String,
        onlyTesting: [String],
        progress: ProgressReporter
    ) throws -> XcodebuildMutationRunner {
        let resolved: String
        if let scheme {
            resolved = scheme
        } else {
            progress.phase("discovering xcodebuild scheme in \(workspace ?? projectDirectory)")
            resolved = try XcodebuildRunner.discoverDefaultScheme(projectDirectory: projectDirectory, workspace: workspace)
        }
        return XcodebuildMutationRunner(
            projectDirectory: projectDirectory,
            workspace: workspace,
            scheme: resolved,
            destination: destination,
            onlyTesting: onlyTesting
        )
    }

    @Sendable public static func readXccov(_ xcresultPath: String) throws -> XccovReport {
        try XccovRunner.decode(data: XccovRunner.runXccov(xcresultPath: xcresultPath))
    }

    public var name: String { MutationRunnerKind.xcodebuild.displayName }

    // MARK: - Arguments

    static func buildForTestingArguments(scheme: String, workspace: String?, destination: String) -> [String] {
        ["xcodebuild", "build-for-testing"] + container(workspace)
            + ["-scheme", scheme, "-destination", destination, "-enableCodeCoverage", "NO"]
    }

    static func testWithoutBuildingArguments(
        scheme: String,
        workspace: String?,
        destination: String,
        resultBundlePath: String,
        onlyTesting: [String]
    ) -> [String] {
        ["xcodebuild", "test-without-building"] + container(workspace)
            + [
                "-scheme", scheme,
                "-destination", destination,
                "-resultBundlePath", resultBundlePath,
                "-enableCodeCoverage", "NO"
            ]
            + onlyTesting.map { "-only-testing:\($0)" }
    }

    private static func container(_ workspace: String?) -> [String] {
        workspace.map { ["-workspace", $0] } ?? []
    }

    // MARK: - MutationTestRunner

    public func runPlainBaseline(progress: ProgressReporter) throws -> TimeInterval {
        let build = try xcodebuild(buildArguments, timeout: nil, progress: progress)
        guard build.succeeded else { throw RunnerSupport.baselineFailure(build) }
        let test = try withResultBundle { bundle in
            try xcodebuild(testArguments(resultBundlePath: bundle), timeout: nil, progress: progress)
        }
        guard test.succeeded else { throw RunnerSupport.baselineFailure(test) }
        return build.duration + test.duration
    }

    public func runCoverageBaseline(progress: ProgressReporter) throws -> CoverageRunResult {
        try withResultBundle { bundle in
            let arguments = XcodebuildRunner.testArguments(
                scheme: scheme,
                workspace: workspace,
                destination: destination,
                resultBundlePath: bundle,
                onlyTesting: onlyTesting
            )
            let outcome = try xcodebuild(arguments, timeout: nil, progress: progress)
            guard FileManager.default.fileExists(atPath: bundle),
                  let report = try? readCoverage(bundle), !report.targets.isEmpty else {
                return CoverageRunResult(exitCode: outcome.exitCode, coverage: nil)
            }
            return CoverageRunResult(exitCode: outcome.exitCode, coverage: .methods(CoverageIndex(report: report)))
        }
    }

    public func prepareMutantRuns(progress: ProgressReporter) throws {
        let build = try xcodebuild(buildArguments, timeout: nil, progress: progress)
        guard build.succeeded else { throw RunnerSupport.baselineFailure(build) }
    }

    public func runMutant(timeout: TimeInterval, progress: ProgressReporter) throws -> MutantRunResult {
        let build = try xcodebuild(buildArguments, timeout: timeout, progress: progress)
        if build.timedOut { return MutantRunResult(status: .timeout, duration: build.duration) }
        guard build.exitCode == 0 else { return MutantRunResult(status: .compileError, duration: build.duration) }
        let remaining = max(timeout - build.duration, 0.001)
        let test = try withResultBundle { bundle in
            try xcodebuild(testArguments(resultBundlePath: bundle), timeout: remaining, progress: progress)
        }
        let duration = build.duration + test.duration
        if test.timedOut { return MutantRunResult(status: .timeout, duration: duration) }
        return MutantRunResult(status: test.exitCode == 0 ? .survived : .killed, duration: duration)
    }

    public func stop() {
        commands.stop()
    }

    // MARK: - Commands

    private var buildArguments: [String] {
        Self.buildForTestingArguments(scheme: scheme, workspace: workspace, destination: destination)
    }

    private func testArguments(resultBundlePath: String) -> [String] {
        Self.testWithoutBuildingArguments(
            scheme: scheme,
            workspace: workspace,
            destination: destination,
            resultBundlePath: resultBundlePath,
            onlyTesting: onlyTesting
        )
    }

    /// Each test run writes its `.xcresult` to a fresh temporary path that is
    /// deleted afterwards, so mutant runs do not pile result bundles up in
    /// DerivedData.
    private func withResultBundle<T>(_ body: (String) throws -> T) throws -> T {
        let directory = temporaryDirectory
            .appendingPathComponent("slopguard-mutate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.appendingPathComponent("tests.xcresult").path)
    }

    private func xcodebuild(_ arguments: [String], timeout: TimeInterval?, progress: ProgressReporter) throws -> CommandOutcome {
        let outcome = try commands.run(
            CommandSpec(
                executable: "/usr/bin/xcrun",
                arguments: arguments,
                workingDirectory: projectDirectory,
                environment: RunnerSupport.environment
            ),
            timeout: timeout,
            progress: progress
        )
        try RunnerSupport.checkLaunched(outcome, runner: "xcodebuild")
        return outcome
    }
}
