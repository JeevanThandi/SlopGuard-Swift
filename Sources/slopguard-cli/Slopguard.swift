import Foundation
import ArgumentParser
import SlopguardCore

/// Top-level CLI entry point. The `@main` lives in `Sources/slopguard-cli-bin`
/// so the CLI lives in a library target — that way tests can `@testable import
/// SlopguardCLI` without xcodebuild rejecting cross-module imports of an
/// executable target.
public struct Slopguard: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "slopguard-swift",
        abstract: "CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS.",
        discussion: """
            slopguard-swift finds complex, undertested Swift code by combining cyclomatic \
            and cognitive complexity (parsed via SwiftSyntax) with Xcode coverage. Use \
            `analyze` for one-shot scans and pipe `--json` into `jq` for downstream tooling.

            Formula:  wCRAP(m) = (cyc × cog) × (1 − cov/100)³ + sqrt(cyc × cog)
            Default crappy threshold: 30.
            """,
        version: SlopguardVersion.version,
        subcommands: [
            AnalyzeCommand.self,
            VersionCommand.self
        ],
        defaultSubcommand: AnalyzeCommand.self
    )

    public init() {}
}
