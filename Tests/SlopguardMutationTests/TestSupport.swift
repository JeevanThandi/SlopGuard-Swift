import Foundation
@testable import SlopguardCore
@testable import SlopguardMutation

/// A fresh directory under the OS temp dir (real path, so `/var` vs
/// `/private/var` never differs), removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

func makeTemporaryDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("slopguard-mutation-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return URL(fileURLWithPath: LineCoverageIndex.canonicalPath(base.path), isDirectory: true)
}

/// Write `contents` to `relative` under `root`, creating directories.
@discardableResult
func write(_ contents: String, to relative: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

func read(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// Collects everything a `ProgressReporter` emits.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    private var _raw = Data()

    var messages: [String] { lock.withLock { _messages } }
    var raw: Data { lock.withLock { _raw } }

    func reporter(_ verbosity: ProgressReporter.Verbosity = .normal) -> ProgressReporter {
        ProgressReporter(
            verbosity: verbosity,
            messageSink: { [self] line in lock.withLock { _messages.append(line) } },
            rawSink: { [self] chunk in lock.withLock { _raw.append(chunk) } }
        )
    }
}

/// A `CommandRunning` fake: records every call and answers from a script.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        let spec: CommandSpec
        let timeout: TimeInterval?
        let captureStdout: Bool
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _stopped = false
    private let respond: @Sendable (CommandSpec) throws -> CommandOutcome

    init(respond: @escaping @Sendable (CommandSpec) throws -> CommandOutcome) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { _calls } }
    var stopped: Bool { lock.withLock { _stopped } }

    func run(_ spec: CommandSpec, timeout: TimeInterval?, captureStdout: Bool, progress: ProgressReporter) throws -> CommandOutcome {
        lock.withLock { _calls.append(Call(spec: spec, timeout: timeout, captureStdout: captureStdout)) }
        return try respond(spec)
    }

    func stop() {
        lock.withLock { _stopped = true }
    }
}

/// A `MutationTestRunner` fake: scripted baseline, coverage and per-mutant
/// results, plus a hook that runs while each mutant is in place.
final class FakeMutationRunner: MutationTestRunner, @unchecked Sendable {
    let name = "swift test"
    var baselineSeconds: TimeInterval = 2.1
    var baselineError: Error?
    var coverage: CoverageRunResult = CoverageRunResult(exitCode: 0, coverage: nil)
    var coverageError: Error?
    /// Called for each mutant run, in order; returns its status.
    var onMutant: (Int) throws -> MutantStatus = { _ in .killed }

    private let lock = NSLock()
    private var _events: [String] = []
    private var _timeouts: [TimeInterval] = []
    private var mutantIndex = 0

    var events: [String] { lock.withLock { _events } }
    var timeouts: [TimeInterval] { lock.withLock { _timeouts } }

    private func record(_ event: String) { lock.withLock { _events.append(event) } }

    func runPlainBaseline(progress: ProgressReporter) throws -> TimeInterval {
        record("baseline")
        if let baselineError { throw baselineError }
        return baselineSeconds
    }

    func runCoverageBaseline(progress: ProgressReporter) throws -> CoverageRunResult {
        record("coverage")
        if let coverageError { throw coverageError }
        return coverage
    }

    func prepareMutantRuns(progress: ProgressReporter) throws {
        record("prepare")
    }

    func runMutant(timeout: TimeInterval, progress: ProgressReporter) throws -> MutantRunResult {
        let index = lock.withLock { () -> Int in
            _timeouts.append(timeout)
            defer { mutantIndex += 1 }
            return mutantIndex
        }
        record("mutant \(index)")
        return MutantRunResult(status: try onMutant(index), duration: 0.5)
    }

    func stop() {
        record("stop")
    }
}

/// Signal handling that never touches the process: `deliver` plays the
/// part of a signal, and exit codes are recorded instead of exiting.
final class FakeInterrupts: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var _exitCodes: [Int32] = []
    private var _installs = 0
    private var _uninstalls = 0

    var exitCodes: [Int32] { lock.withLock { _exitCodes } }
    var installs: Int { lock.withLock { _installs } }
    var uninstalls: Int { lock.withLock { _uninstalls } }

    var handling: MutationPipeline.InterruptHandling {
        MutationPipeline.InterruptHandling(
            install: { [self] handler in
                lock.withLock {
                    self.handler = handler
                    _installs += 1
                }
                return { [self] in lock.withLock { _uninstalls += 1 } }
            },
            exit: { [self] code in lock.withLock { _exitCodes.append(code) } }
        )
    }

    func deliver(_ signal: Int32) {
        let handler = lock.withLock { self.handler }
        handler?(signal)
    }
}

/// Interrupt handling that installs nothing (for tests that never signal).
let noInterrupts = MutationPipeline.InterruptHandling(install: { _ in {} }, exit: { _ in })
