import Foundation

/// Sink for human-readable progress chatter from long-running operations
/// (directory walks, xcodebuild test runs, coverage parsing). Always goes
/// to a side channel so it can't pollute the main result stream — the CLI
/// binds it to stderr so `--json` consumers piping into `jq` stay clean.
public struct ProgressReporter: Sendable {

    public enum Verbosity: Sendable, Equatable {
        /// `--quiet`: emit nothing.
        case silent
        /// Default: high-level phase markers ("running xcodebuild test…").
        case normal
        /// `--verbose`: phase markers AND stream subprocess output through.
        case verbose
    }

    public let verbosity: Verbosity
    private let messageSink: @Sendable (String) -> Void
    private let rawSink: @Sendable (Data) -> Void

    public init(
        verbosity: Verbosity,
        messageSink: @escaping @Sendable (String) -> Void,
        rawSink: @escaping @Sendable (Data) -> Void
    ) {
        self.verbosity = verbosity
        self.messageSink = messageSink
        self.rawSink = rawSink
    }

    /// A reporter that swallows everything. Default for library callers.
    public static let silent = ProgressReporter(
        verbosity: .silent,
        messageSink: { _ in },
        rawSink: { _ in }
    )

    /// A reporter wired to `FileHandle.standardError`. The CLI's default.
    public static func stderr(verbosity: Verbosity = .normal) -> ProgressReporter {
        ProgressReporter(
            verbosity: verbosity,
            messageSink: { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            },
            rawSink: { chunk in
                FileHandle.standardError.write(chunk)
            }
        )
    }

    /// Emit a phase marker. Suppressed when `verbosity == .silent`. Output
    /// is prefixed with `slopguard: ` so it's distinguishable from xcodebuild
    /// chatter when both share stderr.
    public func phase(_ message: String) {
        guard verbosity != .silent else { return }
        messageSink("slopguard: \(message)")
    }

    /// Pass raw subprocess bytes through verbatim. Suppressed unless
    /// `verbosity == .verbose`. No framing — the subprocess chose its
    /// own.
    public func raw(_ data: Data) {
        guard verbosity == .verbose else { return }
        rawSink(data)
    }

    public var isVerbose: Bool { verbosity == .verbose }
}
