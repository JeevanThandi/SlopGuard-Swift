import Foundation
import SlopguardCore

/// Probes an `.xcresult` bundle to answer a single question: how many tests ran?
///
/// xccov collapses "scheme had no tests" and "test plan suppressed coverage"
/// into the same "No coverage data in result bundle" stderr. The pipeline
/// distinguishes them by counting test runs in the bundle — non-zero means
/// the user has tests but coverage was misconfigured (a much louder note),
/// zero means the report's 0% is an honest reflection of reality.
///
/// `nil` from any probe call means *we could not determine* — older Xcode,
/// missing tool, decode failure. Callers should treat that as
/// `.coverageNotGathered(testCount: nil)` rather than guessing "no tests".
public protocol XcresultTestProbing: Sendable {
    func testCount(xcresultURL: URL) async -> Int?
}

public struct XcresultProbe: XcresultTestProbing, Sendable {

    public init() {}

    public func testCount(xcresultURL: URL) async -> Int? {
        let path = xcresultURL.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.probe(xcresultPath: path)
        }.value
    }

    /// Try the modern `xcresulttool get test-results tests` first, then fall
    /// back to the legacy command. Both produce JSON we can walk for test
    /// nodes; either form failing returns `nil` rather than throwing — a
    /// probe that can't decide should never block analysis.
    static func probe(xcresultPath: String) -> Int? {
        if let count = runModern(xcresultPath: xcresultPath) {
            return count
        }
        return runLegacy(xcresultPath: xcresultPath)
    }

    private static func runModern(xcresultPath: String) -> Int? {
        let outcome = try? ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", xcresultPath],
            launchError: { SlopguardError.xccovUnavailable(reason: "\($0)") }
        )
        guard let outcome, outcome.exitCode == 0 else { return nil }
        return countTestCases(modernJSON: outcome.output)
    }

    private static func runLegacy(xcresultPath: String) -> Int? {
        let outcome = try? ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "--legacy", "--path", xcresultPath, "--format", "json"],
            launchError: { SlopguardError.xccovUnavailable(reason: "\($0)") }
        )
        guard let outcome, outcome.exitCode == 0 else { return nil }
        return countTestCases(legacyJSON: outcome.output)
    }

    /// Modern `xcresulttool get test-results tests` returns a tree of
    /// `testNodes`. We count nodes whose `nodeType == "Test Case"`. Any
    /// shape we don't recognise yields `nil` so the caller can fall back
    /// rather than report a wrong count.
    static func countTestCases(modernJSON data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let nodes = (root["testNodes"] as? [[String: Any]]) ?? []
        // Empty `testNodes` is a positive signal — the bundle truly has no
        // test cases. Non-nil zero is fine.
        return walkTestNodes(nodes)
    }

    private static func walkTestNodes(_ nodes: [[String: Any]]) -> Int {
        var total = 0
        for node in nodes {
            if (node["nodeType"] as? String) == "Test Case" {
                total += 1
            }
            if let children = node["children"] as? [[String: Any]] {
                total += walkTestNodes(children)
            }
        }
        return total
    }

    /// Legacy `xcresulttool get --legacy --format json` produces an
    /// `actions._values[].actionResult.testsRef` reference per action; the
    /// presence of a non-empty `testsRef` indicates tests were attached.
    /// We don't drill into the referenced summary (that requires another
    /// xcresulttool call); a single non-empty ref is enough to say
    /// "tests ran" — caller treats unknown count as `coverageNotGathered`.
    static func countTestCases(legacyJSON data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let actions = (root["actions"] as? [String: Any])?["_values"] as? [[String: Any]] ?? []
        var sawTestsRef = false
        for action in actions {
            let result = action["actionResult"] as? [String: Any]
            if let ref = result?["testsRef"] as? [String: Any], !ref.isEmpty {
                sawTestsRef = true
                break
            }
        }
        // Legacy can only tell us "any tests ran" vs "none". Map to a
        // sentinel so the pipeline picks the right reason: 0 = none,
        // 1 = "at least one" (we don't know exactly how many).
        return sawTestsRef ? 1 : 0
    }
}
