import Foundation
import Testing
@testable import SlopguardCore
@testable import SlopguardCoverage
@testable import SlopguardMutation

/// Answers `swift build` / `swift test` calls from a table keyed by the
/// first argument; anything unscripted exits 0.
private func scripted(_ table: [String: CommandOutcome]) -> FakeCommandRunner {
    FakeCommandRunner { spec in table[spec.arguments.first ?? ""] ?? CommandOutcome(exitCode: 0, duration: 1) }
}

private let xccovJSON = """
{
  "coveredLines": 2, "executableLines": 6, "lineCoverage": 0.33,
  "targets": [{
    "name": "App", "coveredLines": 2, "executableLines": 6, "lineCoverage": 0.33,
    "files": [{
      "name": "Store.swift", "path": "/p/Sources/Store.swift",
      "coveredLines": 2, "executableLines": 6, "lineCoverage": 0.33,
      "functions": [
        {"name": "Store.run()", "lineNumber": 3, "executionCount": 0, "coveredLines": 0, "executableLines": 3, "lineCoverage": 0},
        {"name": "Store.used()", "lineNumber": 10, "executionCount": 4, "coveredLines": 2, "executableLines": 3, "lineCoverage": 0.66}
      ]
    }]
  }]
}
"""

@Suite("runner selection")
struct RunnerSelectionTests {

    @Test func rules() throws {
        try withTemporaryDirectory { root in
            let path = root.path
            #expect(throws: SlopguardError.self) { try RunnerSelection.detect(scheme: nil, workspace: nil, projectDirectory: path) }
            #expect(try RunnerSelection.detect(scheme: "App", workspace: nil, projectDirectory: path) == .xcodebuild)
            #expect(try RunnerSelection.detect(scheme: nil, workspace: "/w/App.xcworkspace", projectDirectory: path) == .xcodebuild)
            try write("// swift-tools-version: 6.0\n", to: "Package.swift", in: root)
            #expect(try RunnerSelection.detect(scheme: nil, workspace: nil, projectDirectory: path) == .swiftTest)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
            #expect(try RunnerSelection.detect(scheme: nil, workspace: nil, projectDirectory: path) == .xcodebuild)
        }
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcworkspace"), withIntermediateDirectories: true)
            #expect(try RunnerSelection.detect(scheme: nil, workspace: nil, projectDirectory: root.path) == .xcodebuild)
        }
    }

    @Test("runner_not_detected names the directory")
    func notDetected() {
        do {
            _ = try RunnerSelection.detect(scheme: nil, workspace: nil, projectDirectory: "/no/such/project")
            Issue.record("expected runner_not_detected")
        } catch let error as SlopguardError {
            #expect(error.code == "runner_not_detected")
            #expect(error.message.contains("/no/such/project"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("swift test runner")
struct SwiftTestRunnerTests {

    @Test("commands: build-tests, then test without building or coverage, in the project, with CI=1")
    func arguments() throws {
        let commands = scripted([:])
        let runner = SwiftTestMutationRunner(projectDirectory: "/p", onlyTesting: ["AppTests/LoginTests"], commands: commands)
        _ = try runner.runMutant(timeout: 30, progress: .silent)
        let calls = commands.calls
        #expect(calls.map(\.spec.arguments) == [
            ["build", "--build-tests"],
            ["test", "--skip-build", "--disable-code-coverage", "--filter", "AppTests.LoginTests"]
        ])
        #expect(calls.allSatisfy { $0.spec.executable == "swift" && $0.spec.workingDirectory == "/p" })
        #expect(calls.allSatisfy { $0.spec.environment["CI"] == "1" && $0.spec.environment["NO_COLOR"] == "1" })
        #expect(calls[0].timeout == 30)
        #expect(calls[1].timeout == 29)
        #expect(runner.coverageArguments == ["test", "--enable-code-coverage", "--filter", "AppTests.LoginTests"])
    }

    @Test("--only-testing identifiers become SwiftPM filters")
    func filters() {
        #expect(SwiftTestMutationRunner.filterArguments(["App", "App/Login", "App/Login/testA"]) ==
            ["--filter", "App", "--filter", "App.Login", "--filter", "App.Login/testA"])
    }

    @Test("classification: compile error, kill, survivor, timeout in either step")
    func classification() throws {
        func status(_ table: [String: CommandOutcome]) throws -> MutantStatus {
            try SwiftTestMutationRunner(projectDirectory: "/p", commands: scripted(table)).runMutant(timeout: 30, progress: .silent).status
        }
        #expect(try status(["build": CommandOutcome(exitCode: 1)]) == .compileError)
        #expect(try status(["build": CommandOutcome(exitCode: nil, timedOut: true)]) == .timeout)
        #expect(try status(["test": CommandOutcome(exitCode: 1)]) == .killed)
        #expect(try status(["test": CommandOutcome(exitCode: nil)]) == .killed)
        #expect(try status(["test": CommandOutcome(exitCode: nil, timedOut: true)]) == .timeout)
        #expect(try status([:]) == .survived)
        let commands = scripted(["build": CommandOutcome(exitCode: 1)])
        _ = try SwiftTestMutationRunner(projectDirectory: "/p", commands: commands).runMutant(timeout: 30, progress: .silent)
        #expect(commands.calls.count == 1)
    }

    @Test("the plain baseline runs both steps without a timeout and fails with the output tail")
    func plainBaseline() throws {
        let passing = scripted(["build": CommandOutcome(exitCode: 0, duration: 3), "test": CommandOutcome(exitCode: 0, duration: 1.5)])
        #expect(try SwiftTestMutationRunner(projectDirectory: "/p", commands: passing).runPlainBaseline(progress: .silent) == 4.5)
        #expect(passing.calls.allSatisfy { $0.timeout == nil })

        let failing = scripted(["test": CommandOutcome(exitCode: 1, outputTail: "\n✘ Test addAppendsToEnd() failed\n")])
        do {
            _ = try SwiftTestMutationRunner(projectDirectory: "/p", commands: failing).runPlainBaseline(progress: .silent)
            Issue.record("expected baseline_failed")
        } catch let error as SlopguardError {
            #expect(error.code == "baseline_failed")
            #expect(error.message == "The test suite fails without any mutation (exit 1). Fix the failing tests first: ✘ Test addAppendsToEnd() failed")
        }
    }

    @Test("xcrun's own errors are runner_unavailable, not test failures")
    func xcrunErrors() {
        let broken = scripted(["build": CommandOutcome(exitCode: 1, outputTail: "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)\n")])
        do {
            _ = try SwiftTestMutationRunner(projectDirectory: "/p", commands: broken).runMutant(timeout: 30, progress: .silent)
            Issue.record("expected runner_unavailable")
        } catch let error as SlopguardError {
            #expect(error.code == "runner_unavailable")
        } catch {
            Issue.record("unexpected \(error)")
        }
        // A test that prints such a line in the middle of its output is still a kill.
        let noisy = scripted(["test": CommandOutcome(exitCode: 1, outputTail: "Test output\nxcrun: error: something\n")])
        #expect((try? SwiftTestMutationRunner(projectDirectory: "/p", commands: noisy).runMutant(timeout: 30, progress: .silent).status) == .killed)
    }

    @Test("coverage: bin path → fresh default.profdata + test binary → llvm-cov lcov export")
    func coverage() throws {
        try withTemporaryDirectory { root in
            let bin = root.appendingPathComponent("debug")
            try write("profile", to: "debug/codecov/default.profdata", in: root)
            try write("binary", to: "debug/PkgPackageTests.xctest/Contents/MacOS/PkgPackageTests", in: root)
            let source = try write("let x = 1\n", to: "Sources/F.swift", in: root)
            let lcov = "SF:\(source.path)\nDA:1,0\nend_of_record\n"
            let commands = FakeCommandRunner { spec in
                if spec.arguments == ["build", "--show-bin-path"] {
                    return CommandOutcome(exitCode: 0, stdout: Data("\(bin.path)\n".utf8))
                }
                if spec.executable == "/usr/bin/xcrun" { return CommandOutcome(exitCode: 0, stdout: Data(lcov.utf8)) }
                return CommandOutcome(exitCode: 1)   // the coverage test run itself failed
            }
            let runner = SwiftTestMutationRunner(projectDirectory: root.path, commands: commands)
            let result = try runner.runCoverageBaseline(progress: .silent)
            #expect(result.exitCode == 1)
            guard case .lines(let index)? = result.coverage else {
                Issue.record("expected line coverage")
                return
            }
            #expect(index.count(absolutePath: source.path, line: 1) == 0)
            let export = try #require(commands.calls.last)
            #expect(export.captureStdout)
            #expect(export.spec.arguments == [
                "llvm-cov", "export", "-format=lcov", "-instr-profile",
                bin.appendingPathComponent("codecov/default.profdata").path,
                bin.appendingPathComponent("PkgPackageTests.xctest/Contents/MacOS/PkgPackageTests").path
            ])
        }
    }

    @Test("no usable coverage: stale profile, no test binary, failed export")
    func coverageMissing() throws {
        try withTemporaryDirectory { root in
            let bin = root.appendingPathComponent("debug")
            let profdata = try write("profile", to: "debug/codecov/default.profdata", in: root)
            let binPath = FakeCommandRunner { spec in
                spec.arguments.first == "build" ? CommandOutcome(exitCode: 0, stdout: Data(bin.path.utf8)) : CommandOutcome(exitCode: 0)
            }
            // No .xctest bundle yet.
            #expect(try SwiftTestMutationRunner(projectDirectory: root.path, commands: binPath).runCoverageBaseline(progress: .silent).coverage == nil)
            try write("binary", to: "debug/P.xctest/Contents/MacOS/P", in: root)
            // Export succeeds but names no file.
            #expect(try SwiftTestMutationRunner(projectDirectory: root.path, commands: binPath).runCoverageBaseline(progress: .silent).coverage == nil)
            // A profile older than the run is stale.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: profdata.path)
            #expect(!SwiftTestMutationRunner.isFresh(profdata.path, since: Date()))
            #expect(SwiftTestMutationRunner.testBinaries(in: bin.path) == [bin.appendingPathComponent("P.xctest/Contents/MacOS/P").path])
        }
    }

    @Test("a real long-running test process is killed on timeout; a failed build is a compile error")
    func realProcesses() throws {
        try withTemporaryDirectory { root in
            // A stand-in for `swift`: marker files choose what build and test do.
            let script = try write("""
            #!/bin/sh
            case "$1" in
              build) if [ -f build-fails ]; then echo "error: cannot find 'x' in scope" >&2; exit 1; fi ;;
              test) if [ -f test-hangs ]; then sleep 300 & wait; fi
                    if [ -f test-fails ]; then exit 1; fi ;;
            esac
            exit 0
            """, to: "bin/swift", in: root)
            chmod(script.path, 0o755)
            let runner = SwiftTestMutationRunner(projectDirectory: root.path, swiftExecutable: script.path)

            #expect(try runner.runMutant(timeout: 60, progress: .silent).status == .survived)
            try write("", to: "test-fails", in: root)
            #expect(try runner.runMutant(timeout: 60, progress: .silent).status == .killed)
            try FileManager.default.removeItem(at: root.appendingPathComponent("test-fails"))

            try write("", to: "test-hangs", in: root)
            let started = Date()
            let hung = try runner.runMutant(timeout: 2, progress: .silent)
            #expect(hung.status == .timeout)
            #expect(Date().timeIntervalSince(started) < 60)
            try FileManager.default.removeItem(at: root.appendingPathComponent("test-hangs"))

            try write("", to: "build-fails", in: root)
            #expect(try runner.runMutant(timeout: 60, progress: .silent).status == .compileError)
        }
    }
}

@Suite("xcodebuild runner")
struct XcodebuildRunnerMutationTests {

    private func runner(_ commands: FakeCommandRunner,
                        readCoverage: @escaping @Sendable (String) throws -> XccovReport = { _ in throw BodyError() }) -> XcodebuildMutationRunner {
        XcodebuildMutationRunner(
            projectDirectory: "/p",
            workspace: "/p/App.xcworkspace",
            scheme: "App",
            destination: "platform=iOS Simulator,name=iPhone 16",
            onlyTesting: ["AppTests/LoginTests"],
            commands: commands,
            readCoverage: readCoverage
        )
    }

    private struct BodyError: Error {}

    @Test("build-for-testing and test-without-building share analyze's plumbing, with coverage off")
    func arguments() throws {
        #expect(XcodebuildMutationRunner.buildForTestingArguments(scheme: "App", workspace: nil, destination: "platform=macOS") ==
            ["xcodebuild", "build-for-testing", "-scheme", "App", "-destination", "platform=macOS", "-enableCodeCoverage", "NO"])
        #expect(XcodebuildMutationRunner.testWithoutBuildingArguments(
            scheme: "App", workspace: "/p/App.xcworkspace", destination: "platform=macOS",
            resultBundlePath: "/tmp/r.xcresult", onlyTesting: ["AppTests/LoginTests", "AppTests/SignupTests/testA"]
        ) == [
            "xcodebuild", "test-without-building", "-workspace", "/p/App.xcworkspace",
            "-scheme", "App", "-destination", "platform=macOS",
            "-resultBundlePath", "/tmp/r.xcresult", "-enableCodeCoverage", "NO",
            "-only-testing:AppTests/LoginTests", "-only-testing:AppTests/SignupTests/testA"
        ])

        let commands = FakeCommandRunner { _ in CommandOutcome(exitCode: 0, duration: 2) }
        _ = try runner(commands).runMutant(timeout: 100, progress: .silent)
        let calls = commands.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.spec.executable == "/usr/bin/xcrun" && $0.spec.workingDirectory == "/p" })
        #expect(calls[0].spec.arguments == XcodebuildMutationRunner.buildForTestingArguments(
            scheme: "App", workspace: "/p/App.xcworkspace", destination: "platform=iOS Simulator,name=iPhone 16"))
        let testArguments = calls[1].spec.arguments
        #expect(testArguments.starts(with: ["xcodebuild", "test-without-building", "-workspace", "/p/App.xcworkspace"]))
        #expect(testArguments.last == "-only-testing:AppTests/LoginTests")
        #expect(calls[0].timeout == 100)
        #expect(calls[1].timeout == 98)
        let bundle = try #require(testArguments.firstIndex(of: "-resultBundlePath").map { testArguments[$0 + 1] })
        #expect(!FileManager.default.fileExists(atPath: (bundle as NSString).deletingLastPathComponent))
    }

    @Test("classification: compile error, kill, survivor, timeout")
    func classification() throws {
        func status(build: CommandOutcome, test: CommandOutcome) throws -> MutantStatus {
            let commands = FakeCommandRunner { spec in spec.arguments[1] == "build-for-testing" ? build : test }
            return try runner(commands).runMutant(timeout: 30, progress: .silent).status
        }
        let ok = CommandOutcome(exitCode: 0)
        #expect(try status(build: CommandOutcome(exitCode: 65), test: ok) == .compileError)
        #expect(try status(build: CommandOutcome(exitCode: nil, timedOut: true), test: ok) == .timeout)
        #expect(try status(build: ok, test: CommandOutcome(exitCode: 65)) == .killed)
        #expect(try status(build: ok, test: CommandOutcome(exitCode: nil, timedOut: true)) == .timeout)
        #expect(try status(build: ok, test: ok) == .survived)
    }

    @Test("baseline failure, and xcrun without xcodebuild is runner_unavailable")
    func failures() throws {
        let failing = FakeCommandRunner { spec in
            spec.arguments[1] == "test-without-building" ? CommandOutcome(exitCode: 65, outputTail: "** TEST FAILED **") : CommandOutcome(exitCode: 0)
        }
        do {
            _ = try runner(failing).runPlainBaseline(progress: .silent)
            Issue.record("expected baseline_failed")
        } catch let error as SlopguardError {
            #expect(error.code == "baseline_failed")
            #expect(error.message.hasSuffix("(exit 65). Fix the failing tests first: ** TEST FAILED **"))
        }
        let missing = FakeCommandRunner { _ in
            CommandOutcome(exitCode: 72, outputTail: "xcrun: error: unable to find utility \"xcodebuild\", not a developer tool or in PATH\n")
        }
        do {
            _ = try runner(missing).runPlainBaseline(progress: .silent)
            Issue.record("expected runner_unavailable")
        } catch let error as SlopguardError {
            #expect(error.code == "runner_unavailable")
            #expect(error.message.contains("unable to find utility"))
        }
    }

    @Test("coverage: analyze's xcodebuild test arguments, read with xccov; missing data is nil")
    func coverage() throws {
        let commands = FakeCommandRunner { spec in
            if let index = spec.arguments.firstIndex(of: "-resultBundlePath") {
                try FileManager.default.createDirectory(atPath: spec.arguments[index + 1], withIntermediateDirectories: true)
            }
            return CommandOutcome(exitCode: 65)
        }
        let report = try JSONDecoder().decode(XccovReport.self, from: Data(xccovJSON.utf8))
        let result = try runner(commands, readCoverage: { _ in report }).runCoverageBaseline(progress: .silent)
        #expect(result.exitCode == 65)
        guard case .methods(let index)? = result.coverage else {
            Issue.record("expected method coverage")
            return
        }
        let arguments = try #require(commands.calls.first?.spec.arguments)
        let bundle = try #require(arguments.firstIndex(of: "-resultBundlePath").map { arguments[$0 + 1] })
        #expect(arguments == XcodebuildRunner.testArguments(
            scheme: "App", workspace: "/p/App.xcworkspace", destination: "platform=iOS Simulator,name=iPhone 16",
            resultBundlePath: bundle, onlyTesting: ["AppTests/LoginTests"]))
        #expect(arguments.contains("YES"))
        let coverage = BaselineCoverage.methods(index)
        #expect(coverage.isUncovered(absolutePath: "/p/Sources/Store.swift", line: 4, methodLines: 3...6))
        #expect(!coverage.isUncovered(absolutePath: "/p/Sources/Store.swift", line: 11, methodLines: 10...12))
        #expect(!coverage.isUncovered(absolutePath: "/p/Sources/Store.swift", line: 1, methodLines: nil))

        let unreadable = try runner(commands).runCoverageBaseline(progress: .silent)
        #expect(unreadable.coverage == nil)
    }
}

@Suite("line coverage index")
struct LineCoverageIndexTests {

    @Test("lcov DA records give per-line counts; ranges give percentages; unknown is nil")
    func parse() throws {
        try withTemporaryDirectory { root in
            let a = try write("a\n", to: "A.swift", in: root)
            let b = try write("b\n", to: "B.swift", in: root)
            let lcov = """
            SF:\(a.path)
            DA:1,5
            DA:2,0
            DA:4,1,checksum
            end_of_record
            SF:\(b.path)
            DA:7,0
            end_of_record
            SF:\(a.path)
            DA:2,3
            end_of_record
            """
            let index = LineCoverageIndex(lcov: lcov)
            #expect(index.fileCount == 2)
            #expect(index.count(absolutePath: a.path, line: 1) == 5)
            #expect(index.count(absolutePath: a.path, line: 2) == 3)
            #expect(index.count(absolutePath: a.path, line: 3) == nil)
            #expect(index.methodCoverage(absolutePath: b.path, line: 7, endLine: 7) == 0)
            #expect(index.methodCoverage(absolutePath: a.path, line: 1, endLine: 4) == 100)
            #expect(index.methodCoverage(absolutePath: a.path, line: 3, endLine: 3) == nil)
            #expect(index.methodCoverage(absolutePath: root.appendingPathComponent("C.swift").path, line: 1, endLine: 1) == nil)
            #expect(index.fileCoverage(absolutePath: b.path) == 0)
            let lines = BaselineCoverage.lines(index)
            #expect(lines.isUncovered(absolutePath: b.path, line: 7, methodLines: nil))
            #expect(!lines.isUncovered(absolutePath: a.path, line: 1, methodLines: nil))
            #expect(!lines.isUncovered(absolutePath: a.path, line: 3, methodLines: nil))
        }
    }

    @Test("paths match after resolving symlinks")
    func symlinks() throws {
        try withTemporaryDirectory { root in
            let real = try write("x\n", to: "real/F.swift", in: root)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
            let index = LineCoverageIndex(lcov: "SF:\(link.path)/F.swift\nDA:1,0\nend_of_record\n")
            #expect(index.count(absolutePath: real.path, line: 1) == 0)
        }
    }
}
