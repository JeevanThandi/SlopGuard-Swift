import Foundation
import ArgumentParser
import SlopguardCore
import SlopguardMutation

/// Anything that can run `mutate` for the command — the real
/// `MutationPipeline`, or a stub in tests.
protocol MutationRunning: Sendable {
    func run(_ options: MutationPipeline.Options, progress: ProgressReporter) async throws -> MutationReport
}

extension MutationPipeline: MutationRunning {}

struct MutateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutate",
        abstract: "Mutate the source one change at a time, run the tests against each mutant, and report the mutants the tests miss.",
        discussion: """
            Each mutant is written into its source file in place, tested, and restored. \
            One mutate run per project can hold the workspace guard. SIGINT, SIGTERM and \
            SIGHUP restore the file before exit, and the next run recovers a file that a \
            crash left mutated.

            Runner: --runner swift-test|xcodebuild when given. Otherwise xcodebuild when \
            --scheme or --workspace is passed or the project directory holds an \
            .xcodeproj / .xcworkspace, else swift test when it holds a Package.swift.

            Statuses: killed (a test failed), survived (every test passed), timeout \
            (counted as killed), no_coverage (no test runs the line), compile_error \
            (excluded from the score), ignored, pending (--dry-run, or its file changed \
            during the run).
            Operators: \(MutationOperator.allCases.map(\.rawValue).joined(separator: ", ")).
            Ignore marker, on the mutated line or on a comment line above it:
              // slopguard-ignore-mutant(boundary): equal values assign the same max

            Examples:
              slopguard-swift mutate --path Sources/MyLib/Store.swift  # one file
              slopguard-swift mutate --path Sources --operators boundary,logical
              slopguard-swift mutate --path Sources --dry-run          # list, run nothing
              slopguard-swift mutate --path . --scheme MyApp           # Xcode project
              slopguard-swift mutate --path Sources --json | jq .summary
              slopguard-swift mutate --path Sources --fail-under 80    # CI gate
            """
    )

    @Option(name: [.short, .long], help: "Directory of Swift sources, or a single .swift file, to mutate. Defaults to the current directory.")
    var path: String = "."

    @Option(name: .long, parsing: .upToNextOption, help: "Only mutate files matching these glob(s). Repeat or pass space-separated.")
    var include: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Extra glob(s) of files / directories to skip. Combined with the built-in defaults (.build, Pods, Carthage, Generated, *Tests, *Spec, etc.).")
    var exclude: [String] = []

    @Flag(name: .long, help: "Skip the built-in default excludes.")
    var noDefaultExcludes: Bool = false

    @Option(name: .long, help: "Mutation operators to apply, comma-separated or repeated. Defaults to all.")
    var operators: [String] = []

    @Option(name: .long, help: "Test runner to drive: swift-test or xcodebuild. Chosen from the project when omitted.")
    var runner: String?

    @Option(name: .long, help: "Project directory the tests run in. Defaults to the nearest Package.swift / .xcodeproj / .xcworkspace above --path.")
    var projectDir: String?

    @Option(name: .long, help: "xcodebuild scheme. Auto-discovered when omitted. Selects the xcodebuild runner.")
    var scheme: String?

    @Option(name: .long, help: "Path to an .xcworkspace passed as -workspace to xcodebuild. Selects the xcodebuild runner.")
    var workspace: String?

    @Option(name: .long, help: "xcodebuild destination string. Defaults to platform=macOS.")
    var destination: String?

    @Option(name: .customLong("only-testing"), parsing: .upToNextOption,
            help: "Test identifier(s) such as MyAppTests/LoginTests. xcodebuild gets -only-testing:<id>; swift test gets --filter MyAppTests.LoginTests.")
    var onlyTesting: [String] = []

    @Flag(name: .long, help: "Skip the coverage run and test every mutant, including mutants on lines no test executes.")
    var noCoverage: Bool = false

    @Option(name: .long, help: "Per-mutant timeout in seconds (build and test). Defaults to 3 × the baseline run time + 60.")
    var timeout: String?

    @Flag(name: .long, help: "List the mutants without running any tests or touching any file.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit JSON to stdout (default is pretty text).")
    var json: Bool = false

    @Option(name: .long, help: "Exit with code 2 if the mutation score (0-100) is below this value. Ignored with --dry-run.")
    var failUnder: String?

    @Flag(name: [.short, .long], help: "Stream test-runner output to stderr.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Suppress all progress chatter on stderr. The report on stdout is unaffected.")
    var quiet: Bool = false

    mutating func run() async throws {
        let code = await execute(
            pipeline: MutationPipeline(),
            stdout: { FileHandle.standardOutput.write(Data($0.utf8)) },
            stderr: { FileHandle.standardError.write(Data($0.utf8)) }
        )
        if code != 0 { throw ExitCode(code) }
    }

    /// Everything after flag parsing, with injectable output: validate, run,
    /// print the report, apply `--fail-under`. Returns the exit code.
    func execute(
        pipeline: some MutationRunning,
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> Int32 {
        let parsed: (options: MutationPipeline.Options, failUnder: Double?)
        let report: MutationReport
        do {
            parsed = try pipelineOptions()
            report = try await pipeline.run(parsed.options, progress: resolveProgressReporter())
        } catch let error as SlopguardError {
            stderr(errorText(SlopguardErrorEnvelope(error)))
            return 1
        } catch {
            stderr(errorText(SlopguardErrorEnvelope(code: "internal_error", message: "\(error)")))
            return 1
        }

        if json {
            let data = (try? MutationReportFormatter.json(report)) ?? Data()
            stdout(String(decoding: data, as: UTF8.self) + "\n")
        } else {
            stdout(MutationReportFormatter.pretty(report))
        }

        if let failUnder = parsed.failUnder, !dryRun,
           let score = report.summary.mutationScore, score < failUnder {
            stderr("\(SlopguardVersion.toolName): mutation score \(String(format: "%.2f", score))% is below --fail-under \(failUnder)\n")
            return 2
        }
        return 0
    }

    /// Validate the flags and turn them into pipeline options. Throws
    /// `invalid_argument`.
    func pipelineOptions() throws -> (options: MutationPipeline.Options, failUnder: Double?) {
        let operatorIDs = try MutationOperator.parse(operators)

        var timeoutSeconds: Double?
        if let timeout {
            guard let value = Double(timeout.trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0 else {
                throw SlopguardError.invalidArgument(name: "--timeout", reason: "not a positive number: \(timeout)")
            }
            timeoutSeconds = value
        }

        var failUnderScore: Double?
        if let failUnder {
            guard let value = Double(failUnder.trimmingCharacters(in: .whitespaces)), value.isFinite else {
                throw SlopguardError.invalidArgument(name: "--fail-under", reason: "not a number: \(failUnder)")
            }
            failUnderScore = value
        }

        var runnerKind: MutationRunnerKind?
        if let runner {
            guard let kind = MutationRunnerKind(rawValue: runner) else {
                let expected = MutationRunnerKind.allCases.map(\.rawValue).joined(separator: ", ")
                throw SlopguardError.invalidArgument(
                    name: "--runner",
                    reason: "'\(runner)' is not supported (expected one of: \(expected))"
                )
            }
            runnerKind = kind
        }
        if runnerKind == .swiftTest {
            for (flag, value) in [("--scheme", scheme), ("--workspace", workspace), ("--destination", destination)]
            where value != nil {
                throw SlopguardError.invalidArgument(name: flag, reason: "applies only to the xcodebuild runner")
            }
        }

        let baseExcludes = noDefaultExcludes ? [] : AnalysisOptions.defaultExcludeGlobs
        let options = MutationPipeline.Options(
            sourceURL: resolvePath(path),
            analysisOptions: AnalysisOptions(includeGlobs: include, excludeGlobs: baseExcludes + exclude, followSymlinks: false),
            operators: operatorIDs,
            runner: runnerKind,
            projectDirectory: projectDir.map(resolvePath),
            scheme: scheme,
            workspace: workspace.map(resolvePath),
            destination: destination,
            onlyTesting: onlyTesting,
            coverage: !noCoverage,
            timeoutSeconds: timeoutSeconds,
            dryRun: dryRun
        )
        return (options, failUnderScore)
    }

    /// `--quiet` wins over `--verbose`; neither means default phase markers.
    func resolveProgressReporter() -> ProgressReporter {
        if quiet { return .silent }
        return .stderr(verbosity: verbose ? .verbose : .normal)
    }

    /// The error envelope as JSON under `--json`, else one line of text.
    private func errorText(_ envelope: SlopguardErrorEnvelope) -> String {
        if json, let data = try? CrapReportFormatter.errorJSON(envelope) {
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        return CrapReportFormatter.errorText(envelope) + "\n"
    }
}
