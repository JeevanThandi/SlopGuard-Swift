import Foundation

/// Top-level JSON payload emitted by the CLI (`--json`) and returned by MCP tools.
/// Stable, versioned (`schemaVersion`) so agents can rely on the shape.
public struct CrapReport: Sendable, Hashable, Codable {
    /// Schema 2 (current): adds `cognitiveComplexity` + `weightedComplexity`
    /// throughout, and re-points the `crap` / `aggregatedCrap` formula at the
    /// weighted blend (`sqrt(cyc × cog)`). JSON shape is purely additive but
    /// the *meaning* of `crap`-derived fields shifts vs schema 1, so consumers
    /// comparing reports across versions will see scores drop dramatically on
    /// flat-dispatch code (the intended fix).
    public static let currentSchemaVersion = "2"

    public let schemaVersion: String
    public let tool: String
    public let toolVersion: String
    public let generatedAt: Date
    public let sourceRoot: String
    public let xcresultPath: String?
    public let threshold: Double
    public let coverageAvailable: Bool
    /// Human-readable diagnostic notes — surfaced when slopguard had to make
    /// a judgement call the user should know about (e.g. "tests ran but
    /// coverage wasn't gathered"). Empty by default; additive in JSON output.
    public let notes: [String]

    public let summary: Summary
    public let methods: [MethodCrap]
    public let types: [TypeCrap]

    public init(
        tool: String = "slopguard-swift",
        toolVersion: String,
        generatedAt: Date = .init(),
        sourceRoot: String,
        xcresultPath: String?,
        threshold: Double,
        coverageAvailable: Bool,
        notes: [String] = [],
        summary: Summary,
        methods: [MethodCrap],
        types: [TypeCrap]
    ) {
        self.schemaVersion = CrapReport.currentSchemaVersion
        self.tool = tool
        self.toolVersion = toolVersion
        self.generatedAt = generatedAt
        self.sourceRoot = sourceRoot
        self.xcresultPath = xcresultPath
        self.threshold = threshold
        self.coverageAvailable = coverageAvailable
        self.notes = notes
        self.summary = summary
        self.methods = methods
        self.types = types
    }

    public struct Summary: Sendable, Hashable, Codable {
        public let fileCount: Int
        public let typeCount: Int
        public let methodCount: Int
        public let crappyMethodCount: Int
        public let crappyTypeCount: Int
        public let averageCrap: Double
        public let maxCrap: Double
        public let averageComplexity: Double
        public let averageCognitiveComplexity: Double
        public let averageWeightedComplexity: Double
        public let weightedCoverage: Double?

        public init(
            fileCount: Int,
            typeCount: Int,
            methodCount: Int,
            crappyMethodCount: Int,
            crappyTypeCount: Int,
            averageCrap: Double,
            maxCrap: Double,
            averageComplexity: Double,
            averageCognitiveComplexity: Double,
            averageWeightedComplexity: Double,
            weightedCoverage: Double?
        ) {
            self.fileCount = fileCount
            self.typeCount = typeCount
            self.methodCount = methodCount
            self.crappyMethodCount = crappyMethodCount
            self.crappyTypeCount = crappyTypeCount
            self.averageCrap = averageCrap
            self.maxCrap = maxCrap
            self.averageComplexity = averageComplexity
            self.averageCognitiveComplexity = averageCognitiveComplexity
            self.averageWeightedComplexity = averageWeightedComplexity
            self.weightedCoverage = weightedCoverage
        }
    }
}

/// A single method's CRAP entry in the final report.
public struct MethodCrap: Sendable, Hashable, Codable {
    public let id: String
    public let file: String
    public let line: Int
    public let endLine: Int
    public let typeName: String?
    public let name: String
    public let qualifiedName: String
    public let kind: MethodKind
    /// Cyclomatic complexity (McCabe). Preserved for cross-tool parity.
    public let complexity: Int
    /// Cognitive complexity (SonarSource 2023). Tracks how hard the code is
    /// to *understand* — flat dispatch is +1, nesting is amplified.
    public let cognitiveComplexity: Int
    /// `sqrt(complexity × cognitiveComplexity)` — the value fed into the CRAP
    /// formula since schema 2.
    public let weightedComplexity: Double
    public let coverage: Double
    public let crap: Double
    public let isCrappy: Bool

    public init(
        id: String,
        file: String,
        line: Int,
        endLine: Int,
        typeName: String?,
        name: String,
        qualifiedName: String,
        kind: MethodKind,
        complexity: Int,
        cognitiveComplexity: Int,
        weightedComplexity: Double,
        coverage: Double,
        crap: Double,
        isCrappy: Bool
    ) {
        self.id = id
        self.file = file
        self.line = line
        self.endLine = endLine
        self.typeName = typeName
        self.name = name
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.complexity = complexity
        self.cognitiveComplexity = cognitiveComplexity
        self.weightedComplexity = weightedComplexity
        self.coverage = coverage
        self.crap = crap
        self.isCrappy = isCrappy
    }
}

/// A type-level aggregation entry in the final report.
public struct TypeCrap: Sendable, Hashable, Codable {
    public let id: String
    public let file: String
    public let line: Int
    public let kind: TypeKind
    public let name: String
    public let methodCount: Int
    /// Cyclomatic sum / max across the type's methods. Preserved for parity.
    public let totalComplexity: Int
    public let maxComplexity: Int
    /// Cognitive sum / max across the type's methods.
    public let totalCognitiveComplexity: Int
    public let maxCognitiveComplexity: Int
    /// `sqrt(totalComplexity × totalCognitiveComplexity)` — feeds `aggregatedCrap`
    /// since schema 2.
    public let weightedTotalComplexity: Double
    public let weightedCoverage: Double
    public let sumCrap: Double
    public let maxCrap: Double
    public let aggregatedCrap: Double
    public let isCrappy: Bool

    public init(
        id: String,
        file: String,
        line: Int,
        kind: TypeKind,
        name: String,
        methodCount: Int,
        totalComplexity: Int,
        maxComplexity: Int,
        totalCognitiveComplexity: Int,
        maxCognitiveComplexity: Int,
        weightedTotalComplexity: Double,
        weightedCoverage: Double,
        sumCrap: Double,
        maxCrap: Double,
        aggregatedCrap: Double,
        isCrappy: Bool
    ) {
        self.id = id
        self.file = file
        self.line = line
        self.kind = kind
        self.name = name
        self.methodCount = methodCount
        self.totalComplexity = totalComplexity
        self.maxComplexity = maxComplexity
        self.totalCognitiveComplexity = totalCognitiveComplexity
        self.maxCognitiveComplexity = maxCognitiveComplexity
        self.weightedTotalComplexity = weightedTotalComplexity
        self.weightedCoverage = weightedCoverage
        self.sumCrap = sumCrap
        self.maxCrap = maxCrap
        self.aggregatedCrap = aggregatedCrap
        self.isCrappy = isCrappy
    }
}
