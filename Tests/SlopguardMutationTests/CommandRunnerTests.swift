import Foundation
import Darwin
import Testing
@testable import SlopguardCore
@testable import SlopguardMutation

private func shell(_ script: String, in directory: URL, environment: [String: String] = [:]) -> CommandSpec {
    CommandSpec(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: directory.path, environment: environment)
}

/// Wait up to `seconds` for `condition`, polling.
private func eventually(within seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

private func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

@Suite("process-group command runner")
struct CommandRunnerTests {

    @Test("exit code, merged output tail, working directory and environment")
    func basics() throws {
        try withTemporaryDirectory { dir in
            let outcome = try ProcessGroupCommandRunner().run(
                shell("echo out; echo err 1>&2; pwd; echo \"CI=$CI\"; exit 3", in: dir, environment: ["CI": "1"]),
                timeout: nil,
                progress: .silent
            )
            #expect(outcome.exitCode == 3)
            #expect(!outcome.timedOut)
            #expect(outcome.outputTail.contains("out\n"))
            #expect(outcome.outputTail.contains("err\n"))
            #expect(outcome.outputTail.contains(dir.path))
            #expect(outcome.outputTail.contains("CI=1"))
            #expect(outcome.stdout.isEmpty)
        }
    }

    @Test("captureStdout keeps stdout apart from stderr")
    func capture() throws {
        try withTemporaryDirectory { dir in
            let outcome = try ProcessGroupCommandRunner().run(
                shell("echo data; echo noise 1>&2", in: dir), timeout: nil, captureStdout: true, progress: .silent
            )
            #expect(outcome.exitCode == 0)
            #expect(String(decoding: outcome.stdout, as: UTF8.self) == "data\n")
            #expect(outcome.outputTail.contains("noise"))
        }
    }

    @Test("stdin is /dev/null, so a command that reads it does not hang")
    func stdinIsNull() throws {
        try withTemporaryDirectory { dir in
            let outcome = try ProcessGroupCommandRunner().run(shell("cat; echo done", in: dir), timeout: 60, progress: .silent)
            #expect(outcome.outputTail == "done\n")
            #expect(!outcome.timedOut)
        }
    }

    @Test("--verbose streams the output through the progress reporter")
    func streaming() throws {
        try withTemporaryDirectory { dir in
            let sink = ProgressSink()
            _ = try ProcessGroupCommandRunner().run(shell("echo streamed", in: dir), timeout: nil, progress: sink.reporter(.verbose))
            #expect(String(decoding: sink.raw, as: UTF8.self) == "streamed\n")
        }
    }

    @Test("a timeout kills the whole process group, not just the direct child")
    func timeoutKillsGroup() throws {
        try withTemporaryDirectory { dir in
            let pidFile = dir.appendingPathComponent("child.pid")
            let started = Date()
            let outcome = try ProcessGroupCommandRunner().run(
                shell("sleep 300 & echo $! > '\(pidFile.path)'; sleep 300", in: dir),
                timeout: 1,
                progress: .silent
            )
            #expect(outcome.timedOut)
            #expect(outcome.exitCode == nil)
            #expect(Date().timeIntervalSince(started) < 60)
            let text = try read(pidFile).trimmingCharacters(in: .whitespacesAndNewlines)
            let grandchild = try #require(pid_t(text))
            #expect(eventually(within: 10) { isGone(grandchild) }, "background sleep \(grandchild) survived the timeout")
        }
    }

    @Test("a command that cannot be launched is runner_unavailable")
    func launchFailures() throws {
        try withTemporaryDirectory { dir in
            let runner = ProcessGroupCommandRunner()
            for executable in ["/no/such/binary", "slopguard-no-such-command-on-path"] {
                do {
                    _ = try runner.run(CommandSpec(executable: executable, arguments: [], workingDirectory: dir.path),
                                       timeout: nil, progress: .silent)
                    Issue.record("expected runner_unavailable for \(executable)")
                } catch let error as SlopguardError {
                    #expect(error.code == "runner_unavailable")
                }
            }
            #expect(throws: SlopguardError.self) {
                _ = try runner.run(shell("true", in: dir.appendingPathComponent("missing")), timeout: nil, progress: .silent)
            }
        }
    }

    @Test("stop() kills the running command and refuses new ones")
    func stop() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = ProcessGroupCommandRunner()
        let started = Date()
        let task = Task.detached {
            try runner.run(shell("sleep 300", in: dir), timeout: nil, progress: .silent)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        runner.stop()
        let outcome = try await task.value
        #expect(outcome.exitCode == nil)
        #expect(Date().timeIntervalSince(started) < 60)
        #expect(throws: SlopguardError.self) {
            _ = try runner.run(shell("true", in: dir), timeout: nil, progress: .silent)
        }
    }

    @Test("wait statuses decode to exit codes; signals decode to nil")
    func waitStatus() {
        #expect(ProcessGroupCommandRunner.exitCode(fromWaitStatus: 0) == 0)
        #expect(ProcessGroupCommandRunner.exitCode(fromWaitStatus: 3 << 8) == 3)
        #expect(ProcessGroupCommandRunner.exitCode(fromWaitStatus: SIGKILL) == nil)
    }

    @Test("the output tail keeps the newest chunks within the limit")
    func outputTail() {
        var tail = OutputTail(limit: 10)
        for chunk in ["aaaa", "bbbb", "cccc", "dddd"] { tail.append(Data(chunk.utf8)) }
        #expect(tail.text == "ccccdddd")
        var big = OutputTail(limit: 4)
        big.append(Data("0123456789".utf8))
        #expect(big.text == "0123456789")
    }
}
