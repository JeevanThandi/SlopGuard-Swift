import Foundation

/// The pure-syntactic analysis result for a single Swift file. Contains complexity
/// metrics for every declaration found, plus aggregations per enclosing type.
public struct FileReport: Sendable, Hashable, Codable {
    public let path: String
    public let methods: [MethodMetric]
    public let types: [TypeMetric]

    public init(path: String, methods: [MethodMetric], types: [TypeMetric]) {
        self.path = path
        self.methods = methods
        self.types = types
    }
}
