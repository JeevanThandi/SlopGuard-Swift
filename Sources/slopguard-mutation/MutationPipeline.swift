import Foundation
import Darwin
import SlopguardCore
import SlopguardCoverage

/// Orchestrates `mutate`: plan mutants → acquire the workspace guard → plain
/// baseline (the exact mutant command, unmutated) → coverage baseline →
/// one test run per mutant → report.
///
/// Mutants run one at a time, in report order, each written in place and
/// restored by the `WorkspaceGuard` — including on SIGINT / SIGTERM / SIGHUP.
public struct MutationPipeline: Sendable {

    /// Added to three times the plain baseline's wall time to form the
    /// default per-mutant timeout. Each Swift mutant run includes a compile.
    public static let timeoutGraceSeconds: Double = 60

    /// Everything `mutate` needs from the command line.
    public struct Options: Sendable {
        /// Directory or single `.swift` file to mutate.
        public var sourceURL: URL
        public var analysisOptions: AnalysisOptions
        public var operators: [MutationOperator]
        /// `nil` = choose with `RunnerSelection`.
        public var runner: MutationRunnerKind?
        /// `nil` = discover from `sourceURL`, like `analyze`.
        public var projectDirectory: URL?
        public var scheme: String?
        public var workspace: URL?
        /// `nil` = `platform=macOS`.
        public var destination: String?
        public var onlyTesting: [String]
        /// Classify mutants on unexecuted lines as `no_coverage`.
        public var coverage: Bool
        /// `nil` = computed from the plain baseline.
        public var timeoutSeconds: Double?
        public var dryRun: Bool

        public init(
            sourceURL: URL,
            analysisOptions: AnalysisOptions = .default,
            operators: [MutationOperator] = MutationOperator.allCases,
            runner: MutationRunnerKind? = nil,
            projectDirectory: URL? = nil,
            scheme: String? = nil,
            workspace: URL? = nil,
            destination: String? = nil,
            onlyTesting: [String] = [],
            coverage: Bool = true,
            timeoutSeconds: Double? = nil,
            dryRun: Bool = false
        ) {
            self.sourceURL = sourceURL
            self.analysisOptions = analysisOptions
            self.operators = operators
            self.runner = runner
            self.projectDirectory = projectDirectory
            self.scheme = scheme
            self.workspace = workspace
            self.destination = destination
            self.onlyTesting = onlyTesting
            self.coverage = coverage
            self.timeoutSeconds = timeoutSeconds
            self.dryRun = dryRun
        }
    }

    /// What a runner factory gets to build a runner from.
    public struct RunnerRequest: Sendable {
        public let kind: MutationRunnerKind
        public let projectDirectory: String
        public let scheme: String?
        public let workspace: String?
        public let destination: String
        public let onlyTesting: [String]
    }

    /// How the pipeline reacts to SIGINT / SIGTERM / SIGHUP. Injectable so
    /// tests can deliver a "signal" and observe the exit code without dying.
    public struct InterruptHandling: Sendable {
        /// Install a handler; returns the uninstaller.
        public var install: @Sendable (@escaping @Sendable (Int32) -> Void) -> @Sendable () -> Void
        /// End the process after the restore.
        public var exit: @Sendable (Int32) -> Void

        public init(
            install: @escaping @Sendable (@escaping @Sendable (Int32) -> Void) -> @Sendable () -> Void,
            exit: @escaping @Sendable (Int32) -> Void
        ) {
            self.install = install
            self.exit = exit
        }

        /// Real signal handling: restore, then exit 130 / 143 / 129.
        public static let live = InterruptHandling(
            install: { handler in SignalTrap.install(handler: handler) },
            exit: { code in Darwin.exit(code) }
        )
    }

    public var planner: MutationPlanner
    public var makeRunner: @Sendable (RunnerRequest, ProgressReporter) throws -> any MutationTestRunner
    /// Parent of the guard directories. Default: the OS temp dir.
    public var guardRoot: URL
    public var interrupts: InterruptHandling

    public init(
        planner: MutationPlanner = MutationPlanner(),
        makeRunner: @escaping @Sendable (RunnerRequest, ProgressReporter) throws -> any MutationTestRunner = MutationPipeline.liveRunner,
        guardRoot: URL = FileManager.default.temporaryDirectory,
        interrupts: InterruptHandling = .live
    ) {
        self.planner = planner
        self.makeRunner = makeRunner
        self.guardRoot = guardRoot
        self.interrupts = interrupts
    }

    /// The real runners: SwiftPM or xcodebuild, spawned in their own process groups.
    @Sendable public static func liveRunner(_ request: RunnerRequest, progress: ProgressReporter) throws -> any MutationTestRunner {
        switch request.kind {
        case .swiftTest:
            return SwiftTestMutationRunner(projectDirectory: request.projectDirectory, onlyTesting: request.onlyTesting)
        case .xcodebuild:
            return try XcodebuildMutationRunner.make(
                projectDirectory: request.projectDirectory,
                workspace: request.workspace,
                scheme: request.scheme,
                destination: request.destination,
                onlyTesting: request.onlyTesting,
                progress: progress
            )
        }
    }

    /// Run `mutate`. Test runs block, so the work happens on a detached task.
    public func run(_ options: Options, progress: ProgressReporter = .silent) async throws -> MutationReport {
        let pipeline = self
        return try await Task.detached(priority: .userInitiated) {
            try pipeline.runBlocking(options, progress: progress)
        }.value
    }

    // MARK: - Flow

    private struct Execution {
        let projectRoot: String
        let runner: String
        let timeoutSeconds: Double
        let coverageAvailable: Bool
        let notes: [String]
        let statuses: [MutantStatus]
    }

    func runBlocking(_ options: Options, progress: ProgressReporter) throws -> MutationReport {
        let sourcePath = options.sourceURL.standardizedFileURL.path
        progress.phase("walking \(sourcePath)")
        let files = try planner.planFiles(
            rootURL: options.sourceURL,
            options: options.analysisOptions,
            operators: options.operators
        )
        let planned = files.flatMap(\.mutants)
        progress.phase("generated \(planned.count) mutant(s) in \(files.count) file(s)")

        if options.dryRun || planned.allSatisfy(\.ignored) {
            let statuses = planned.map { $0.ignored ? MutantStatus.ignored : .pending }
            return buildReport(sourcePath: sourcePath, options: options, files: files, statuses: statuses, execution: nil)
        }
        let execution = try execute(files, options: options, progress: progress)
        let report = buildReport(
            sourcePath: sourcePath,
            options: options,
            files: files,
            statuses: execution.statuses,
            execution: execution
        )
        let s = report.summary
        progress.phase(
            "done — \(s.killed) killed, \(s.timedOut) timeout, \(s.survived) survived, " +
                "\(s.noCoverage) no_coverage, \(s.compileErrors) compile_error, \(s.ignored) ignored"
        )
        return report
    }

    private func execute(_ files: [PlannedFile], options: Options, progress: ProgressReporter) throws -> Execution {
        let projectRoot = (options.projectDirectory ?? ProjectRootDiscovery.discover(searchingFrom: options.sourceURL))
            .standardizedFileURL.path
        let kind: MutationRunnerKind
        if let explicit = options.runner {
            kind = explicit
        } else {
            progress.phase("detecting test runner in \(projectRoot)")
            kind = try RunnerSelection.detect(
                scheme: options.scheme,
                workspace: options.workspace?.path,
                projectDirectory: projectRoot
            )
        }
        let runner = try makeRunner(
            RunnerRequest(
                kind: kind,
                projectDirectory: projectRoot,
                scheme: options.scheme,
                workspace: options.workspace?.standardizedFileURL.path,
                destination: options.destination ?? "platform=macOS",
                onlyTesting: options.onlyTesting
            ),
            progress
        )

        let workspaceGuard = try WorkspaceGuard.acquire(projectRoot: projectRoot, temporaryRoot: guardRoot)
        let interrupts = self.interrupts
        let uninstall = interrupts.install { signal in
            runner.stop()
            var restored: String?
            do {
                restored = try workspaceGuard.restore()
                try workspaceGuard.release()
            } catch {
                progress.phase("\(error)")
            }
            progress.phase(restored.map { "interrupted — restored \($0)" } ?? "interrupted")
            interrupts.exit(SignalTrap.exitCode(for: signal))
        }

        let outcome = Result {
            try runAll(files, options: options, runner: runner, workspaceGuard: workspaceGuard,
                       projectRoot: projectRoot, progress: progress)
        }
        uninstall()
        try workspaceGuard.release()
        return try outcome.get()
    }

    private func runAll(
        _ files: [PlannedFile],
        options: Options,
        runner: any MutationTestRunner,
        workspaceGuard: WorkspaceGuard,
        projectRoot: String,
        progress: ProgressReporter
    ) throws -> Execution {
        var notes = workspaceGuard.notes

        progress.phase("running baseline tests (\(runner.name)) in \(projectRoot)")
        let baselineSeconds = try runner.runPlainBaseline(progress: progress)
        let timeout = options.timeoutSeconds ?? (baselineSeconds * 3).rounded(.up) + Self.timeoutGraceSeconds
        progress.phase(
            "baseline passed in \(String(format: "%.1f", baselineSeconds))s; " +
                "timeout is \(MutationReportFormatter.formatSeconds(timeout))s per mutant"
        )

        var coverage: BaselineCoverage?
        if options.coverage {
            progress.phase("running \(runner.name) with coverage in \(projectRoot) — this can take a while")
            // The coverage run is never fatal: the plain baseline already
            // decided pass / fail. Anything that leaves no usable data — an
            // error included — only costs the no_coverage shortcut.
            let result = (try? runner.runCoverageBaseline(progress: progress))
                ?? CoverageRunResult(exitCode: nil, coverage: nil)
            if let data = result.coverage {
                coverage = data
                if result.exitCode != 0 { notes.append(MutationNotes.coverageRunFailed(exitCode: result.exitCode)) }
            } else {
                notes.append(MutationNotes.noCoverageData)
            }
            progress.phase("rebuilding without coverage for the mutant runs")
            try runner.prepareMutantRuns(progress: progress)
        }

        let run = MutantRun(
            runner: runner,
            coverage: coverage,
            workspaceGuard: workspaceGuard,
            timeout: timeout,
            total: files.reduce(0) { $0 + $1.mutants.count },
            progress: progress
        )
        var statuses: [MutantStatus] = []
        for file in files {
            if let note = try runMutants(of: file, run: run, statuses: &statuses) {
                notes.append(note)
            }
        }
        return Execution(
            projectRoot: projectRoot,
            runner: runner.name,
            timeoutSeconds: timeout,
            coverageAvailable: coverage != nil,
            notes: notes,
            statuses: statuses
        )
    }

    /// What every mutant run shares.
    private struct MutantRun {
        let runner: any MutationTestRunner
        let coverage: BaselineCoverage?
        let workspaceGuard: WorkspaceGuard
        let timeout: TimeInterval
        let total: Int
        let progress: ProgressReporter
    }

    /// Run one file's mutants in order, appending their statuses. When the
    /// file changed after planning, that mutant and the rest of the file stay
    /// `pending` (an ignored mutant stays `ignored`, as in the other ports),
    /// and the returned note says so.
    private func runMutants(of file: PlannedFile, run: MutantRun, statuses: inout [MutantStatus]) throws -> String? {
        let planned = Data(file.source.utf8)
        var note: String?
        for mutant in file.mutants {
            var status: MutantStatus = mutant.ignored ? .ignored : .pending
            var duration: TimeInterval?
            if note == nil {
                do {
                    (status, duration) = try mutantStatus(file: file, planned: planned, mutant: mutant, run: run)
                } catch is WorkspaceGuard.FileChanged {
                    note = MutationNotes.fileChanged(file.absolutePath)
                }
            }
            statuses.append(status)
            let timing = duration.map { String(format: " (%.1fs)", $0) } ?? ""
            let site = mutant.site
            let label = status.rawValue.padding(toLength: max(13, status.rawValue.count), withPad: " ", startingAt: 0)
            run.progress.phase(
                "[\(statuses.count)/\(run.total)] \(label) \(site.file):\(site.line):\(site.column) " +
                    "\(site.mutationOperator.rawValue)\(timing)"
            )
        }
        return note
    }

    private func mutantStatus(
        file: PlannedFile,
        planned: Data,
        mutant: PlannedMutant,
        run: MutantRun
    ) throws -> (MutantStatus, TimeInterval?) {
        if mutant.ignored { return (.ignored, nil) }
        if let coverage = run.coverage, coverage.isUncovered(
            absolutePath: file.absolutePath,
            line: mutant.site.line,
            methodLines: mutant.methodLines
        ) {
            return (.noCoverage, nil)
        }
        let mutated = Data(mutant.site.apply(to: file.source).utf8)
        let result = try run.workspaceGuard.withMutant(file: file.absolutePath, planned: planned, mutated: mutated) {
            try run.runner.runMutant(timeout: run.timeout, progress: run.progress)
        }
        return (result.status, result.duration)
    }

    private func buildReport(
        sourcePath: String,
        options: Options,
        files: [PlannedFile],
        statuses: [MutantStatus],
        execution: Execution?
    ) -> MutationReport {
        let planned = files.flatMap(\.mutants)
        let mutants = zip(planned, statuses).map { MutantResult(planned: $0, status: $1) }
        let summary = MutationReport.Summary(mutants: mutants, fileCount: files.count)
        return MutationReport(
            sourceRoot: sourcePath,
            projectRoot: execution?.projectRoot,
            runner: execution?.runner,
            timeoutSeconds: execution?.timeoutSeconds,
            coverageAvailable: execution?.coverageAvailable ?? false,
            operators: options.operators,
            notes: (execution?.notes ?? []) + MutationNotes.resultNotes(summary),
            summary: summary,
            mutants: mutants
        )
    }
}
