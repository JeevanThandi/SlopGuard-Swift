import Foundation
import ArgumentParser
import SlopguardCore
import SlopguardCoverage

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze a directory or file and print a CRAP report.",
        discussion: """
            slopguard-swift drives `xcodebuild test -enableCodeCoverage YES` itself to gather \
            line coverage. Coverage is an artifact of the analysis, not an input.

            Examples:
              slopguard-swift analyze --path Sources --threshold 30 --json
              slopguard-swift analyze --path Sources --scheme MyApp-Package --destination 'platform=iOS Simulator,name=iPhone 16'
              slopguard-swift analyze --path . --workspace MyApp.xcworkspace --scheme MyApp # CocoaPods-style workspace
              slopguard-swift analyze --path . --fail-over 50      # fail CI when any method's CRAP > 50
              slopguard-swift analyze --path Sources --no-coverage # skip the test build (complexity-only)
            """
    )

    @Option(name: [.short, .long], help: "Directory of Swift sources, or a single .swift file. Defaults to the current directory.")
    var path: String = "."

    @Option(name: [.short, .long], help: "CRAP threshold above which a method/class is considered crappy.")
    var threshold: Double = CRAP.defaultThreshold

    @Option(name: .long, help: "xcodebuild scheme to test for coverage. Auto-discovered when omitted.")
    var scheme: String?

    @Option(name: .long, help: "Path to an .xcworkspace passed as -workspace to xcodebuild. Use when the project directory holds multiple containers (e.g. CocoaPods) and xcodebuild picks the wrong one, causing build errors.")
    var workspace: String?

    @Option(name: .long, help: "xcodebuild destination string. Defaults to platform=macOS.")
    var destination: String = "platform=macOS"

    @Option(name: .long, help: "Project directory passed as cwd to xcodebuild. Defaults to the current directory.")
    var projectDir: String?

    @Flag(name: .long, help: "Skip the xcodebuild step and report complexity only (every method shows 0% coverage).")
    var noCoverage: Bool = false

    @Option(name: .long, parsing: .upToNextOption, help: "Glob(s) of files to include. Repeat or pass space-separated.")
    var include: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Extra glob(s) of files / directories to exclude. Combined with the built-in defaults (.build, Pods, Carthage, Generated, *Tests, *Spec, etc.) — use --no-default-excludes to start clean.")
    var exclude: [String] = []

    @Flag(name: .long, help: "Skip the built-in default excludes. Useful when you want to analyze test code itself, or take complete manual control of the exclude list.")
    var noDefaultExcludes: Bool = false

    @Flag(name: .long, help: "Emit JSON to stdout (default is pretty text).")
    var json: Bool = false

    @Option(name: .long, help: "Exit with code 2 if any method's CRAP exceeds this value. Useful in CI.")
    var failOver: Double?

    @Flag(name: [.short, .long], help: "Stream xcodebuild output and other subprocess chatter to stderr. Use when you suspect xcodebuild itself is misbehaving.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Suppress all progress chatter on stderr. Phase markers and subprocess output are silenced. JSON / pretty output on stdout is unaffected.")
    var quiet: Bool = false

    /// Hidden escape hatch — used by tests / CI fixtures that already have an
    /// `.xcresult`. End users should let slopguard generate one itself.
    @Option(name: .customLong("xcresult"), help: .hidden)
    var xcresult: String?

    mutating func run() async throws {
        let pipeline = AnalysisPipeline()
        let sourceURL = resolvePath(path)
        let baseExcludes = noDefaultExcludes ? [] : AnalysisOptions.defaultExcludeGlobs
        let options = AnalysisOptions(
            includeGlobs: include,
            excludeGlobs: baseExcludes + exclude,
            followSymlinks: false
        )
        let coverage = resolveCoverageSource()

        let progress = resolveProgressReporter()
        let report: CrapReport
        do {
            report = try await pipeline.run(
                sourceURL: sourceURL,
                coverage: coverage,
                threshold: threshold,
                options: options,
                progress: progress
            )
        } catch let error as SlopguardError {
            try emitError(.init(error))
            throw ExitCode(1)
        } catch {
            try emitError(.init(code: "internal_error", message: "\(error)"))
            throw ExitCode(1)
        }

        if json {
            try emitJSON(report)
        } else {
            emitPretty(report)
        }

        if let failOver, !report.methods.isEmpty, report.methods[0].crap > failOver {
            FileHandle.standardError.write(
                Data("slopguard-swift: CRAP \(report.methods[0].crap) exceeds --fail-over \(failOver)\n".utf8)
            )
            throw ExitCode(2)
        }
    }

    // MARK: - Output (thin I/O around CrapReportFormatter)

    private func emitJSON(_ report: CrapReport) throws {
        let data = try CrapReportFormatter.json(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private func emitPretty(_ report: CrapReport) {
        FileHandle.standardOutput.write(Data(CrapReportFormatter.pretty(report).utf8))
    }

    private func emitError(_ env: SlopguardErrorEnvelope) throws {
        if json {
            let data = try CrapReportFormatter.errorJSON(env)
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data([0x0A]))
        } else {
            FileHandle.standardError.write(Data((CrapReportFormatter.errorText(env) + "\n").utf8))
        }
    }

    /// `--quiet` wins over `--verbose` if both are passed; if neither is
    /// passed we emit the default phase markers. Internal (not private) so
    /// the CLI tests can assert the flag → verbosity mapping.
    func resolveProgressReporter() -> ProgressReporter {
        if quiet { return .silent }
        return .stderr(verbosity: verbose ? .verbose : .normal)
    }

    private func resolveCoverageSource() -> AnalysisPipeline.CoverageSource {
        .fromFlags(
            noCoverage: noCoverage,
            xcresult: xcresult,
            scheme: scheme,
            workspace: workspace,
            destination: destination,
            projectDir: projectDir
        )
    }
}

private func resolvePath(_ raw: String) -> URL {
    let expanded = (raw as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
}
