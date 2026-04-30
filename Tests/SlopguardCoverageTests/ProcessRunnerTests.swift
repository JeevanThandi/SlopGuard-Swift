import XCTest
@testable import SlopguardCoverage
import SlopguardCore

/// `ProcessRunner` is the shared subprocess helper underneath both runners.
/// We test it against tiny system binaries (`/bin/echo`, `/usr/bin/false`,
/// `/bin/sh`) so the assertions are fast and hermetic, and so they run
/// happily under both `swift test` and `xcodebuild test` (no nested
/// xcodebuild → no `/tmp/action.xccovreport` clobbering).
final class ProcessRunnerTests: XCTestCase {

    private let unexpectedLaunchError: (Error) -> SlopguardError = {
        SlopguardError.xccovUnavailable(reason: "unexpected launch failure: \($0)")
    }
    private let unexpectedExitError: (Int32, String) -> SlopguardError = {
        SlopguardError.xccovInvocationFailed(exitCode: $0, stderr: $1)
    }

    func testRunCapturesStdoutAndZeroExit() throws {
        let outcome = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["hello", "world"],
            launchError: unexpectedLaunchError
        )
        let output = String(data: outcome.output, encoding: .utf8)
        XCTAssertEqual(output, "hello world\n")
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.stderr.isEmpty)
    }

    func testRunReturnsNonZeroExitWithoutThrowing() throws {
        let outcome = try ProcessRunner.run(
            executable: "/usr/bin/false",
            arguments: [],
            launchError: unexpectedLaunchError
        )
        XCTAssertNotEqual(outcome.exitCode, 0)
    }

    /// `cwd` is honored — verified by spawning a shell that prints `pwd`.
    func testRunHonorsWorkingDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("processrunner-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outcome = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "pwd"],
            cwd: tmp.path,
            launchError: unexpectedLaunchError
        )
        let pwd = String(data: outcome.output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // macOS resolves /var to /private/var; either form is acceptable.
        XCTAssertTrue(
            pwd == tmp.path || pwd == "/private\(tmp.path)",
            "expected pwd=\(tmp.path), got \(pwd ?? "nil")"
        )
    }

    func testRunTranslatesLaunchFailureToTypedError() {
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: "/no/such/binary",
                arguments: [],
                launchError: { SlopguardError.xccovUnavailable(reason: "launch: \($0)") }
            )
        ) { err in
            guard case SlopguardError.xccovUnavailable = err else {
                XCTFail("expected xccovUnavailable, got \(err)")
                return
            }
        }
    }

    // MARK: - runOrThrow

    func testRunOrThrowReturnsOutputOnSuccess() throws {
        let data = try ProcessRunner.runOrThrow(
            executable: "/bin/echo",
            arguments: ["ok"],
            launchError: unexpectedLaunchError,
            failureError: unexpectedExitError
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok\n")
    }

    /// Non-zero exit → `runOrThrow` raises the caller's typed error and
    /// hands it both the exit code and the captured stderr text.
    func testRunOrThrowMapsNonZeroExitToTypedError() {
        var capturedExit: Int32?
        var capturedStderr: String?
        XCTAssertThrowsError(
            try ProcessRunner.runOrThrow(
                executable: "/bin/sh",
                arguments: ["-c", "echo boom 1>&2; exit 7"],
                launchError: unexpectedLaunchError,
                failureError: { code, stderr in
                    capturedExit = code
                    capturedStderr = stderr
                    return SlopguardError.xccovInvocationFailed(exitCode: code, stderr: stderr)
                }
            )
        ) { err in
            guard case SlopguardError.xccovInvocationFailed(let code, let stderr) = err else {
                XCTFail("expected xccovInvocationFailed, got \(err)")
                return
            }
            XCTAssertEqual(code, 7)
            XCTAssertTrue(stderr.contains("boom"))
        }
        XCTAssertEqual(capturedExit, 7)
        XCTAssertTrue(capturedStderr?.contains("boom") ?? false)
    }
}
