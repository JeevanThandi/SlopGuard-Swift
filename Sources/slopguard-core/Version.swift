import Foundation

/// Build-stamped version constants. Edit `version` for releases; the CI workflow
/// asserts this matches the git tag.
public enum SlopguardVersion: Sendable {
    public static let version = "0.1.0"
    public static let toolName = "slopguard-swift"
}
