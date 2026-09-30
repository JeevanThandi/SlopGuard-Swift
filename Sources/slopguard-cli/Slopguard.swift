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

            `mutate` checks that the tests verify the code, not only run it: it changes \
            the source one small step at a time (a mutant), runs the tests against each \
            mutant, and lists the mutants every test still passes with.
            """,
        version: SlopguardVersion.version,
        subcommands: [
            AnalyzeCommand.self,
            MutateCommand.self,
            VersionCommand.self
        ],
        defaultSubcommand: AnalyzeCommand.self
    )

    public init() {}
}
