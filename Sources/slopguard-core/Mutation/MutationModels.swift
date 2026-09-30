import Foundation

/// What happened to a mutant.
///
/// - `killed` — the tests failed with the mutant in place (good).
/// - `survived` — the tests still passed (a gap: no test checks this behaviour).
/// - `timeout` — the run exceeded the timeout; counted as killed.
/// - `no_coverage` — no test executes the mutated line, so it was not run.
/// - `compile_error` — the mutant did not compile; excluded from the score.
/// - `ignored` — switched off by a `slopguard-ignore-mutant` marker.
/// - `pending` — listed by `--dry-run`, never run.
public enum MutantStatus: String, Sendable, Codable, CaseIterable {
    case killed
    case survived
    case timeout
    case noCoverage = "no_coverage"
    case compileError = "compile_error"
    case ignored
    case pending
}

/// One planned source change, before any test run. `utf8Start` / `utf8End`
/// index the file's UTF-8 bytes; `line` and `column` are 1-based, with
/// `column` counted in Unicode code points.
public struct MutantSite: Sendable, Hashable {
    /// Path relative to the source root (forward-slash-normalized).
    public let file: String
    public let line: Int
    public let column: Int
    public let mutationOperator: MutationOperator
    /// The exact source text the mutant replaces.
    public let original: String
    /// The exact text written in its place.
    public let replacement: String
    public let utf8Start: Int
    public let utf8End: Int

    public init(
        file: String,
        line: Int,
        column: Int,
        mutationOperator: MutationOperator,
        original: String,
        replacement: String,
        utf8Start: Int,
        utf8End: Int
    ) {
        self.file = file
        self.line = line
        self.column = column
        self.mutationOperator = mutationOperator
        self.original = original
        self.replacement = replacement
        self.utf8Start = utf8Start
        self.utf8End = utf8End
    }

    /// Stable id: `<file>:<line>:<column>:<operator>`.
    public var id: String { "\(file):\(line):\(column):\(mutationOperator.rawValue)" }

    /// Report order: file (byte-wise), then line, column and operator id.
    public static func precedes(_ a: MutantSite, _ b: MutantSite) -> Bool {
        if a.file != b.file { return a.file.utf8.lexicographicallyPrecedes(b.file.utf8) }
        if a.line != b.line { return a.line < b.line }
        if a.column != b.column { return a.column < b.column }
        return a.mutationOperator < b.mutationOperator
    }

    /// `source` with this mutant applied.
    public func apply(to source: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(utf8Start..<utf8End, with: Array(replacement.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A mutant plus everything known about it before any test run.
public struct PlannedMutant: Sendable, Hashable {
    public let site: MutantSite
    /// Qualified name of the innermost enclosing method, or `nil` for code
    /// outside any method.
    public let method: String?
    /// `[startLine, endLine]` of that method, or `nil`.
    public let methodLines: ClosedRange<Int>?
    /// Switched off by a `slopguard-ignore-mutant` marker.
    public let ignored: Bool

    public init(site: MutantSite, method: String?, methodLines: ClosedRange<Int>?, ignored: Bool) {
        self.site = site
        self.method = method
        self.methodLines = methodLines
        self.ignored = ignored
    }
}

/// A mutant in the final report.
public struct MutantResult: Sendable, Hashable, Codable {
    /// Stable id: `<file>:<line>:<column>:<operator>`.
    public let id: String
    public let file: String
    public let line: Int
    public let column: Int
    public let mutationOperator: MutationOperator
    public let original: String
    public let replacement: String
    /// Qualified name of the innermost enclosing method, or `nil` for code
    /// outside any method (encoded as JSON `null`).
    public let method: String?
    public let status: MutantStatus

    public init(planned: PlannedMutant, status: MutantStatus) {
        self.init(
            id: planned.site.id,
            file: planned.site.file,
            line: planned.site.line,
            column: planned.site.column,
            mutationOperator: planned.site.mutationOperator,
            original: planned.site.original,
            replacement: planned.site.replacement,
            method: planned.method,
            status: status
        )
    }

    public init(
        id: String,
        file: String,
        line: Int,
        column: Int,
        mutationOperator: MutationOperator,
        original: String,
        replacement: String,
        method: String?,
        status: MutantStatus
    ) {
        self.id = id
        self.file = file
        self.line = line
        self.column = column
        self.mutationOperator = mutationOperator
        self.original = original
        self.replacement = replacement
        self.method = method
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, file, line, column, original, replacement, method, status
        case mutationOperator = "operator"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
        try container.encode(mutationOperator, forKey: .mutationOperator)
        try container.encode(original, forKey: .original)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(method, forKey: .method)   // explicit null
        try container.encode(status, forKey: .status)
    }
}

/// Top-level JSON payload of `mutate --json`. Versioned separately from the
/// CRAP report (`reportType` tells the two apart). Shared with every port.
public struct MutationReport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = "1"
    public static let reportTypeName = "mutation"

    public let schemaVersion: String
    public let reportType: String
    public let tool: String
    public let toolVersion: String
    public let generatedAt: Date
    public let sourceRoot: String
    /// Where the tests ran; `nil` when no test ran (dry run, or nothing to run).
    public let projectRoot: String?
    /// The test runner driven for mutants (`swift test`, `xcodebuild`); `nil`
    /// when no test ran.
    public let runner: String?
    /// Per-mutant timeout in seconds; `nil` when no test ran.
    public let timeoutSeconds: Double?
    /// Whether line coverage classified `no_coverage` mutants.
    public let coverageAvailable: Bool
    /// The enabled operator ids, sorted.
    public let operators: [MutationOperator]
    /// Plain-sentence diagnostics (recovered files, missing coverage, …).
    public let notes: [String]
    public let summary: Summary
    public let mutants: [MutantResult]

    public init(
        tool: String = SlopguardVersion.toolName,
        toolVersion: String = SlopguardVersion.version,
        generatedAt: Date = Date(),
        sourceRoot: String,
        projectRoot: String?,
        runner: String?,
        timeoutSeconds: Double?,
        coverageAvailable: Bool,
        operators: [MutationOperator],
        notes: [String],
        summary: Summary,
        mutants: [MutantResult]
    ) {
        self.schemaVersion = MutationReport.currentSchemaVersion
        self.reportType = MutationReport.reportTypeName
        self.tool = tool
        self.toolVersion = toolVersion
        self.generatedAt = generatedAt
        self.sourceRoot = sourceRoot
        self.projectRoot = projectRoot
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
        self.coverageAvailable = coverageAvailable
        self.operators = operators
        self.notes = notes
        self.summary = summary
        self.mutants = mutants
    }

    public struct Summary: Sendable, Hashable, Codable {
        /// Source files scanned, including files that yielded no mutants.
        public let fileCount: Int
        public let mutantCount: Int
        public let killed: Int
        public let survived: Int
        public let timedOut: Int
        public let noCoverage: Int
        public let compileErrors: Int
        public let ignored: Int
        public let pending: Int
        /// `(killed + timedOut) / (killed + timedOut + survived + noCoverage) × 100`,
        /// unrounded, or `nil` when no mutant counts towards the score.
        public let mutationScore: Double?

        /// Count each status of `mutants` and compute the score.
        public init(mutants: [MutantResult], fileCount: Int) {
            func count(_ status: MutantStatus) -> Int { mutants.lazy.filter { $0.status == status }.count }
            let killed = count(.killed)
            let timedOut = count(.timeout)
            let survived = count(.survived)
            let noCoverage = count(.noCoverage)
            let detected = killed + timedOut
            let scored = detected + survived + noCoverage
            self.fileCount = fileCount
            self.mutantCount = mutants.count
            self.killed = killed
            self.survived = survived
            self.timedOut = timedOut
            self.noCoverage = noCoverage
            self.compileErrors = count(.compileError)
            self.ignored = count(.ignored)
            self.pending = count(.pending)
            self.mutationScore = scored == 0 ? nil : Double(detected) / Double(scored) * 100
        }

        private enum CodingKeys: String, CodingKey {
            case fileCount, mutantCount, killed, survived, timedOut, noCoverage
            case compileErrors, ignored, pending, mutationScore
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(fileCount, forKey: .fileCount)
            try container.encode(mutantCount, forKey: .mutantCount)
            try container.encode(killed, forKey: .killed)
            try container.encode(survived, forKey: .survived)
            try container.encode(timedOut, forKey: .timedOut)
            try container.encode(noCoverage, forKey: .noCoverage)
            try container.encode(compileErrors, forKey: .compileErrors)
            try container.encode(ignored, forKey: .ignored)
            try container.encode(pending, forKey: .pending)
            try container.encode(mutationScore, forKey: .mutationScore)   // explicit null
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, reportType, tool, toolVersion, generatedAt, sourceRoot, projectRoot
        case runner, timeoutSeconds, coverageAvailable, operators, notes, summary, mutants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        reportType = try container.decode(String.self, forKey: .reportType)
        tool = try container.decode(String.self, forKey: .tool)
        toolVersion = try container.decode(String.self, forKey: .toolVersion)
        let stamp = try container.decode(String.self, forKey: .generatedAt)
        guard let date = MutationReport.parseTimestamp(stamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generatedAt,
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp, got \(stamp)"
            )
        }
        generatedAt = date
        sourceRoot = try container.decode(String.self, forKey: .sourceRoot)
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        runner = try container.decodeIfPresent(String.self, forKey: .runner)
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        coverageAvailable = try container.decode(Bool.self, forKey: .coverageAvailable)
        operators = try container.decode([MutationOperator].self, forKey: .operators)
        notes = try container.decode([String].self, forKey: .notes)
        summary = try container.decode(Summary.self, forKey: .summary)
        mutants = try container.decode([MutantResult].self, forKey: .mutants)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(reportType, forKey: .reportType)
        try container.encode(tool, forKey: .tool)
        try container.encode(toolVersion, forKey: .toolVersion)
        try container.encode(MutationReport.timestamp(generatedAt), forKey: .generatedAt)
        try container.encode(sourceRoot, forKey: .sourceRoot)
        try container.encode(projectRoot, forKey: .projectRoot)        // explicit null
        try container.encode(runner, forKey: .runner)                  // explicit null
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)  // explicit null
        try container.encode(coverageAvailable, forKey: .coverageAvailable)
        try container.encode(operators, forKey: .operators)
        try container.encode(notes, forKey: .notes)
        try container.encode(summary, forKey: .summary)
        try container.encode(mutants, forKey: .mutants)
    }

    /// UTC ISO-8601 with milliseconds (`2026-09-30T12:00:00.000Z`), the
    /// timestamp format every port writes.
    public static func timestamp(_ date: Date) -> String {
        timestampFormatter().string(from: date)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter().date(from: text)
    }

    /// `ISO8601DateFormatter` is not `Sendable`, so each call builds its own.
    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// The standard report notes, worded identically in every port.
public enum MutationNotes {
    public static let noCoverageData =
        "The baseline test run produced no coverage data, so every mutant was run."
    public static let everyMutantSurvived =
        "Every tested mutant survived. Check that the tests import the source under --path."

    public static func compileErrors(_ count: Int) -> String {
        "\(count) mutant(s) did not compile and are excluded from the score."
    }

    /// A file edited while `mutate` was running: its remaining mutants stay `pending`.
    public static func fileChanged(_ absolutePath: String) -> String {
        "\(absolutePath) changed while mutate was running, so its remaining mutants were not run."
    }

    public static func coverageRunFailed(exitCode: Int32?) -> String {
        "The coverage run exited with code \(exitCode.map { "\($0)" } ?? "unknown"); its coverage data was still used."
    }

    /// Notes that follow from the results: every tested mutant survived, or
    /// some mutants did not compile.
    public static func resultNotes(_ summary: MutationReport.Summary) -> [String] {
        var notes: [String] = []
        if summary.survived > 0 && summary.killed + summary.timedOut == 0 {
            notes.append(everyMutantSurvived)
        }
        if summary.compileErrors > 0 {
            notes.append(compileErrors(summary.compileErrors))
        }
        return notes
    }
}
