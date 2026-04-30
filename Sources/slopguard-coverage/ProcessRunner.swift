import Foundation
import SlopguardCore

/// Tiny shared subprocess helper. Both `XccovRunner` and `XcodebuildRunner`
/// need the same plumbing (spawn → capture stdout/stderr → check exit code →
/// translate failures into typed `SlopguardError`s), so we factor it out
/// here. Doing this also means the wrappers themselves become one-liners
/// at cc=1, well below the threshold — and `ProcessRunner` is testable
/// against fast, hermetic binaries like `/bin/echo` and `/usr/bin/false`,
/// which work under both `swift test` and `xcodebuild test`.
enum ProcessRunner {

    /// Outcome of a subprocess run. `exitCode == 0` means success; the
    /// caller decides whether non-zero is fatal. Both pipes are drained
    /// regardless of exit code so callers can produce useful error text.
    struct Outcome: Sendable {
        let output: Data
        let stderr: Data
        let exitCode: Int32
    }

    /// Run `executable` with `arguments` (and an optional working directory),
    /// capture both pipes, and return the `Outcome`. Launch failures are
    /// translated into `SlopguardError` via `launchError`; non-zero exits
    /// are *not* treated as errors here — see `runOrThrow` for that.
    static func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        launchError: (Error) -> SlopguardError
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw launchError(error)
        }

        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()

        return Outcome(output: outData, stderr: errData, exitCode: process.terminationStatus)
    }

    /// Same as `run`, but also throws when the process exits non-zero. The
    /// caller supplies the typed error to construct from `(exitCode, stderr)`.
    static func runOrThrow(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        launchError: (Error) -> SlopguardError,
        failureError: (Int32, String) -> SlopguardError
    ) throws -> Data {
        let outcome = try run(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            launchError: launchError
        )
        guard outcome.exitCode == 0 else {
            let stderrText = String(data: outcome.stderr, encoding: .utf8) ?? "<non-utf8 stderr>"
            throw failureError(outcome.exitCode, stderrText)
        }
        return outcome.output
    }
}
