import Foundation

/// Abstraction over coverage data, so that `SlopguardCore` does not depend on the
/// coverage subsystem (which transitively depends on `xcrun`). `SlopguardCoverage`
/// supplies a concrete conformance via `CoverageIndex`.
public protocol CoverageProvider: Sendable {
    /// Method-level coverage as a percentage in `[0, 100]`, or `nil` if unknown.
    func methodCoverage(absolutePath: String, line: Int, endLine: Int) -> Double?

    /// File-level coverage as a percentage in `[0, 100]`, or `nil` if unknown.
    func fileCoverage(absolutePath: String) -> Double?
}
