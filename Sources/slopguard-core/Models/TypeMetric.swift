import Foundation

/// Aggregated complexity for a single enclosing type (class/struct/enum/actor/extension).
public struct TypeMetric: Sendable, Hashable, Codable {

    public let kind: TypeKind
    public let name: String
    public let file: String
    public let startLine: Int
    public let endLine: Int

    /// Qualified names of the methods that belong to this type. Used to look them up
    /// in the flat `[MethodMetric]` produced by the same file analysis pass.
    public let methodIDs: [String]

    public let methodCount: Int
    public let totalComplexity: Int
    public let maxComplexity: Int
    public let totalCognitiveComplexity: Int
    public let maxCognitiveComplexity: Int

    public init(
        kind: TypeKind,
        name: String,
        file: String,
        startLine: Int,
        endLine: Int,
        methodIDs: [String],
        methodCount: Int,
        totalComplexity: Int,
        maxComplexity: Int,
        totalCognitiveComplexity: Int,
        maxCognitiveComplexity: Int
    ) {
        self.kind = kind
        self.name = name
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.methodIDs = methodIDs
        self.methodCount = methodCount
        self.totalComplexity = totalComplexity
        self.maxComplexity = maxComplexity
        self.totalCognitiveComplexity = totalCognitiveComplexity
        self.maxCognitiveComplexity = maxCognitiveComplexity
    }

    public var id: String { "\(file)#\(name)@\(startLine)" }
}
