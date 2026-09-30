import Foundation
import SlopguardCore
import SlopguardCoverage

/// The two test runners `mutate` can drive.
public enum MutationRunnerKind: String, Sendable, CaseIterable {
    case swiftTest = "swift-test"
    case xcodebuild

    /// The name the report shows (`runner` field).
    public var displayName: String {
        switch self {
        case .swiftTest: return "swift test"
        case .xcodebuild: return "xcodebuild"
        }
    }
}

/// Picks the runner when `--runner` is not given: `xcodebuild` when a scheme
/// or workspace is passed or the project directory holds an `.xcodeproj` /
/// `.xcworkspace`; else `swift test` when it holds a `Package.swift`.
public enum RunnerSelection {

    public static func detect(scheme: String?, workspace: String?, projectDirectory: String) throws -> MutationRunnerKind {
        if scheme != nil || workspace != nil { return .xcodebuild }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: projectDirectory)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return .xcodebuild
        }
        if entries.contains("Package.swift") { return .swiftTest }
        throw SlopguardError.runnerNotDetected(projectDirectory: projectDirectory)
    }
}

/// How one mutant run ended.
public struct MutantRunResult: Sendable, Equatable {
    public let status: MutantStatus
    /// Wall time of the build and test steps, in seconds.
    public let duration: TimeInterval

    public init(status: MutantStatus, duration: TimeInterval) {
        self.status = status
        self.duration = duration
    }
}

/// Line coverage from the coverage baseline, as each runner can provide it.
public enum BaselineCoverage: Sendable {
    /// Per-line execution counts (`swift test` → `llvm-cov export -format=lcov`).
    case lines(LineCoverageIndex)
    /// Per-function coverage (`xcodebuild` → `xccov`). xccov's report has no
    /// per-line counts, so a line counts as uncovered when its enclosing method
    /// never ran.
    case methods(CoverageIndex)

    /// Whether no test executed `line` — exactly 0, never merely unknown.
    public func isUncovered(absolutePath: String, line: Int, methodLines: ClosedRange<Int>?) -> Bool {
        switch self {
        case .lines(let index):
            return index.methodCoverage(absolutePath: absolutePath, line: line, endLine: line) == 0
        case .methods(let index):
            guard let methodLines else { return false }
            return index.methodCoverage(
                absolutePath: absolutePath,
                line: methodLines.lowerBound,
                endLine: methodLines.upperBound
            ) == 0
        }
    }
}

/// What the coverage baseline produced. `coverage` is `nil` when the run gave
/// no usable data; a non-zero `exitCode` with data still counts.
public struct CoverageRunResult: Sendable {
    public let exitCode: Int32?
    public let coverage: BaselineCoverage?

    public init(exitCode: Int32?, coverage: BaselineCoverage?) {
        self.exitCode = exitCode
        self.coverage = coverage
    }
}

/// A test runner as `mutate` drives it: the plain baseline, the coverage
/// baseline, and one run per mutant. Implementations are synchronous; the
/// pipeline calls them from a detached task.
public protocol MutationTestRunner: Sendable {
    /// Name for the report and progress lines (`swift test`, `xcodebuild`).
    var name: String { get }

    /// Run the exact mutant test command on the unmutated code, with no
    /// timeout. Throws `baseline_failed` when it fails. Returns its wall time.
    func runPlainBaseline(progress: ProgressReporter) throws -> TimeInterval

    /// Run the tests with coverage. Never throws `baseline_failed`: failing
    /// tests here only cost the `no_coverage` shortcut, and the pipeline
    /// treats a thrown error the same as a run that left no usable data.
    func runCoverageBaseline(progress: ProgressReporter) throws -> CoverageRunResult

    /// Rebuild without coverage after the coverage run, so the first mutant
    /// does not pay for switching the build back (and time out on it).
    func prepareMutantRuns(progress: ProgressReporter) throws

    /// Build and test with the mutant in place, within `timeout` seconds.
    func runMutant(timeout: TimeInterval, progress: ProgressReporter) throws -> MutantRunResult

    /// Kill the running command's process group and start no more commands.
    func stop()
}

/// Shared helpers for the runners.
enum RunnerSupport {

    /// Variables added to every test-runner command: keep runners
    /// non-interactive and colour-free.
    static let environment = ["CI": "1", "NO_COLOR": "1"]

    /// `baseline_failed` for a failed unmutated run, quoting the output tail.
    static func baselineFailure(_ outcome: CommandOutcome) -> SlopguardError {
        let tail = outcome.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return .baselineFailed(exitCode: outcome.exitCode, output: tail.isEmpty ? "no output captured" : tail)
    }

    /// xcrun launches fine but fails before the tool runs when the tool or
    /// the developer directory is missing. That is `runner_unavailable`, not a
    /// test failure. Only output that *starts* with xcrun's error counts, so a
    /// test that happens to print one is still a test failure.
    static func checkLaunched(_ outcome: CommandOutcome, runner: String) throws {
        let output = outcome.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.exitCode != 0, output.hasPrefix("xcrun: error:") else { return }
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? output
        throw SlopguardError.runnerUnavailable(reason: "\(runner): \(line)")
    }
}
