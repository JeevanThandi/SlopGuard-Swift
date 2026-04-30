import Foundation

/// Joins per-file complexity output with optional coverage data to produce the
/// final `CrapReport`. Stateless and `Sendable`.
public struct CrapAggregator: Sendable {

    public init() {}

    /// - Parameters:
    ///   - fileReports:   Output of `DirectoryAnalyzer` / `SwiftFileAnalyzer`.
    ///   - sourceRootURL: Used to resolve `FileReport.path` (relative) to an
    ///                    absolute path so the coverage provider can match it.
    ///   - xcresultPath:  Recorded on the report; not used for analysis.
    ///   - threshold:     CRAP value above which a method/type is "crappy".
    ///   - coverage:      Optional. When `nil`, coverage is treated as 0% — the
    ///                    worst-case so that complexity alone surfaces loudly.
    ///   - notes:         Diagnostic strings to surface alongside the report
    ///                    (e.g. "tests ran but coverage was not gathered").
    public func aggregate(
        fileReports: [FileReport],
        sourceRootURL: URL,
        xcresultPath: String?,
        threshold: Double = CRAP.defaultThreshold,
        coverage: (any CoverageProvider)?,
        notes: [String] = []
    ) -> CrapReport {
        let rootAbsolute = sourceRootURL.standardizedFileURL.path
        let coverageAvailable = coverage != nil

        var methods: [MethodCrap] = []
        var totalComplexity = 0
        var totalCognitive = 0
        var totalWeighted = 0.0
        // Use Double for the weighted-coverage running totals so we don't lose
        // precision rounding fractional covered-line counts to Int.
        var totalCovered = 0.0
        var totalExecutable = 0

        for fileReport in fileReports {
            let absoluteFilePath = absolutize(rootAbsolute: rootAbsolute, relative: fileReport.path)
            for method in fileReport.methods {
                let cov = coverage.flatMap {
                    $0.methodCoverage(
                        absolutePath: absoluteFilePath,
                        line: method.startLine,
                        endLine: method.endLine
                    )
                } ?? coverage.flatMap {
                    $0.fileCoverage(absolutePath: absoluteFilePath)
                } ?? 0.0

                // Schema 2: feed the weighted blend into the formula. Cyclomatic
                // and cognitive ride along on the report so agents can see *why*
                // the score is what it is.
                let crap = CRAP.score(
                    complexity: method.weightedComplexity,
                    coveragePercent: cov
                )
                let executable = max(0, method.endLine - method.startLine + 1)

                methods.append(MethodCrap(
                    id: method.id,
                    file: method.file,
                    line: method.startLine,
                    endLine: method.endLine,
                    typeName: method.typeName,
                    name: method.name,
                    qualifiedName: method.qualifiedName,
                    kind: method.kind,
                    complexity: method.complexity,
                    cognitiveComplexity: method.cognitiveComplexity,
                    weightedComplexity: method.weightedComplexity,
                    coverage: cov,
                    crap: crap,
                    isCrappy: crap > threshold
                ))
                totalComplexity += method.complexity
                totalCognitive += method.cognitiveComplexity
                totalWeighted += method.weightedComplexity
                totalCovered += Double(executable) * cov / 100.0
                totalExecutable += executable
            }
        }

        // Per-type aggregation — group MethodCrap by (file, typeName) when set.
        var types: [TypeCrap] = []
        for fileReport in fileReports {
            for typeMetric in fileReport.types {
                let typeMethods = methods.filter { $0.file == fileReport.path && typeMetric.methodIDs.contains($0.id) }
                let craps = typeMethods.map(\.crap)
                let agg = CRAP.aggregate(craps)
                let weightedCov = weightedCoverage(typeMethods)
                // Type-level weighted: sqrt(totalCyc × totalCog), mirroring the
                // method-level GM. This is what feeds aggregatedCrap so the
                // type-level score is consistent with how individual methods
                // are scored.
                let weightedTotal = (
                    Double(typeMetric.totalComplexity)
                    * Double(typeMetric.totalCognitiveComplexity)
                ).squareRoot()
                let aggregated = CRAP.score(
                    complexity: weightedTotal,
                    coveragePercent: weightedCov
                )
                types.append(TypeCrap(
                    id: typeMetric.id,
                    file: typeMetric.file,
                    line: typeMetric.startLine,
                    kind: typeMetric.kind,
                    name: typeMetric.name,
                    methodCount: typeMetric.methodCount,
                    totalComplexity: typeMetric.totalComplexity,
                    maxComplexity: typeMetric.maxComplexity,
                    totalCognitiveComplexity: typeMetric.totalCognitiveComplexity,
                    maxCognitiveComplexity: typeMetric.maxCognitiveComplexity,
                    weightedTotalComplexity: weightedTotal,
                    weightedCoverage: weightedCov,
                    sumCrap: agg.sum,
                    maxCrap: agg.max,
                    aggregatedCrap: aggregated,
                    isCrappy: aggregated > threshold || agg.max > threshold
                ))
            }
        }

        methods.sort { $0.crap > $1.crap }
        types.sort { $0.aggregatedCrap > $1.aggregatedCrap }

        let crappyMethods = methods.lazy.filter(\.isCrappy).count
        let crappyTypes = types.lazy.filter(\.isCrappy).count
        let avgCrap = methods.isEmpty ? 0 : methods.reduce(0.0) { $0 + $1.crap } / Double(methods.count)
        let maxCrap = methods.first?.crap ?? 0
        let avgComplexity = methods.isEmpty ? 0 : Double(totalComplexity) / Double(methods.count)
        let avgCognitive = methods.isEmpty ? 0 : Double(totalCognitive) / Double(methods.count)
        let avgWeighted = methods.isEmpty ? 0 : totalWeighted / Double(methods.count)
        let weighted: Double? = (coverageAvailable && totalExecutable > 0)
            ? totalCovered / Double(totalExecutable) * 100.0
            : (coverageAvailable ? 0.0 : nil)

        let summary = CrapReport.Summary(
            fileCount: fileReports.count,
            typeCount: types.count,
            methodCount: methods.count,
            crappyMethodCount: crappyMethods,
            crappyTypeCount: crappyTypes,
            averageCrap: avgCrap,
            maxCrap: maxCrap,
            averageComplexity: avgComplexity,
            averageCognitiveComplexity: avgCognitive,
            averageWeightedComplexity: avgWeighted,
            weightedCoverage: weighted
        )

        // Prepend the schema-2 explanation so JSON consumers and CLI users see
        // the meaning shift loudly. Keep any caller-supplied notes after.
        let allNotes = [Self.schemaTwoNote] + notes

        return CrapReport(
            toolVersion: SlopguardVersion.version,
            sourceRoot: rootAbsolute,
            xcresultPath: xcresultPath,
            threshold: threshold,
            coverageAvailable: coverageAvailable,
            notes: allNotes,
            summary: summary,
            methods: methods,
            types: types
        )
    }

    /// Standing note on every schema-2 report so downstream consumers know the
    /// `crap`-derived fields are driven by the weighted blend, not raw cyclomatic.
    /// The reported score is `wCRAP` (weighted CRAP), not the classic Pearson
    /// CRAP — cross-tool comparisons need adjustment for the change of input.
    private static let schemaTwoNote =
        "Score is wCRAP (weighted CRAP) since schema 2: complexity input is " +
        "weightedComplexity = sqrt(cyclomatic × cognitive), not raw cyclomatic. " +
        "Both raw metrics ship under `complexity` (cyclomatic, McCabe) and " +
        "`cognitiveComplexity` (SonarSource 2023); the score itself is reported " +
        "under the existing `crap` field for schema continuity. Recursion " +
        "increment is deferred (known undercount vs Sonar parity)."

    private func weightedCoverage(_ methods: [MethodCrap]) -> Double {
        guard !methods.isEmpty else { return 0 }
        var totalLines = 0
        var weighted = 0.0
        for m in methods {
            let lines = max(1, m.endLine - m.line + 1)
            totalLines += lines
            weighted += m.coverage * Double(lines)
        }
        return totalLines == 0 ? 0 : weighted / Double(totalLines)
    }
}

private func absolutize(rootAbsolute: String, relative: String) -> String {
    if relative.hasPrefix("/") { return relative }
    let separator = rootAbsolute.hasSuffix("/") ? "" : "/"
    return rootAbsolute + separator + relative
}
