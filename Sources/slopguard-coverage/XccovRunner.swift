import Foundation
import SlopguardCore

/// Anything that can produce an `XccovReport` for a given `.xcresult` URL.
/// Exists so `AnalysisPipeline` can be unit-tested with a stub without
/// having to spawn xccov for real.
public protocol XccovReporting: Sendable {
    func runReport(xcresultURL: URL) async throws -> XccovReport
}

/// Invokes `xcrun xccov view --report --json <path>` against an `.xcresult` bundle and
/// decodes the output into an `XccovReport`. Pure I/O — no formula logic lives here.
public struct XccovRunner: XccovReporting, Sendable {

    public init() {}

    /// Run xccov and return the decoded report. The actual subprocess work is done
    /// in a detached task so callers can `await` from any actor context without
    /// dragging non-`Sendable` `Process` / `Pipe` references across isolation.
    public func runReport(xcresultURL: URL) async throws -> XccovReport {
        let path = xcresultURL.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SlopguardError.fileNotFound(path: path)
        }
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.runXccov(xcresultPath: path)
        }.value
        return try Self.decode(data: data)
    }

    /// Spawn `xcrun xccov view --report --json <path>` and return its stdout.
    /// Throws a typed `SlopguardError` for launch / non-zero-exit failures so the
    /// caller doesn't have to inspect `Process.terminationStatus` itself.
    static func runXccov(xcresultPath: String) throws -> Data {
        try ProcessRunner.runOrThrow(
            executable: "/usr/bin/xcrun",
            arguments: ["xccov", "view", "--report", "--json", xcresultPath],
            launchError: { SlopguardError.xccovUnavailable(reason: "Could not launch xcrun: \($0)") },
            failureError: Self.mapFailure(exitCode:stderr:)
        )
    }

    /// Map a non-zero xccov exit into the right typed error.
    ///
    /// xccov collapses "tests didn't run" and "test plan disabled coverage"
    /// into the same stderr string ("No coverage data in result bundle"). We
    /// catch that signature and re-raise as `coverageDataMissing` so the
    /// pipeline can probe the bundle and decide which case actually applies
    /// — generic `xccovInvocationFailed` would force callers to grep stderr.
    static func mapFailure(exitCode: Int32, stderr: String) -> SlopguardError {
        if stderr.localizedCaseInsensitiveContains("no coverage data") {
            return .coverageDataMissing(reason: .coverageNotGathered(testCount: nil))
        }
        return .xccovInvocationFailed(exitCode: exitCode, stderr: stderr)
    }

    static func decode(data: Data) throws -> XccovReport {
        do {
            return try JSONDecoder().decode(XccovReport.self, from: data)
        } catch {
            throw SlopguardError.xccovDecodeFailed(underlying: "\(error)")
        }
    }
}
