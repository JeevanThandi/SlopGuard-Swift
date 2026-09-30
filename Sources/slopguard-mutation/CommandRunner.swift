import Foundation
import Darwin
import SlopguardCore

/// One test-runner invocation: what to launch, where, and which variables to
/// add to the inherited environment.
public struct CommandSpec: Sendable, Equatable {
    /// An absolute path, or a bare name looked up on `PATH` (e.g. `swift`).
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    /// Added to (and overriding) the inherited environment.
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// How one command ended.
public struct CommandOutcome: Sendable, Equatable {
    /// The exit status, or `nil` when a signal ended the process (the timeout kill).
    public var exitCode: Int32?
    public var timedOut: Bool
    /// Wall time in seconds.
    public var duration: TimeInterval
    /// Bounded tail of the combined stdout / stderr.
    public var outputTail: String
    /// Everything the command wrote to stdout — only for `captureStdout` runs.
    public var stdout: Data

    public init(exitCode: Int32?, timedOut: Bool = false, duration: TimeInterval = 0, outputTail: String = "", stdout: Data = Data()) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.duration = duration
        self.outputTail = outputTail
        self.stdout = stdout
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Launches test-runner commands for `mutate`. Injectable so the runners'
/// argument construction and classification can be tested with fakes.
public protocol CommandRunning: Sendable {
    /// Run `spec` to completion, or until `timeout` seconds pass (`nil` = no
    /// limit). Output streams to `progress` under `--verbose`; a bounded tail
    /// is kept either way. With `captureStdout`, stdout is also collected in
    /// full, apart from stderr. A command that cannot be launched throws
    /// `runner_unavailable`.
    func run(_ spec: CommandSpec, timeout: TimeInterval?, captureStdout: Bool, progress: ProgressReporter) throws -> CommandOutcome

    /// Kill the running command's process group, if any, and refuse to start
    /// new commands. Safe to call from a signal handler's queue at any time.
    func stop()
}

extension CommandRunning {
    func run(_ spec: CommandSpec, timeout: TimeInterval?, progress: ProgressReporter) throws -> CommandOutcome {
        try run(spec, timeout: timeout, captureStdout: false, progress: progress)
    }
}

/// Keeps the last `limit` bytes of a subprocess's output (never fewer than the
/// newest chunk), so a failure message can quote the end of the run without
/// holding a whole build log in memory.
struct OutputTail {
    private var chunks: [Data] = []
    private var bytes = 0
    private let limit: Int

    init(limit: Int = 8 * 1024) {
        self.limit = limit
    }

    mutating func append(_ chunk: Data) {
        chunks.append(chunk)
        bytes += chunk.count
        while chunks.count > 1 && bytes > limit {
            bytes -= chunks.removeFirst().count
        }
    }

    var text: String { String(decoding: chunks.reduce(Data(), +), as: UTF8.self) }
}

/// Runs each command in its own process group (`posix_spawn` with
/// `POSIX_SPAWN_SETPGROUP`), so a timeout — or an interrupt — kills the
/// runner and every process it started: an infinite-loop test binary must not
/// be left spinning. The child gets default signal dispositions (slopguard
/// itself ignores SIGINT / SIGTERM / SIGHUP while a run is in progress),
/// `/dev/null` as stdin, and no inherited descriptors besides stdout / stderr.
public final class ProcessGroupCommandRunner: CommandRunning, @unchecked Sendable {

    /// How long to keep reading after the child exits, in case a grandchild
    /// that escaped the group still holds the pipe open.
    private let drainGrace: TimeInterval
    private let lock = NSLock()
    private var activeGroup: pid_t?
    private var stopped = false

    public init(drainGrace: TimeInterval = 2) {
        self.drainGrace = drainGrace
    }

    public func stop() {
        lock.withLock {
            stopped = true
            if let group = activeGroup { _ = kill(-group, SIGKILL) }
        }
    }

    public func run(_ spec: CommandSpec, timeout: TimeInterval?, captureStdout: Bool, progress: ProgressReporter) throws -> CommandOutcome {
        let executable = try Self.resolveExecutable(spec.executable)
        try Self.requireDirectory(spec.workingDirectory)
        let output = try Self.makePipe()
        let stdout: (read: Int32, write: Int32)?
        do {
            stdout = captureStdout ? try Self.makePipe() : nil
        } catch {
            Self.close(output)
            throw error
        }
        let started = DispatchTime.now()
        let pid: pid_t
        do {
            pid = try spawn(executable: executable, spec: spec, output: output.write, stdout: stdout?.write ?? output.write)
        } catch {
            Self.close(output)
            if let stdout { Self.close(stdout) }
            throw error
        }
        Darwin.close(output.write)
        if let stdout { Darwin.close(stdout.write) }

        var watch = ChildWatch(pid: pid, started: started, timeout: timeout, drainGrace: drainGrace, progress: progress)
        watch.readers.append(ChildWatch.Reader(fd: output.read, isStdout: false))
        if let stdout { watch.readers.append(ChildWatch.Reader(fd: stdout.read, isStdout: true)) }
        defer { for reader in watch.readers { Darwin.close(reader.fd) } }
        watch.runToCompletion()

        lock.withLock { activeGroup = nil }
        if watch.timedOut { _ = kill(-pid, SIGKILL) }   // stragglers in the group
        return watch.outcome
    }

    // MARK: - Spawning


    private func spawn(executable: String, spec: CommandSpec, output: Int32, stdout: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = child pid), default signal handling, empty
        // signal mask, and only the descriptors set up above.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in spec.environment { environment[key] = value }
        let argv = ([executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        guard lock.withLock({ !stopped }) else {
            throw SlopguardError.runnerUnavailable(reason: "the run was interrupted")
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw SlopguardError.runnerUnavailable(
                reason: "could not launch \(executable): \(String(cString: strerror(result)))"
            )
        }
        lock.withLock {
            activeGroup = pid
            if stopped { _ = kill(-pid, SIGKILL) }
        }
        return pid
    }

    /// `swift` → the first executable `swift` on `PATH`; paths pass through.
    static func resolveExecutable(_ name: String) throws -> String {
        if name.contains("/") { return name }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw SlopguardError.runnerUnavailable(reason: "could not find `\(name)` on PATH")
    }

    private static func requireDirectory(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SlopguardError.fileNotFound(path: path)
        }
    }

    private static func close(_ pipe: (read: Int32, write: Int32)) {
        Darwin.close(pipe.read)
        Darwin.close(pipe.write)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw SlopguardError.runnerUnavailable(reason: "could not create a pipe: \(String(cString: strerror(errno)))")
        }
        return (fds[0], fds[1])
    }

    /// The exit code of a normal exit, or `nil` when a signal ended the process.
    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : nil
    }
}

/// Waits for one spawned child: reads its pipes (keeping the output tail,
/// streaming under `--verbose`), reaps it, and kills its process group once
/// the timeout passes. After the child exits, reading continues for
/// `drainGrace` seconds at most, in case a process that left the group still
/// holds a pipe open.
struct ChildWatch {

    struct Reader {
        let fd: Int32
        let isStdout: Bool
        var done = false
    }

    let pid: pid_t
    let started: DispatchTime
    let timeout: TimeInterval?
    let drainGrace: TimeInterval
    let progress: ProgressReporter
    var readers: [Reader] = []

    private(set) var timedOut = false
    private var status: Int32 = 0
    private var exitedAt: DispatchTime?
    private var tail = OutputTail()
    private var stdout = Data()
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(pid: pid_t, started: DispatchTime, timeout: TimeInterval?, drainGrace: TimeInterval, progress: ProgressReporter) {
        self.pid = pid
        self.started = started
        self.timeout = timeout
        self.drainGrace = drainGrace
        self.progress = progress
    }

    var outcome: CommandOutcome {
        CommandOutcome(
            exitCode: ProcessGroupCommandRunner.exitCode(fromWaitStatus: status),
            timedOut: timedOut,
            duration: Self.seconds(since: started),
            outputTail: tail.text,
            stdout: stdout
        )
    }

    mutating func runToCompletion() {
        while !isFinished() {
            enforceTimeout()
            readAvailableOutput()
        }
    }

    /// Reap the child if it has exited; finished once it is reaped and its
    /// pipes are drained (or the drain grace ran out).
    private mutating func isFinished() -> Bool {
        if exitedAt == nil, reap() { exitedAt = .now() }
        guard let exitedAt else { return false }
        return readers.allSatisfy(\.done) || Self.seconds(since: exitedAt) > drainGrace
    }

    private mutating func reap() -> Bool {
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid || (result == -1 && errno == ECHILD)
    }

    private mutating func enforceTimeout() {
        guard exitedAt == nil, !timedOut, let timeout, Self.seconds(since: started) > timeout else { return }
        timedOut = true
        _ = kill(-pid, SIGKILL)
    }

    /// Wait up to 50 ms for output, then read whatever is ready.
    private mutating func readAvailableOutput() {
        let open = readers.indices.filter { !readers[$0].done }
        guard !open.isEmpty else {
            usleep(20_000)
            return
        }
        var fds = open.map { pollfd(fd: readers[$0].fd, events: Int16(POLLIN), revents: 0) }
        guard poll(&fds, nfds_t(fds.count), 50) > 0 else { return }
        for (slot, index) in open.enumerated() where fds[slot].revents != 0 {
            read(index)
        }
    }

    private mutating func read(_ index: Int) {
        let count = Darwin.read(readers[index].fd, &buffer, buffer.count)
        guard count > 0 else {
            if count == 0 || (errno != EINTR && errno != EAGAIN) { readers[index].done = true }
            return
        }
        let chunk = Data(buffer[0..<count])
        tail.append(chunk)
        progress.raw(chunk)
        if readers[index].isStdout { stdout.append(chunk) }
    }

    private static func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
