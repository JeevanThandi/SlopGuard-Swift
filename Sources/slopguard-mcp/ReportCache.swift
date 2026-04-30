import Foundation
import SlopguardCore

/// In-memory cache of the most recent `CrapReport`. Backed by an actor so the MCP
/// `analyze_*` tools can write while `get_crap_report` and friends read concurrently.
public actor ReportCache {

    private var lastReport: CrapReport?
    private var lastSourceRoot: String?
    private var lastXcresult: String?

    public init() {}

    public func store(report: CrapReport, sourceRoot: String, xcresultPath: String?) {
        self.lastReport = report
        self.lastSourceRoot = sourceRoot
        self.lastXcresult = xcresultPath
    }

    public func get() -> CrapReport? { lastReport }

    public func describe() -> (sourceRoot: String?, xcresult: String?) {
        (lastSourceRoot, lastXcresult)
    }
}
