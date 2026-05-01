import Foundation

/// Why a coverage probe came back empty. These two cases look identical to
/// `xccov` ("No coverage data in result bundle") but mean very different things
/// to the user — `noTestsDetected` is an honest 0%, while `coverageNotGathered`
/// is a configuration problem masquerading as 0%.
public enum CoverageMissingReason: Sendable, Equatable {
    /// xcodebuild produced an `.xcresult` but the bundle has zero test runs.
    /// Treating coverage as 0% is *correct* — there genuinely are no tests.
    case noTestsDetected

    /// Tests executed but the bundle has no coverage data. Almost always a
    /// test plan with "Gather code coverage" off, or `-enableCodeCoverage YES`
    /// being overridden by a scheme/test-plan setting. Reporting 0% is
    /// misleading; the report carries a stronger note for this case.
    /// `testCount == nil` means the probe couldn't determine — we still
    /// fall through with this reason rather than misreport "no tests".
    case coverageNotGathered(testCount: Int?)
}

/// Machine-readable error type. Every variant carries a stable string `code` so that
/// CLI `--json` output stays consumable by agents without pattern-matching on
/// free-text messages.
public enum SlopguardError: Error, Sendable, CustomStringConvertible {
    case fileNotFound(path: String)
    case notADirectory(path: String)
    case unreadableFile(path: String, underlying: String)
    case parseFailed(path: String, underlying: String)
    case xccovUnavailable(reason: String)
    case xccovInvocationFailed(exitCode: Int32, stderr: String)
    case xccovDecodeFailed(underlying: String)
    /// Raised by `XccovRunner` when xccov reports the bundle has no coverage
    /// data. Carries an unresolved reason — the pipeline probes the xcresult
    /// to disambiguate "no tests" vs "tests-but-coverage-suppressed" before
    /// deciding what note to attach to the report.
    case coverageDataMissing(reason: CoverageMissingReason)
    case xcodebuildUnavailable(reason: String)
    case xcodebuildSchemeAmbiguous(schemes: [String])
    case xcodebuildSchemeNotFound(projectDirectory: String)
    case xcodebuildBuildFailed(exitCode: Int32, stderr: String)
    case invalidArgument(name: String, reason: String)
    case unsupported(reason: String)

    public var code: String { info.code }
    public var message: String { info.message }
    public var description: String { "[\(code)] \(message)" }

    /// Pairs the stable code with the rendered message so we walk the
    /// case list once instead of twice. Kept private — callers ask for
    /// `code` / `message` / `description` and don't need to know how
    /// they're produced.
    private var info: (code: String, message: String) {
        switch self {
        case .fileNotFound(let path):
            return ("file_not_found", "File not found: \(path)")
        case .notADirectory(let path):
            return ("not_a_directory", "Not a directory: \(path)")
        case .unreadableFile(let path, let underlying):
            return ("unreadable_file", "Could not read \(path): \(underlying)")
        case .parseFailed(let path, let underlying):
            return ("parse_failed", "Failed to parse \(path): \(underlying)")
        case .xccovUnavailable(let reason):
            return ("xccov_unavailable", "xccov is unavailable: \(reason)")
        case .xccovInvocationFailed(let exitCode, let stderr):
            return ("xccov_invocation_failed", "xccov exited with code \(exitCode): \(stderr)")
        case .xccovDecodeFailed(let underlying):
            return ("xccov_decode_failed", "Failed to decode xccov output: \(underlying)")
        case .coverageDataMissing(let reason):
            switch reason {
            case .noTestsDetected:
                return ("coverage_data_missing", "No tests were detected in the xcresult bundle")
            case .coverageNotGathered(let count):
                let detail = count.map { "\($0) test(s) ran" } ?? "tests appear to have run"
                return (
                    "coverage_data_missing",
                    "\(detail) but no coverage data was gathered — check the test plan's 'Gather code coverage' setting"
                )
            }
        case .xcodebuildUnavailable(let reason):
            return ("xcodebuild_unavailable", "xcodebuild is unavailable: \(reason)")
        case .xcodebuildSchemeAmbiguous(let schemes):
            return (
                "xcodebuild_scheme_ambiguous",
                "Multiple test schemes found; pass --scheme to disambiguate. Schemes: \(schemes.joined(separator: ", "))"
            )
        case .xcodebuildSchemeNotFound(let projectDirectory):
            return (
                "xcodebuild_scheme_not_found",
                "No xcodebuild schemes were discovered under \(projectDirectory). Pass --scheme or run from a SwiftPM/Xcode project root."
            )
        case .xcodebuildBuildFailed(let exitCode, let stderr):
            return ("xcodebuild_build_failed", "xcodebuild failed before tests ran (exit \(exitCode)): \(stderr)")
        case .invalidArgument(let name, let reason):
            return ("invalid_argument", "Invalid argument '\(name)': \(reason)")
        case .unsupported(let reason):
            return ("unsupported", "Unsupported: \(reason)")
        }
    }
}

/// JSON-friendly envelope emitted on the CLI's `--json` error path.
public struct SlopguardErrorEnvelope: Sendable, Codable {
    public let code: String
    public let message: String

    public init(_ error: SlopguardError) {
        self.code = error.code
        self.message = error.message
    }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
