import Foundation
import Testing
import ArgumentParser
@testable import SlopguardCore
@testable import SlopguardMutation
@testable import SlopguardCLI

/// Returns a canned report (or error) and records the options it got.
private final class StubPipeline: MutationRunning, @unchecked Sendable {
    let result: Result<MutationReport, Error>
    private let lock = NSLock()
    private var _options: [MutationPipeline.Options] = []
    var options: [MutationPipeline.Options] { lock.withLock { _options } }

    init(_ result: Result<MutationReport, Error>) {
        self.result = result
    }

    func run(_ options: MutationPipeline.Options, progress: ProgressReporter) async throws -> MutationReport {
        lock.withLock { _options.append(options) }
        return try result.get()
    }
}

private final class Output: @unchecked Sendable {
    var stdout = ""
    var stderr = ""
}

private func report(score killed: Int, survived: Int) -> MutationReport {
    let mutants = (0..<(killed + survived)).map { index in
        MutantResult(id: "F.swift:\(index + 1):1:boundary", file: "F.swift", line: index + 1, column: 1,
                     mutationOperator: .boundary, original: "<", replacement: "<=", method: nil,
                     status: index < killed ? .killed : .survived)
    }
    return MutationReport(sourceRoot: "/p/Sources", projectRoot: "/p", runner: "swift test", timeoutSeconds: 61,
                          coverageAvailable: true, operators: MutationOperator.allCases, notes: [],
                          summary: MutationReport.Summary(mutants: mutants, fileCount: 1), mutants: mutants)
}

/// Parse `arguments` as `mutate` and run it against `pipeline`.
private func run(_ arguments: [String], pipeline: some MutationRunning) async throws -> (code: Int32, output: Output) {
    let command = try MutateCommand.parse(arguments + ["--quiet"])
    let output = Output()
    let code = await command.execute(pipeline: pipeline, stdout: { output.stdout += $0 }, stderr: { output.stderr += $0 })
    return (code, output)
}

@Suite("mutate command")
struct MutateCommandTests {

    @Test("mutate is a subcommand; analyze stays the default")
    func registration() throws {
        #expect(Slopguard.configuration.subcommands.contains { $0 == MutateCommand.self })
        #expect(Slopguard.configuration.defaultSubcommand == AnalyzeCommand.self)
        #expect(try Slopguard.parseAsRoot(["mutate", "--dry-run"]) is MutateCommand)
        #expect(try Slopguard.parseAsRoot(["--path", "."]) is AnalyzeCommand)
    }

    @Test("analyze-only flags are unknown to mutate", arguments: [
        ["--threshold", "30"], ["--fail-over", "50"], ["--xcresult", "x.xcresult"], ["--coverage-file", "c.json"]
    ])
    func analyzeOnlyFlags(arguments: [String]) {
        #expect(throws: (any Error).self) { try MutateCommand.parse(arguments) }
    }

    @Test("flags map onto pipeline options")
    func optionsMapping() throws {
        let command = try MutateCommand.parse([
            "--path", "/p/Sources", "--project-dir", "/p", "--operators", "remove_not,boundary", "--operators", "logical",
            "--include", "**/A.swift", "**/B.swift", "--exclude", "**/Gen/**", "--no-default-excludes",
            "--runner", "xcodebuild", "--scheme", "App", "--workspace", "/p/App.xcworkspace",
            "--destination", "platform=macOS", "--only-testing", "AppTests/A", "AppTests/B",
            "--no-coverage", "--timeout", "2.5", "--fail-under", "80"
        ])
        let (options, failUnder) = try command.pipelineOptions()
        #expect(options.sourceURL.path == "/p/Sources")
        #expect(options.projectDirectory?.path == "/p")
        #expect(options.operators == [.boundary, .logical, .removeNot])
        #expect(options.analysisOptions.includeGlobs == ["**/A.swift", "**/B.swift"])
        #expect(options.analysisOptions.excludeGlobs == ["**/Gen/**"])
        #expect(options.runner == .xcodebuild)
        #expect(options.scheme == "App")
        #expect(options.workspace?.path == "/p/App.xcworkspace")
        #expect(options.destination == "platform=macOS")
        #expect(options.onlyTesting == ["AppTests/A", "AppTests/B"])
        #expect(!options.coverage)
        #expect(options.timeoutSeconds == 2.5)
        #expect(!options.dryRun)
        #expect(failUnder == 80)

        let defaults = try MutateCommand.parse([]).pipelineOptions().options
        #expect(defaults.operators == MutationOperator.allCases)
        #expect(defaults.analysisOptions.excludeGlobs == AnalysisOptions.defaultExcludeGlobs)
        #expect(defaults.runner == nil && defaults.projectDirectory == nil && defaults.timeoutSeconds == nil)
        #expect(defaults.coverage)
        #expect(defaults.sourceURL.path == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
    }

    @Test("flag validation errors are invalid_argument, exit 1, and never start a run", arguments: zip([
        ["--operators", "bogus"],
        ["--timeout", "0"],
        ["--timeout=-5"],
        ["--timeout", "soon"],
        ["--fail-under", "high"],
        ["--runner", "gradle"],
        ["--runner", "swift-test", "--scheme", "App"],
        ["--runner", "swift-test", "--destination", "platform=macOS"]
    ], [
        "--operators", "--timeout", "--timeout", "--timeout", "--fail-under", "--runner", "--scheme", "--destination"
    ]))
    func validation(arguments: [String], flag: String) async throws {
        let pipeline = StubPipeline(.success(report(score: 1, survived: 0)))
        let (code, output) = try await run(arguments, pipeline: pipeline)
        #expect(code == 1)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.hasPrefix("slopguard-swift: [invalid_argument] Invalid argument '\(flag)'"))
        #expect(pipeline.options.isEmpty)
    }

    @Test("--json errors are a JSON envelope on stderr")
    func jsonError() async throws {
        let (code, output) = try await run(["--json", "--timeout", "0"], pipeline: StubPipeline(.success(report(score: 1, survived: 0))))
        #expect(code == 1)
        let envelope = try JSONSerialization.jsonObject(with: Data(output.stderr.utf8)) as? [String: [String: String]]
        #expect(envelope?["error"]?["code"] == "invalid_argument")
        #expect(envelope?["error"]?["message"] == "Invalid argument '--timeout': not a positive number: 0")
    }

    @Test("pipeline errors keep their code; unknown errors are internal_error")
    func pipelineErrors() async throws {
        let failed = StubPipeline(.failure(SlopguardError.baselineFailed(exitCode: 1, output: "boom")))
        let (code, output) = try await run([], pipeline: failed)
        #expect(code == 1)
        #expect(output.stderr == "slopguard-swift: [baseline_failed] The test suite fails without any mutation (exit 1). Fix the failing tests first: boom\n")
        struct Odd: Error {}
        let odd = try await run([], pipeline: StubPipeline(.failure(Odd())))
        #expect(odd.code == 1)
        #expect(odd.output.stderr.hasPrefix("slopguard-swift: [internal_error]"))
    }

    @Test("--fail-under: exit 2 strictly below, with one stderr line")
    func failUnder() async throws {
        let half = StubPipeline(.success(report(score: 1, survived: 1)))
        let below = try await run(["--fail-under", "90"], pipeline: half)
        #expect(below.code == 2)
        #expect(below.output.stderr == "slopguard-swift: mutation score 50.00% is below --fail-under 90.0\n")
        #expect(below.output.stdout.contains("score:          50.00%"))
        #expect(try await run(["--fail-under", "50"], pipeline: half).code == 0)
        #expect(try await run([], pipeline: half).code == 0)
        let noScore = StubPipeline(.success(report(score: 0, survived: 0)))
        #expect(try await run(["--fail-under", "100"], pipeline: noScore).code == 0)
    }

    @Test("dry run end to end: lists pending mutants, touches nothing, ignores --fail-under")
    func dryRun() async throws {
        try await withTemporaryDirectory { root in
            let source = "func f(a: Int, b: Int) -> Bool { a > b }\n"
            let file = try write(source, to: "Sources/F.swift", in: root)
            let pipeline = MutationPipeline(guardRoot: root.appendingPathComponent("guards"), interrupts: noInterrupts)
            let json = try await run(["--path", root.appendingPathComponent("Sources").path, "--dry-run", "--json", "--fail-under", "90"],
                                     pipeline: pipeline)
            #expect(json.code == 0)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.output.stdout.utf8)) as? [String: Any])
            #expect(object["runner"] is NSNull && object["projectRoot"] is NSNull && object["timeoutSeconds"] is NSNull)
            #expect(object["coverageAvailable"] as? Bool == false)
            let summary = try #require(object["summary"] as? [String: Any])
            #expect(summary["pending"] as? Int == 2)
            #expect(summary["mutationScore"] is NSNull)

            let text = try await run(["--path", root.appendingPathComponent("Sources").path, "--dry-run"], pipeline: pipeline)
            #expect(text.output.stdout.contains("runner:    (not run)"))
            #expect(text.output.stdout.contains("Mutants (2, not run)\n  F.swift:1:36  boundary  `>` → `>=`  f(a:b:)\n"))
            #expect(try read(file) == source)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("guards").path))
        }
    }

    @Test("--quiet wins over --verbose")
    func progress() throws {
        #expect(try MutateCommand.parse([]).resolveProgressReporter().verbosity == .normal)
        #expect(try MutateCommand.parse(["-v"]).resolveProgressReporter().verbosity == .verbose)
        #expect(try MutateCommand.parse(["--quiet", "--verbose"]).resolveProgressReporter().verbosity == .silent)
    }
}

@Suite("error codes")
struct MutationErrorTests {

    @Test("the new codes and messages")
    func codes() {
        let cases: [(SlopguardError, String, String)] = [
            (.baselineFailed(exitCode: 2, output: "tail"), "baseline_failed",
             "The test suite fails without any mutation (exit 2). Fix the failing tests first: tail"),
            (.baselineFailed(exitCode: nil, output: "tail"), "baseline_failed",
             "The test suite fails without any mutation (exit unknown). Fix the failing tests first: tail"),
            (.mutationInProgress(pid: 77, projectRoot: "/p"), "mutation_in_progress",
             "Another slopguard mutate run (pid 77) is using /p."),
            (.restoreFailed(path: "/p/F.swift", backupPath: "/t/original", underlying: "EACCES"), "restore_failed",
             "Could not restore /p/F.swift after mutation: EACCES. The original is saved at /t/original."),
            (.runnerUnavailable(reason: "no swift"), "runner_unavailable", "Test runner is unavailable: no swift")
        ]
        for (error, code, message) in cases {
            #expect(error.code == code)
            #expect(error.message == message)
        }
        #expect(SlopguardError.runnerNotDetected(projectDirectory: "/p").code == "runner_not_detected")
    }
}
