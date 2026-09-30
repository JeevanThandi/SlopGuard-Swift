import Foundation
import Testing
@testable import SlopguardCore
@testable import SlopguardMutation

private let fixtureSource = """
func f(a: Int, b: Int) -> Bool {
    a > b
}
func g(x: Bool) -> Bool { !x }

"""

/// A package with one source file (3 mutants: boundary + negate_conditional
/// on line 2, remove_not on line 4) and a private guard root.
private struct PipelineFixture {
    let root: URL
    let project: URL
    let file: URL
    let guardRoot: URL

    init(_ root: URL, source: String = fixtureSource) throws {
        self.root = root
        project = root.appendingPathComponent("project", isDirectory: true)
        guardRoot = root.appendingPathComponent("guards", isDirectory: true)
        try FileManager.default.createDirectory(at: guardRoot, withIntermediateDirectories: true)
        try write("// swift-tools-version: 6.0\n", to: "Package.swift", in: project)
        file = try write(source, to: "Sources/Lib/F.swift", in: project)
    }

    var sources: URL { project.appendingPathComponent("Sources") }

    func pipeline(_ runner: FakeMutationRunner, interrupts: MutationPipeline.InterruptHandling = noInterrupts) -> MutationPipeline {
        MutationPipeline(makeRunner: { _, _ in runner }, guardRoot: guardRoot, interrupts: interrupts)
    }

    func options(coverage: Bool = true, timeout: Double? = nil, dryRun: Bool = false) -> MutationPipeline.Options {
        MutationPipeline.Options(sourceURL: sources, runner: .swiftTest, coverage: coverage, timeoutSeconds: timeout, dryRun: dryRun)
    }

    /// lcov with `line → count` for the fixture file.
    func coverage(_ counts: [Int: Int]) -> CoverageRunResult {
        let records = counts.sorted { $0.key < $1.key }.map { "DA:\($0.key),\($0.value)" }.joined(separator: "\n")
        let index = LineCoverageIndex(lcov: "SF:\(file.path)\n\(records)\nend_of_record\n")
        return CoverageRunResult(exitCode: 0, coverage: .lines(index))
    }

    var guardDirectoryExists: Bool {
        FileManager.default.fileExists(
            atPath: WorkspaceGuard.guardDirectory(projectRoot: project.standardizedFileURL.path, temporaryRoot: guardRoot).path
        )
    }
}

@Suite("mutation pipeline")
struct MutationPipelineTests {

    @Test("baseline → coverage → rebuild → mutants; statuses, no_coverage, timeout and notes")
    func fullFlow() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            runner.coverage = fixture.coverage([2: 3, 4: 0])
            runner.onMutant = { index in [MutantStatus.killed, .compileError][index] }
            let sink = ProgressSink()
            let report = try await fixture.pipeline(runner).run(fixture.options(), progress: sink.reporter())

            #expect(runner.events == ["baseline", "coverage", "prepare", "mutant 0", "mutant 1"])
            #expect(report.mutants.map(\.status) == [.killed, .compileError, .noCoverage])
            #expect(report.mutants.map(\.id) == [
                "Lib/F.swift:2:7:boundary", "Lib/F.swift:2:7:negate_conditional", "Lib/F.swift:4:27:remove_not"
            ])
            #expect(report.mutants.map(\.method) == ["f(a:b:)", "f(a:b:)", "g(x:)"])
            #expect(report.projectRoot == fixture.project.standardizedFileURL.path)
            #expect(report.sourceRoot == fixture.sources.standardizedFileURL.path)
            #expect(report.runner == "swift test")
            #expect(report.timeoutSeconds == 67)   // ceil(2.1 × 3) + 60
            #expect(runner.timeouts == [67, 67])
            #expect(report.coverageAvailable)
            #expect(report.summary.mutationScore == 50)
            #expect(report.notes == ["1 mutant(s) did not compile and are excluded from the score."])
            #expect(try read(fixture.file) == fixtureSource)
            #expect(!fixture.guardDirectoryExists)

            let messages = sink.messages
            #expect(messages.first == "slopguard: walking \(fixture.sources.standardizedFileURL.path)")
            #expect(messages.contains("slopguard: generated 3 mutant(s) in 1 file(s)"))
            #expect(messages.contains("slopguard: running baseline tests (swift test) in \(fixture.project.standardizedFileURL.path)"))
            #expect(messages.contains("slopguard: baseline passed in 2.1s; timeout is 67s per mutant"))
            #expect(messages.contains("slopguard: running swift test with coverage in \(fixture.project.standardizedFileURL.path) — this can take a while"))
            #expect(messages.contains("slopguard: [1/3] killed        Lib/F.swift:2:7 boundary (0.5s)"))
            #expect(messages.contains("slopguard: [3/3] no_coverage   Lib/F.swift:4:27 remove_not"))
            #expect(messages.last == "slopguard: done — 1 killed, 0 timeout, 0 survived, 1 no_coverage, 1 compile_error, 0 ignored")
        }
    }

    @Test("each mutant is in place while its tests run and restored afterwards")
    func mutantInPlace() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            let file = fixture.file
            let seen = ProgressSink()
            runner.onMutant = { _ in
                seen.reporter().phase(String(decoding: try Data(contentsOf: file), as: UTF8.self))
                return .survived
            }
            let report = try await fixture.pipeline(runner).run(fixture.options(coverage: false), progress: .silent)
            #expect(seen.messages == [
                "slopguard: " + fixtureSource.replacingOccurrences(of: "a > b", with: "a >= b"),
                "slopguard: " + fixtureSource.replacingOccurrences(of: "a > b", with: "a <= b"),
                "slopguard: " + fixtureSource.replacingOccurrences(of: "{ !x }", with: "{ x }")
            ])
            #expect(try read(fixture.file) == fixtureSource)
            #expect(report.notes == ["Every tested mutant survived. Check that the tests import the source under --path."])
            #expect(report.summary.mutationScore == 0)
        }
    }

    @Test("an error mid-run restores the file, releases the guard and propagates")
    func restoreOnError() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            runner.onMutant = { index in
                if index == 1 { throw SlopguardError.runnerUnavailable(reason: "swift vanished") }
                return .killed
            }
            await #expect(throws: SlopguardError.self) {
                _ = try await fixture.pipeline(runner).run(fixture.options(coverage: false), progress: .silent)
            }
            #expect(try read(fixture.file) == fixtureSource)
            #expect(!fixture.guardDirectoryExists)
        }
    }

    @Test("a file edited between two mutant runs: no stale mutant, the rest stay pending, a note names the file")
    func fileChangedBetweenMutants() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            let file = fixture.file
            let edited = fixtureSource + "// edited while mutate was running\n"
            // The progress line for mutant 1 comes after its restore and before
            // mutant 2 is written: the moment a person could save the file.
            let reporter = ProgressReporter(
                verbosity: .normal,
                messageSink: { line in
                    if line.contains("[1/3]") { try? Data(edited.utf8).write(to: file) }
                },
                rawSink: { _ in }
            )
            let report = try await fixture.pipeline(runner).run(fixture.options(coverage: false), progress: reporter)
            #expect(runner.events == ["baseline", "mutant 0"])
            #expect(report.mutants.map(\.status) == [.killed, .pending, .pending])
            #expect(report.notes == [
                "\(fixture.file.standardizedFileURL.path) changed while mutate was running, so its remaining mutants were not run."
            ])
            #expect(report.summary.pending == 2)
            #expect(try read(fixture.file) == edited)
            #expect(!fixture.guardDirectoryExists)
        }
    }

    @Test("after a file changes, an ignored mutant stays ignored and only the rest become pending")
    func fileChangedKeepsIgnored() async throws {
        try await withTemporaryDirectory { root in
            let source = """
            func f(x: Bool) -> Bool { !x }
            func g(y: Bool) -> Bool { !y }
            func h(z: Bool) -> Bool { !z } // slopguard-ignore-mutant
            func k(w: Bool) -> Bool { !w }

            """
            let fixture = try PipelineFixture(root, source: source)
            let runner = FakeMutationRunner()
            let file = fixture.file
            let edited = source + "// edited while mutate was running\n"
            // The progress line for mutant 1 comes after its restore and before
            // mutant 2 is written.
            let reporter = ProgressReporter(
                verbosity: .normal,
                messageSink: { line in
                    if line.contains("[1/4]") { try? Data(edited.utf8).write(to: file) }
                },
                rawSink: { _ in }
            )
            let report = try await fixture.pipeline(runner).run(fixture.options(coverage: false), progress: reporter)
            #expect(report.mutants.map(\.mutationOperator) == [.removeNot, .removeNot, .removeNot, .removeNot])
            #expect(report.mutants.map(\.status) == [.killed, .pending, .ignored, .pending])
            #expect(runner.events == ["baseline", "mutant 0"])
            #expect(report.summary.pending == 2 && report.summary.ignored == 1)
            #expect(report.notes == [
                "\(fixture.file.standardizedFileURL.path) changed while mutate was running, so its remaining mutants were not run."
            ])
            #expect(try read(fixture.file) == edited)
        }
    }

    @Test("a failing plain baseline stops the run before any mutant")
    func baselineFailure() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            runner.baselineError = SlopguardError.baselineFailed(exitCode: 1, output: "✘ 1 test failed")
            do {
                _ = try await fixture.pipeline(runner).run(fixture.options(), progress: .silent)
                Issue.record("expected baseline_failed")
            } catch let error as SlopguardError {
                #expect(error.code == "baseline_failed")
            }
            #expect(runner.events == ["baseline"])
            #expect(try read(fixture.file) == fixtureSource)
            #expect(!fixture.guardDirectoryExists)
        }
    }

    @Test("--timeout is used as given; --no-coverage skips the coverage run")
    func explicitTimeoutAndNoCoverage() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            let report = try await fixture.pipeline(runner).run(fixture.options(coverage: false, timeout: 2.5), progress: .silent)
            #expect(report.timeoutSeconds == 2.5)
            #expect(runner.timeouts == [2.5, 2.5, 2.5])
            #expect(runner.events == ["baseline", "mutant 0", "mutant 1", "mutant 2"])
            #expect(!report.coverageAvailable)
            #expect(report.notes.isEmpty)
        }
    }

    @Test("coverage notes: no usable data, or a failing coverage run whose data is still used")
    func coverageNotes() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let none = FakeMutationRunner()
            none.coverage = CoverageRunResult(exitCode: 1, coverage: nil)
            let without = try await fixture.pipeline(none).run(fixture.options(), progress: .silent)
            #expect(!without.coverageAvailable)
            #expect(without.notes == ["The baseline test run produced no coverage data, so every mutant was run."])
            #expect(without.mutants.allSatisfy { $0.status == .killed })

            let failing = FakeMutationRunner()
            var result = fixture.coverage([2: 1, 4: 0])
            result = CoverageRunResult(exitCode: 1, coverage: result.coverage)
            failing.coverage = result
            let used = try await fixture.pipeline(failing).run(fixture.options(), progress: .silent)
            #expect(used.coverageAvailable)
            #expect(used.notes == ["The coverage run exited with code 1; its coverage data was still used."])
            #expect(used.mutants.map(\.status) == [.killed, .killed, .noCoverage])
        }
    }

    @Test("a coverage run that throws is not fatal: the no-coverage note, and every mutant runs")
    func coverageErrors() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            runner.coverageError = SlopguardError.runnerUnavailable(reason: "llvm-cov is missing")
            let report = try await fixture.pipeline(runner).run(fixture.options(), progress: .silent)
            #expect(runner.events == ["baseline", "coverage", "prepare", "mutant 0", "mutant 1", "mutant 2"])
            #expect(!report.coverageAvailable)
            #expect(report.notes == ["The baseline test run produced no coverage data, so every mutant was run."])
        }
    }

    @Test("dry run: every mutant pending, nothing run, nothing touched")
    func dryRun() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let runner = FakeMutationRunner()
            let report = try await fixture.pipeline(runner).run(fixture.options(dryRun: true), progress: .silent)
            #expect(report.mutants.map(\.status) == [.pending, .pending, .pending])
            #expect(report.projectRoot == nil && report.runner == nil && report.timeoutSeconds == nil)
            #expect(!report.coverageAvailable)
            #expect(report.summary.mutationScore == nil)
            #expect(runner.events.isEmpty)
            #expect(!fixture.guardDirectoryExists)
        }
    }

    @Test("nothing to run (all ignored, or no mutants): no baseline, no runner, null run fields")
    func nothingToRun() async throws {
        try await withTemporaryDirectory { root in
            let ignored = "func f(a: Int, b: Int) -> Bool {\n    a > b // slopguard-ignore-mutant\n}\n"
            let fixture = try PipelineFixture(root, source: ignored)
            let pipeline = MutationPipeline(
                makeRunner: { _, _ in throw SlopguardError.unsupported(reason: "no runner expected") },
                guardRoot: fixture.guardRoot,
                interrupts: noInterrupts
            )
            let report = try await pipeline.run(fixture.options(), progress: .silent)
            #expect(report.mutants.map(\.status) == [.ignored, .ignored])
            #expect(report.runner == nil && report.projectRoot == nil && report.timeoutSeconds == nil)
            #expect(report.summary.mutationScore == nil)

            try write("let quiet = 1\n", to: "Sources/Lib/F.swift", in: fixture.project)
            let empty = try await pipeline.run(fixture.options(), progress: .silent)
            #expect(empty.summary.mutantCount == 0)
            #expect(empty.summary.fileCount == 1)
            #expect(empty.runner == nil)
        }
    }

    @Test("without --runner the project is discovered and the runner detected")
    func detection() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let requests = RequestLog()
            let runner = FakeMutationRunner()
            let pipeline = MutationPipeline(
                makeRunner: { request, _ in
                    requests.append(request)
                    return runner
                },
                guardRoot: fixture.guardRoot,
                interrupts: noInterrupts
            )
            let sink = ProgressSink()
            var options = MutationPipeline.Options(sourceURL: fixture.file, coverage: false)
            options.onlyTesting = ["LibTests/FTests"]
            _ = try await pipeline.run(options, progress: sink.reporter())
            let request = try #require(requests.all.first)
            #expect(request.kind == .swiftTest)
            #expect(request.projectDirectory == fixture.project.standardizedFileURL.path)
            #expect(request.destination == "platform=macOS")
            #expect(request.onlyTesting == ["LibTests/FTests"])
            #expect(sink.messages.contains("slopguard: detecting test runner in \(fixture.project.standardizedFileURL.path)"))
        }
    }

    @Test("a live run holding the guard blocks this one before any test runs")
    func mutationInProgress() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let directory = WorkspaceGuard.guardDirectory(projectRoot: fixture.project.standardizedFileURL.path, temporaryRoot: fixture.guardRoot)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("\(getppid())".utf8).write(to: directory.appendingPathComponent("lock"))
            let runner = FakeMutationRunner()
            do {
                _ = try await fixture.pipeline(runner).run(fixture.options(), progress: .silent)
                Issue.record("expected mutation_in_progress")
            } catch let error as SlopguardError {
                #expect(error.code == "mutation_in_progress")
            }
            #expect(runner.events.isEmpty)
        }
    }

    @Test("a signal mid-mutant stops the runner, restores the file, releases the guard and exits 128 + signal")
    func interrupt() async throws {
        try await withTemporaryDirectory { root in
            let fixture = try PipelineFixture(root)
            let interrupts = FakeInterrupts()
            let runner = FakeMutationRunner()
            let file = fixture.file
            runner.onMutant = { _ in
                let during = try read(file)
                #expect(during != fixtureSource)
                interrupts.deliver(SIGINT)
                let after = try read(file)
                #expect(after == fixtureSource)
                return .killed
            }
            let sink = ProgressSink()
            await #expect(throws: SlopguardError.self) {
                _ = try await fixture.pipeline(runner, interrupts: interrupts.handling).run(fixture.options(coverage: false), progress: sink.reporter())
            }
            #expect(interrupts.exitCodes == [130])
            #expect(interrupts.installs == 1 && interrupts.uninstalls == 1)
            #expect(runner.events.contains("stop"))
            #expect(sink.messages.contains("slopguard: interrupted — restored \(fixture.file.standardizedFileURL.path)"))
            #expect(try read(fixture.file) == fixtureSource)
            #expect(!fixture.guardDirectoryExists)
            #expect(SignalTrap.exitCode(for: SIGTERM) == 143 && SignalTrap.exitCode(for: SIGHUP) == 129)
        }
    }
}

/// Thread-safe log of runner requests.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [MutationPipeline.RunnerRequest] = []
    func append(_ request: MutationPipeline.RunnerRequest) { lock.withLock { requests.append(request) } }
    var all: [MutationPipeline.RunnerRequest] { lock.withLock { requests } }
}

@Suite("signal trap")
struct SignalTrapTests {

    @Test("a trapped signal reaches the handler instead of killing the process; uninstall restores the old action")
    func trap() async throws {
        let received = ProgressSink()
        let uninstall = SignalTrap.install([SIGUSR2]) { signal in received.reporter().phase("\(signal)") }
        kill(getpid(), SIGUSR2)
        let deadline = Date().addingTimeInterval(10)
        while received.messages.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        uninstall()
        #expect(received.messages == ["slopguard: \(SIGUSR2)"])
        var action = sigaction()
        sigaction(SIGUSR2, nil, &action)
        #expect(action.__sigaction_u.__sa_handler == nil, "SIG_DFL is the null handler")
    }
}
