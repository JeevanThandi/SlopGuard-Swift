import Foundation
import SlopguardCore

/// Drives `xcrun xcodebuild` to *produce* an `.xcresult` bundle with code coverage.
///
/// Coverage is not a user input to slopguard; it's an artifact slopguard generates
/// as part of its own investigation. This runner owns that step: discover a scheme,
/// invoke `xcodebuild test -enableCodeCoverage YES`, and hand back the result-bundle
/// URL for `XccovRunner` to read.
///
/// All subprocess work runs on a detached task so callers can `await` from any actor
/// context without dragging non-`Sendable` `Process` / `Pipe` references across
/// isolation. Pure I/O — no formula logic.
public struct XcodebuildRunner: Sendable {

    public init() {}

    /// Build & test under `xcodebuild` and return the URL of the produced
    /// `.xcresult` bundle. Caller owns that bundle on disk.
    ///
    /// - Parameters:
    ///   - scheme:           Explicit scheme. When `nil`, discover via
    ///                       `xcodebuild -list -json`.
    ///   - destination:      e.g. `"platform=macOS"`.
    ///   - projectDirectory: Working directory for `xcodebuild` (defaults to cwd).
    ///   - resultBundleURL:  Where to write the `.xcresult` bundle.
    /// - Returns: `(resultBundleURL, testsPassed)`. Build failures throw;
    ///   test failures don't — partial coverage is still useful.
    public func runTests(
        scheme: String? = nil,
        destination: String = "platform=macOS",
        projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        resultBundleURL: URL,
        progress: ProgressReporter = .silent
    ) async throws -> (resultBundle: URL, testsPassed: Bool) {
        let projectPath = projectDirectory.standardizedFileURL.path
        let bundlePath = resultBundleURL.standardizedFileURL.path

        let resolvedScheme: String
        if let scheme {
            resolvedScheme = scheme
        } else {
            progress.phase("discovering xcodebuild scheme in \(projectPath)")
            resolvedScheme = try await Self.detached {
                try Self.discoverDefaultScheme(projectDirectory: projectPath)
            }
        }

        progress.phase("running xcodebuild test (scheme '\(resolvedScheme)', destination '\(destination)') — this can take several minutes")
        let testsPassed = try await Self.detached {
            try Self.runXcodebuildTest(
                scheme: resolvedScheme,
                destination: destination,
                projectDirectory: projectPath,
                resultBundlePath: bundlePath,
                progress: progress
            )
        }

        return (resultBundle: resultBundleURL, testsPassed: testsPassed)
    }

    /// Run `xcodebuild -list -json` and pick the right scheme to test.
    ///
    /// SwiftPM packages expose a `<name>-Package` umbrella scheme that runs
    /// every test target. Prefer that. Otherwise fall back to a single
    /// available scheme; bail out when there's ambiguity rather than guess.
    static func discoverDefaultScheme(projectDirectory: String) throws -> String {
        let data = try runXcodebuildList(projectDirectory: projectDirectory)
        let schemes = try decodeSchemes(data: data)
        guard !schemes.isEmpty else {
            throw SlopguardError.xcodebuildSchemeNotFound(projectDirectory: projectDirectory)
        }
        if let umbrella = schemes.first(where: { $0.hasSuffix("-Package") }) {
            return umbrella
        }
        if schemes.count == 1 {
            return schemes[0]
        }
        throw SlopguardError.xcodebuildSchemeAmbiguous(schemes: schemes)
    }

    static func runXcodebuildList(projectDirectory: String) throws -> Data {
        try ProcessRunner.runOrThrow(
            executable: "/usr/bin/xcrun",
            arguments: ["xcodebuild", "-list", "-json"],
            cwd: projectDirectory,
            launchError: { SlopguardError.xcodebuildUnavailable(reason: "Could not launch xcrun: \($0)") },
            failureError: { SlopguardError.xcodebuildBuildFailed(exitCode: $0, stderr: $1) }
        )
    }

    static func decodeSchemes(data: Data) throws -> [String] {
        // `xcodebuild -list -json` returns either { "workspace": {schemes: []} }
        // or { "project": {schemes: []} } depending on the project type. SwiftPM
        // packages report under `workspace`. We accept either.
        struct Listing: Decodable {
            struct Container: Decodable { let schemes: [String]? }
            let workspace: Container?
            let project: Container?
        }
        let decoded: Listing
        do {
            decoded = try JSONDecoder().decode(Listing.self, from: data)
        } catch {
            throw SlopguardError.xcodebuildUnavailable(
                reason: "Could not decode `xcodebuild -list -json` output: \(error)"
            )
        }
        return decoded.workspace?.schemes ?? decoded.project?.schemes ?? []
    }

    /// Invoke `xcodebuild test` and stream its output to `/dev/null`. We only
    /// care about the produced `.xcresult` and the exit code.
    ///
    /// A non-zero exit with the bundle present means tests failed but
    /// coverage was still emitted — keep going. A non-zero exit with no
    /// bundle means the build itself broke — abort.
    static func runXcodebuildTest(
        scheme: String,
        destination: String,
        projectDirectory: String,
        resultBundlePath: String,
        progress: ProgressReporter = .silent
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test",
            "-scheme", scheme,
            "-destination", destination,
            "-resultBundlePath", resultBundlePath,
            "-enableCodeCoverage", "YES"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDirectory)

        // Drain xcodebuild's stdout/stderr — discard by default, stream to the
        // progress reporter under `--verbose`. Either way the pipe must be
        // drained or the subprocess will block once its kernel buffer fills.
        let sink = Pipe()
        process.standardOutput = sink
        process.standardError = sink

        try launch(process)
        if progress.isVerbose {
            sink.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { progress.raw(chunk) }
            }
        } else {
            sink.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
        }
        process.waitUntilExit()
        sink.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus == 0 {
            return true
        }
        if FileManager.default.fileExists(atPath: resultBundlePath) {
            return false
        }
        throw SlopguardError.xcodebuildBuildFailed(
            exitCode: process.terminationStatus,
            stderr: "no .xcresult bundle was produced"
        )
    }

    private static func launch(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw SlopguardError.xcodebuildUnavailable(reason: "Could not launch xcrun: \(error)")
        }
    }

    /// Hop subprocess work to a detached task so non-`Sendable` `Process`
    /// values never cross actor isolation. Mirrors the pattern in `XccovRunner`.
    private static func detached<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
