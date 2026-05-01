import Foundation

/// What kind of declaration this metric describes. Used to render qualified names
/// and for downstream filtering (e.g. "show me only initializers").
public enum MethodKind: String, Sendable, Codable, CaseIterable {
    case function
    case initializer
    case deinitializer
    case `subscript`
    case getter
    case setter
    case willSet
    case didSet
}

/// What kind of enclosing type owns a method. Free functions use `.none` (encoded as `nil`).
public enum TypeKind: String, Sendable, Codable, CaseIterable {
    case `class`
    case `struct`
    case `enum`
    case `actor`
    case `extension`
    case `protocol`
}

/// Pure analysis output for a single declaration. No coverage data is attached here —
/// coverage is joined later by `CrapAggregator` so that this type stays useful in
/// no-coverage modes (e.g. `analyze` without `--xcresult`).
public struct MethodMetric: Sendable, Hashable, Codable {

    /// The leaf name as written in source, e.g. `bar(_:)`, `init(name:)`, `subscript(_:)`.
    public let name: String

    /// Fully qualified name including the enclosing type chain, e.g. `Outer.Inner.bar(_:)`.
    /// For free functions this equals `name`.
    public let qualifiedName: String

    /// Name of the immediate enclosing type, if any.
    public let typeName: String?

    public let kind: MethodKind

    /// Path relative to the analysis root (forward-slash-normalized).
    public let file: String

    public let startLine: Int
    public let endLine: Int

    /// Cyclomatic complexity (McCabe). Counts every branching decision +1
    /// from a base of 1. Preserved for cross-tool comparability — every other
    /// CRAP-style tool reports cyclomatic, so consumers can still align.
    public let complexity: Int

    /// Cognitive complexity per the SonarSource 2023 spec. Designed to track
    /// how hard the code is to *understand* rather than how many test cases
    /// it needs: flat dispatch (large `switch`) is +1 total; nesting is
    /// amplified; `guard`-style early exits are 0. See SKILL.md for the full
    /// rule table.
    public let cognitiveComplexity: Int

    /// Geometric mean `sqrt(complexity × cognitiveComplexity)`. This is the
    /// value `CrapAggregator` feeds into the CRAP formula since schema 2 —
    /// it dampens cyclomatic-only false positives on flat dispatch while
    /// staying honest on genuinely nested code.
    public let weightedComplexity: Double

    public init(
        name: String,
        qualifiedName: String,
        typeName: String?,
        kind: MethodKind,
        file: String,
        startLine: Int,
        endLine: Int,
        complexity: Int,
        cognitiveComplexity: Int
    ) {
        self.name = name
        self.qualifiedName = qualifiedName
        self.typeName = typeName
        self.kind = kind
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.complexity = complexity
        self.cognitiveComplexity = cognitiveComplexity
        self.weightedComplexity = (Double(max(0, complexity)) * Double(max(0, cognitiveComplexity))).squareRoot()
    }

    /// Stable identifier suitable for cross-tool references.
    /// Format: `relative/path.swift#Qualified.Name@startLine`.
    public var id: String { "\(file)#\(qualifiedName)@\(startLine)" }
}
