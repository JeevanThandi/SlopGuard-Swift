import Foundation
import SlopguardCore

/// Drives SwiftPM for `mutate`.
///
/// - Mutant run (and the plain baseline): `swift build --build-tests` — a
///   non-zero exit means the mutant does not compile — then
///   `swift test --skip-build --disable-code-coverage`; a non-zero exit is a kill.
/// - Coverage baseline: `swift test --enable-code-coverage`, then
///   `xcrun llvm-cov export -format=lcov` of the test binary against
///   `<bin path>/codecov/default.profdata` for per-line counts.
///
/// `--only-testing` identifiers use xcodebuild's `Target/Class/method` form,
/// the same as `analyze`; they become `--filter Target.Class/method`.
public struct SwiftTestMutationRunner: MutationTestRunner {

    public let projectDirectory: String
    public let onlyTesting: [String]
    private let commands: any CommandRunning
    /// `swift`, looked up on `PATH` like a shell would.
    private let swiftExecutable: String

    public init(
        projectDirectory: String,
        onlyTesting: [String] = [],
        commands: any CommandRunning = ProcessGroupCommandRunner(),
        swiftExecutable: String = "swift"
    ) {
        self.projectDirectory = projectDirectory
        self.onlyTesting = onlyTesting
        self.commands = commands
        self.swiftExecutable = swiftExecutable
    }

    public var name: String { MutationRunnerKind.swiftTest.displayName }

    // MARK: - Arguments

    static let buildArguments = ["build", "--build-tests"]

    var testArguments: [String] {
        ["test", "--skip-build", "--disable-code-coverage"] + Self.filterArguments(onlyTesting)
    }

    var coverageArguments: [String] {
        ["test", "--enable-code-coverage"] + Self.filterArguments(onlyTesting)
    }

    static let binPathArguments = ["build", "--show-bin-path"]

    /// `Target/Class/method` → `--filter Target.Class/method` (SwiftPM matches
    /// `Target.Class/method`).
    static func filterArguments(_ identifiers: [String]) -> [String] {
        identifiers.flatMap { identifier -> [String] in
            let parts = identifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1 else { return ["--filter", identifier] }
            return ["--filter", parts[0] + "." + parts.dropFirst().joined(separator: "/")]
        }
    }

    // MARK: - MutationTestRunner

    public func runPlainBaseline(progress: ProgressReporter) throws -> TimeInterval {
        let build = try swift(Self.buildArguments, timeout: nil, progress: progress)
        guard build.succeeded else { throw RunnerSupport.baselineFailure(build) }
        let test = try swift(testArguments, timeout: nil, progress: progress)
        guard test.succeeded else { throw RunnerSupport.baselineFailure(test) }
        return build.duration + test.duration
    }

    public func runCoverageBaseline(progress: ProgressReporter) throws -> CoverageRunResult {
        let started = Date()
        let outcome = try swift(coverageArguments, timeout: nil, progress: progress)
        let index = (try? loadCoverage(producedSince: started, progress: progress)) ?? nil
        return CoverageRunResult(exitCode: outcome.exitCode, coverage: index.map(BaselineCoverage.lines))
    }

    public func prepareMutantRuns(progress: ProgressReporter) throws {
        let build = try swift(Self.buildArguments, timeout: nil, progress: progress)
        guard build.succeeded else { throw RunnerSupport.baselineFailure(build) }
    }

    public func runMutant(timeout: TimeInterval, progress: ProgressReporter) throws -> MutantRunResult {
        let build = try swift(Self.buildArguments, timeout: timeout, progress: progress)
        if build.timedOut { return MutantRunResult(status: .timeout, duration: build.duration) }
        guard build.exitCode == 0 else { return MutantRunResult(status: .compileError, duration: build.duration) }
        let remaining = max(timeout - build.duration, 0.001)
        let test = try swift(testArguments, timeout: remaining, progress: progress)
        let duration = build.duration + test.duration
        if test.timedOut { return MutantRunResult(status: .timeout, duration: duration) }
        return MutantRunResult(status: test.exitCode == 0 ? .survived : .killed, duration: duration)
    }

    public func stop() {
        commands.stop()
    }

    // MARK: - Coverage

    /// Per-line counts from this coverage run, or `nil` when it left none: no
    /// bin path, no fresh `default.profdata`, no test binary, or an export
    /// that fails or names no file.
    func loadCoverage(producedSince started: Date, progress: ProgressReporter) throws -> LineCoverageIndex? {
        let binPath = try swift(Self.binPathArguments, timeout: nil, capture: true, progress: .silent)
        guard binPath.exitCode == 0 else { return nil }
        let binDirectory = String(decoding: binPath.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let profdata = (binDirectory as NSString).appendingPathComponent("codecov/default.profdata")
        guard Self.isFresh(profdata, since: started) else { return nil }
        let binaries = Self.testBinaries(in: binDirectory)
        guard !binaries.isEmpty else { return nil }
        let export = try commands.run(
            CommandSpec(
                executable: "/usr/bin/xcrun",
                arguments: Self.exportArguments(profdata: profdata, binaries: binaries),
                workingDirectory: projectDirectory,
                environment: RunnerSupport.environment
            ),
            timeout: nil,
            captureStdout: true,
            progress: .silent
        )
        guard export.exitCode == 0 else { return nil }
        let index = LineCoverageIndex(lcov: String(decoding: export.stdout, as: UTF8.self))
        return index.fileCount > 0 ? index : nil
    }

    static func exportArguments(profdata: String, binaries: [String]) -> [String] {
        var arguments = ["llvm-cov", "export", "-format=lcov", "-instr-profile", profdata]
        for (index, binary) in binaries.enumerated() {
            if index > 0 { arguments.append("-object") }
            arguments.append(binary)
        }
        return arguments
    }

    /// The test binaries SwiftPM built: `<Name>.xctest/Contents/MacOS/<Name>`
    /// bundles on macOS, plain `<Name>.xctest` executables elsewhere.
    static func testBinaries(in binDirectory: String) -> [String] {
        let fileManager = FileManager.default
        let entries = ((try? fileManager.contentsOfDirectory(atPath: binDirectory)) ?? [])
            .filter { $0.hasSuffix(".xctest") }
            .sorted()
        return entries.compactMap { entry in
            let path = (binDirectory as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            guard isDirectory.boolValue else { return path }
            let name = (entry as NSString).deletingPathExtension
            let binary = (path as NSString).appendingPathComponent("Contents/MacOS/\(name)")
            return fileManager.fileExists(atPath: binary) ? binary : nil
        }
    }

    /// Whether `path` exists and was written by this run (a stale profile from
    /// an earlier run must not pass for this one's coverage).
    static func isFresh(_ path: String, since started: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return modified >= started.addingTimeInterval(-1)
    }

    // MARK: - Commands

    private func swift(
        _ arguments: [String],
        timeout: TimeInterval?,
        capture: Bool = false,
        progress: ProgressReporter
    ) throws -> CommandOutcome {
        let outcome = try commands.run(
            CommandSpec(
                executable: swiftExecutable,
                arguments: arguments,
                workingDirectory: projectDirectory,
                environment: RunnerSupport.environment
            ),
            timeout: timeout,
            captureStdout: capture,
            progress: progress
        )
        try RunnerSupport.checkLaunched(outcome, runner: "swift")
        return outcome
    }
}
