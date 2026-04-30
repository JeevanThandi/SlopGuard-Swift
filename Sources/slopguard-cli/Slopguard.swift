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
        abstract: "Agentic-first CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS.",
        discussion: """
            slopguard-swift finds complex, undertested Swift code by combining cyclomatic \
            complexity (parsed via SwiftSyntax) with Xcode coverage. Its primary \
            interface is the MCP server (`slopguard-swift serve`); the CLI is a thin wrapper \
            for CI use and quick one-off scans.

            Formula:  CRAP(m) = comp² × (1 − cov/100)³ + comp
            Default crappy threshold: 30.
            """,
        version: SlopguardVersion.version,
        subcommands: [
            AnalyzeCommand.self,
            ServeCommand.self,
            VersionCommand.self
        ],
        defaultSubcommand: AnalyzeCommand.self
    )

    public init() {}
}
