import Foundation

/// `Decodable` mirror of the JSON produced by:
///
///     xcrun xccov view --report --json /path/to/Result.xcresult
///
/// The shape is:
///
///     { coveredLines, executableLines, lineCoverage,
///       targets: [
///         { name, coveredLines, executableLines, lineCoverage,
///           files: [
///             { name, path, coveredLines, executableLines, lineCoverage,
///               functions: [
///                 { name, lineNumber, executionCount,
///                   coveredLines, executableLines, lineCoverage }
///               ]
///             }
///           ]
///         }
///       ]
///     }
///
/// Unknown fields are tolerated by `JSONDecoder` (it only requires our declared keys).
public struct XccovReport: Sendable, Hashable, Codable {
    public let coveredLines: Int
    public let executableLines: Int
    public let lineCoverage: Double
    public let targets: [XccovTarget]
}

public struct XccovTarget: Sendable, Hashable, Codable {
    public let name: String
    public let coveredLines: Int
    public let executableLines: Int
    public let lineCoverage: Double
    public let files: [XccovFile]
}

public struct XccovFile: Sendable, Hashable, Codable {
    public let name: String
    public let path: String
    public let coveredLines: Int
    public let executableLines: Int
    public let lineCoverage: Double
    public let functions: [XccovFunction]
}

public struct XccovFunction: Sendable, Hashable, Codable {
    public let name: String
    public let lineNumber: Int
    public let executionCount: Int
    public let coveredLines: Int
    public let executableLines: Int
    public let lineCoverage: Double
}
