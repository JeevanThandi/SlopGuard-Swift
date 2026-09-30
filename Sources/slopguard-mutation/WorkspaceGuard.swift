import Foundation
import Darwin
import CryptoKit
import SlopguardCore

/// Keeps in-place mutation safe. `mutate` edits one source file at a time, and
/// the guard makes sure the original always comes back:
///
/// - Before a file's first mutant, its bytes and atime / mtime are kept in
///   memory and its bytes are backed up to `original` in the guard directory.
///   Before each mutant, `journal.json` names the file and the mutant's
///   sha256. After the test run the original bytes and timestamps are written
///   back (truncate + write, so the inode, mode and hard links survive) and
///   the journal is deleted.
/// - A `lock` file (exclusive create, holding the pid) allows one run per
///   project. A lock whose pid is dead belongs to an interrupted run: its
///   journal is used to restore the file — but only when the file still holds
///   exactly that mutant, so later edits are never overwritten.
/// - Immediately before each mutant is written, the file must still hold the
///   bytes the mutants were planned from. When someone edited it during the
///   run, nothing is written and `FileChanged` is thrown, so neither the stale
///   mutant nor the restore overwrites the edit.
///
/// The guard directory is `<temp dir>/slopguard-mutate/<16 hex of sha256(real
/// project path)>`, never inside the project, and has the same layout in every
/// slopguard port. All state changes happen under one lock, so the signal
/// handler can restore while a mutant run is in flight.
public final class WorkspaceGuard: @unchecked Sendable {

    static let lockName = "lock"
    static let journalName = "journal.json"
    static let originalName = "original"

    public let directory: URL
    /// Plain-sentence notes from recovering an interrupted run.
    public let notes: [String]

    /// Thrown by `withMutant` when the file no longer holds the bytes the
    /// mutants were planned from. Nothing was written.
    public struct FileChanged: Error, Equatable {
        public let path: String
    }

    private struct CurrentFile {
        let path: String
        let original: Data
        let accessTime: timespec
        let modificationTime: timespec
    }

    private let lock = NSLock()
    private var current: CurrentFile?
    private var mutated = false
    private var released = false

    private init(directory: URL, notes: [String]) {
        self.directory = directory
        self.notes = notes
    }

    // MARK: - Acquire

    /// Take the project's lock, recovering an interrupted run's leftovers when
    /// the previous holder is dead. Throws `mutation_in_progress` when a live
    /// process holds it.
    public static func acquire(
        projectRoot: String,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = WorkspaceGuard.processIsAlive
    ) throws -> WorkspaceGuard {
        let directory = guardDirectory(projectRoot: projectRoot, temporaryRoot: temporaryRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(lockName).path
        if try tryLock(lockPath, pid: pid) { return WorkspaceGuard(directory: directory, notes: []) }

        let holder = readPid(lockPath)
        if let holder, holder != pid, isAlive(holder) {
            throw SlopguardError.mutationInProgress(pid: holder, projectRoot: projectRoot)
        }
        let notes = recoverInterruptedRun(in: directory)
        try? FileManager.default.removeItem(atPath: lockPath)
        if try tryLock(lockPath, pid: pid) { return WorkspaceGuard(directory: directory, notes: notes) }
        // Another run took the lock between the stale-lock cleanup and the retry.
        throw SlopguardError.mutationInProgress(pid: readPid(lockPath) ?? 0, projectRoot: projectRoot)
    }

    /// `<temporaryRoot>/slopguard-mutate/<first 16 hex chars of sha256(real project path)>`.
    public static func guardDirectory(projectRoot: String, temporaryRoot: URL = FileManager.default.temporaryDirectory) -> URL {
        let real = LineCoverageIndex.canonicalPath(projectRoot)
        let hash = sha256Hex(Data(real.utf8)).prefix(16)
        return temporaryRoot
            .appendingPathComponent("slopguard-mutate", isDirectory: true)
            .appendingPathComponent(String(hash), isDirectory: true)
    }

    /// Whether `pid` names a live process (EPERM: alive, owned by another user).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Mutants

    /// Write `mutated` into `file`, run `body`, and restore the original —
    /// whatever `body` does. The file is backed up before its first mutant.
    /// When the file no longer holds `planned` (the bytes the mutants were
    /// planned from), nothing is written and `FileChanged` is thrown.
    /// A failed restore throws `restore_failed`, which wins over `body`'s error.
    public func withMutant<T>(file: String, planned: Data, mutated bytes: Data, body: () throws -> T) throws -> T {
        let outcome: Result<T, Error>
        do {
            try lock.withLock {
                guard !released else {
                    throw SlopguardError.runnerUnavailable(reason: "the run was interrupted")
                }
                if current?.path != file { try begin(file) }
                // Changed-file guard, in the same locked step as the write.
                guard (try? Data(contentsOf: URL(fileURLWithPath: file))) == planned else {
                    throw FileChanged(path: file)
                }
                try writeAtomically(
                    Self.journalData(file: file, mutantSha256: Self.sha256Hex(bytes)),
                    to: directory.appendingPathComponent(Self.journalName)
                )
                mutated = true
                try Self.writeInPlace(bytes, to: file)
            }
            outcome = .success(try body())
        } catch {
            outcome = .failure(error)
        }
        _ = try restore()
        return try outcome.get()
    }

    /// Put the original back if a mutant is in place. Returns the restored
    /// path, or `nil` when nothing was mutated.
    @discardableResult
    public func restore() throws -> String? {
        try lock.withLock { try restoreLocked() }
    }

    /// Restore anything mutated, then delete the journal, the backup, the
    /// lock and — when nothing else is left in it, such as a kept recovery
    /// backup — the guard directory. Idempotent. When the restore fails the
    /// files stay, so the next run's recovery can still put the original back.
    public func release() throws {
        try lock.withLock {
            if released { return }
            _ = try restoreLocked()
            released = true
            for name in [Self.journalName, Self.originalName, Self.lockName] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
            _ = rmdir(directory.path)   // only succeeds when empty
        }
    }

    private func begin(_ file: String) throws {
        _ = try restoreLocked()
        // Take the timestamps before reading: the read itself can move atime.
        var info = stat()
        guard stat(file, &info) == 0 else {
            throw SlopguardError.unreadableFile(path: file, underlying: String(cString: strerror(errno)))
        }
        let original: Data
        do {
            original = try Data(contentsOf: URL(fileURLWithPath: file))
        } catch {
            throw SlopguardError.unreadableFile(path: file, underlying: "\(error)")
        }
        try writeAtomically(original, to: directory.appendingPathComponent(Self.originalName))
        current = CurrentFile(
            path: file,
            original: original,
            accessTime: info.st_atimespec,
            modificationTime: info.st_mtimespec
        )
    }

    private func restoreLocked() throws -> String? {
        guard let current, mutated else { return nil }
        do {
            try Self.writeInPlace(current.original, to: current.path)
            try Self.setTimes(current.path, access: current.accessTime, modification: current.modificationTime)
        } catch {
            throw SlopguardError.restoreFailed(
                path: current.path,
                backupPath: directory.appendingPathComponent(Self.originalName).path,
                underlying: "\(error)"
            )
        }
        mutated = false
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.journalName))
        return current.path
    }

    // MARK: - Recovery

    private struct Journal: Codable {
        let file: String
        let mutantSha256: String
    }

    /// Undo what an interrupted run left behind. Returns notes for the report.
    static func recoverInterruptedRun(in directory: URL) -> [String] {
        let journalURL = directory.appendingPathComponent(journalName)
        let backupURL = directory.appendingPathComponent(originalName)
        var notes: [String] = []
        if let data = try? Data(contentsOf: journalURL),
           let journal = try? JSONDecoder().decode(Journal.self, from: data) {
            notes = recoverFile(journal, backupURL: backupURL, directory: directory)
        }
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: backupURL)
        return notes
    }

    private static func recoverFile(_ journal: Journal, backupURL: URL, directory: URL) -> [String] {
        let current = try? Data(contentsOf: URL(fileURLWithPath: journal.file))
        let backup = try? Data(contentsOf: backupURL)
        let holdsMutant = current.map { sha256Hex($0) == journal.mutantSha256 } ?? false
        guard let backup else {
            return holdsMutant
                ? ["An interrupted mutate run left \(journal.file) mutated and its backup is missing. Restore the file from version control."]
                : []
        }
        if holdsMutant, (try? writeInPlace(backup, to: journal.file)) != nil {
            return ["Restored \(journal.file), which an interrupted mutate run left mutated."]
        }
        if current == backup { return [] }
        let kept = directory.appendingPathComponent("original-\(Int(Date().timeIntervalSince1970 * 1000))")
        guard (try? FileManager.default.moveItem(at: backupURL, to: kept)) != nil else { return [] }
        if holdsMutant {
            return [
                "An interrupted mutate run left \(journal.file) mutated, and writing the original back failed. " +
                    "The original is at \(kept.path)."
            ]
        }
        return [
            "An interrupted mutate run left a backup of \(journal.file) at \(kept.path). " +
                "The file has changed since, so it was not restored."
        ]
    }

    // MARK: - File helpers

    /// Exclusive-create the lock and write our pid. `false` when it exists.
    private static func tryLock(_ path: String, pid: Int32) throws -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw SlopguardError.unreadableFile(path: path, underlying: String(cString: strerror(errno)))
        }
        defer { close(fd) }
        try writeAll(Data("\(pid)".utf8), to: fd, path: path)
        return true
    }

    private static func readPid(_ path: String) -> Int32? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber) else { return nil }
        return Int32(text)
    }

    /// Truncate and rewrite `path` in place: the inode, mode and hard links
    /// survive, unlike a write-to-temp-and-rename.
    static func writeInPlace(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        try writeAll(data, to: fd, path: path)
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(path)
                }
                offset += written
            }
        }
    }

    private static func setTimes(_ path: String, access: timespec, modification: timespec) throws {
        var times = [access, modification]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw posixError(path) }
    }

    /// Write via a temp file and rename, so a crash never leaves a half-written file.
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else { throw Self.posixError(url.path) }
    }

    private static func journalData(file: String, mutantSha256: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Journal(file: file, mutantSha256: mutantSha256))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func posixError(_ path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(path): \(String(cString: strerror(errno)))"]
        )
    }
}
