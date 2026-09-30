import Foundation
import Darwin
import Testing
@testable import SlopguardCore
@testable import SlopguardMutation

private struct BodyFailure: Error {}

/// A project directory with one source file, plus a separate guard root.
private struct Fixture {
    let project: URL
    let guardRoot: URL
    let file: URL
    let original = "let answer = 6 * 7\n"
    let mutant = "let answer = 6 / 7\n"

    init(_ root: URL) throws {
        project = root.appendingPathComponent("project", isDirectory: true)
        guardRoot = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: guardRoot, withIntermediateDirectories: true)
        file = try write(original, to: "Sources/Answer.swift", in: project)
    }

    var guardDirectory: URL {
        WorkspaceGuard.guardDirectory(projectRoot: project.path, temporaryRoot: guardRoot)
    }

    func acquire(pid: Int32 = 4242, isAlive: (Int32) -> Bool = { _ in false }) throws -> WorkspaceGuard {
        try WorkspaceGuard.acquire(projectRoot: project.path, temporaryRoot: guardRoot, pid: pid, isAlive: isAlive)
    }

    /// Leave the guard files an interrupted run would leave behind.
    func leaveInterruptedRun(pid: Int32, fileContents: String?, backup: String?) throws {
        let directory = guardDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("\(pid)".utf8).write(to: directory.appendingPathComponent("lock"))
        let journal = #"{"file":"\#(file.path)","mutantSha256":"\#(WorkspaceGuard.sha256Hex(Data(mutant.utf8)))"}"#
        try Data(journal.utf8).write(to: directory.appendingPathComponent("journal.json"))
        if let backup { try Data(backup.utf8).write(to: directory.appendingPathComponent("original")) }
        if let fileContents { try Data(fileContents.utf8).write(to: file) }
    }

    func guardFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: guardDirectory.path)) ?? []).sorted()
    }
}

private func fileInfo(_ url: URL) -> stat {
    var info = stat()
    _ = stat(url.path, &info)
    return info
}

@Suite("workspace guard")
struct WorkspaceGuardTests {

    @Test("the guard directory hashes the real project path and lives outside the project")
    func directory() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.project)
            let viaLink = WorkspaceGuard.guardDirectory(projectRoot: link.path, temporaryRoot: fixture.guardRoot)
            #expect(viaLink == fixture.guardDirectory)
            let expectedHash = String(WorkspaceGuard.sha256Hex(Data(fixture.project.path.utf8)).prefix(16))
            #expect(fixture.guardDirectory.path == fixture.guardRoot.path + "/slopguard-mutate/" + expectedHash)
            #expect(!fixture.guardDirectory.path.hasPrefix(fixture.project.path))
        }
    }

    @Test("a live holder blocks a second run with mutation_in_progress")
    func lockExclusivity() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let first = try fixture.acquire(pid: 1111)
            #expect(fixture.guardFiles() == ["lock"])
            #expect(try read(fixture.guardDirectory.appendingPathComponent("lock")) == "1111")
            do {
                _ = try fixture.acquire(pid: 2222, isAlive: { $0 == 1111 })
                Issue.record("expected mutation_in_progress")
            } catch let error as SlopguardError {
                #expect(error.code == "mutation_in_progress")
                #expect(error.message == "Another slopguard mutate run (pid 1111) is using \(fixture.project.path).")
            }
            try first.release()
            #expect(!FileManager.default.fileExists(atPath: fixture.guardDirectory.path), "release removes the empty guard directory")
            let second = try fixture.acquire(pid: 2222, isAlive: { $0 == 1111 })
            try second.release()
        }
    }

    @Test("a stale lock without a journal is simply taken over")
    func staleLockWithoutJournal() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            try FileManager.default.createDirectory(at: fixture.guardDirectory, withIntermediateDirectories: true)
            try Data("999999".utf8).write(to: fixture.guardDirectory.appendingPathComponent("lock"))
            let taken = try fixture.acquire(pid: 3333)
            #expect(taken.notes.isEmpty)
            #expect(try read(fixture.guardDirectory.appendingPathComponent("lock")) == "3333")
            try taken.release()
        }
    }

    @Test("recovery: a file that still holds the journal's mutant is restored")
    func recoveryRestores() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            try fixture.leaveInterruptedRun(pid: 999_999, fileContents: fixture.mutant, backup: fixture.original)
            let recovered = try fixture.acquire()
            #expect(try read(fixture.file) == fixture.original)
            #expect(recovered.notes == ["Restored \(fixture.file.path), which an interrupted mutate run left mutated."])
            #expect(fixture.guardFiles() == ["lock"])
            try recovered.release()
        }
    }

    @Test("recovery: a file that changed since is left alone and the backup is kept")
    func recoveryKeepsBackup() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let edited = "let answer = 42 // edited by hand\n"
            try fixture.leaveInterruptedRun(pid: 999_999, fileContents: edited, backup: fixture.original)
            let recovered = try fixture.acquire()
            #expect(try read(fixture.file) == edited)
            let kept = try #require(fixture.guardFiles().first { $0.hasPrefix("original-") })
            let keptPath = fixture.guardDirectory.appendingPathComponent(kept)
            #expect(try read(keptPath) == fixture.original)
            #expect(recovered.notes == [
                "An interrupted mutate run left a backup of \(fixture.file.path) at \(keptPath.path). " +
                    "The file has changed since, so it was not restored."
            ])
            try recovered.release()
            #expect(fixture.guardFiles() == [kept])
        }
    }

    @Test("recovery: an already-restored file needs no note; a missing backup is reported")
    func recoveryEdgeCases() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            try fixture.leaveInterruptedRun(pid: 999_999, fileContents: fixture.original, backup: fixture.original)
            let clean = try fixture.acquire()
            #expect(clean.notes.isEmpty)
            try clean.release()

            try fixture.leaveInterruptedRun(pid: 999_999, fileContents: fixture.mutant, backup: nil)
            let missing = try fixture.acquire()
            #expect(missing.notes == [
                "An interrupted mutate run left \(fixture.file.path) mutated and its backup is missing. " +
                    "Restore the file from version control."
            ])
            try missing.release()
        }
    }

    @Test("a mutant is journaled and backed up while in place, then restored with inode, mode, links and times")
    func withMutantRestores() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let hardLink = root.appendingPathComponent("hardlink.swift")
            try FileManager.default.linkItem(at: fixture.file, to: hardLink)
            chmod(fixture.file.path, 0o640)
            var old = [timespec(tv_sec: 1_000_000_000, tv_nsec: 123_456_000), timespec(tv_sec: 1_100_000_000, tv_nsec: 654_321_000)]
            #expect(utimensat(AT_FDCWD, fixture.file.path, &old, 0) == 0)
            let before = fileInfo(fixture.file)

            let workspaceGuard = try fixture.acquire()
            let seen = try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) { () -> String in
                let journal = try read(fixture.guardDirectory.appendingPathComponent("journal.json"))
                #expect(journal.contains(WorkspaceGuard.sha256Hex(Data(fixture.mutant.utf8))))
                #expect(journal.contains("\"file\":\"\(fixture.file.path)\""))
                #expect(try read(fixture.guardDirectory.appendingPathComponent("original")) == fixture.original)
                #expect(try read(hardLink) == fixture.mutant)
                return try read(fixture.file)
            }
            #expect(seen == fixture.mutant)

            let after = fileInfo(fixture.file)
            #expect(try read(fixture.file) == fixture.original)
            #expect(try read(hardLink) == fixture.original)
            #expect(after.st_ino == before.st_ino)
            #expect(after.st_mode == before.st_mode)
            #expect(after.st_mtimespec.tv_sec == 1_100_000_000 && after.st_mtimespec.tv_nsec == 654_321_000)
            #expect(after.st_atimespec.tv_sec == 1_000_000_000 && after.st_atimespec.tv_nsec == 123_456_000)
            #expect(fixture.guardFiles() == ["lock", "original"])
            try workspaceGuard.release()
            #expect(fixture.guardFiles().isEmpty)
        }
    }

    @Test("a file edited since planning gets no mutant: FileChanged, and nothing is written")
    func changedFile() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let workspaceGuard = try fixture.acquire()
            let edited = "let answer = 42 // edited during the run\n"
            try Data(edited.utf8).write(to: fixture.file)
            #expect(throws: WorkspaceGuard.FileChanged(path: fixture.file.path)) {
                try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) {
                    Issue.record("the body must not run for a changed file")
                }
            }
            #expect(try read(fixture.file) == edited)
            #expect(!fixture.guardFiles().contains("journal.json"))
            try workspaceGuard.release()
            #expect(try read(fixture.file) == edited)
        }
    }

    @Test("a thrown error still restores the original, and the error propagates")
    func restoreOnThrownError() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let workspaceGuard = try fixture.acquire()
            #expect(throws: BodyFailure.self) {
                try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) {
                    #expect(try read(fixture.file) == fixture.mutant)
                    throw BodyFailure()
                }
            }
            #expect(try read(fixture.file) == fixture.original)
            #expect(!fixture.guardFiles().contains("journal.json"))
            try workspaceGuard.release()
        }
    }

    @Test("release is idempotent, restores a mutant left in place, and ends the guard")
    func releaseEndsTheGuard() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let workspaceGuard = try fixture.acquire()
            #expect(try workspaceGuard.restore() == nil)
            // The signal handler's path: restore + release while a mutant is in place.
            try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) {
                #expect(try workspaceGuard.restore() == fixture.file.path)
                try workspaceGuard.release()
                #expect(try read(fixture.file) == fixture.original)
            }
            try workspaceGuard.release()
            #expect(fixture.guardFiles().isEmpty)
            #expect(throws: SlopguardError.self) {
                try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) {}
            }
            #expect(try read(fixture.file) == fixture.original)
        }
    }

    @Test("a failed restore throws restore_failed naming the file and the backup, and keeps the lock")
    func restoreFailure() throws {
        try withTemporaryDirectory { root in
            let fixture = try Fixture(root)
            let workspaceGuard = try fixture.acquire()
            do {
                try workspaceGuard.withMutant(file: fixture.file.path, planned: Data(fixture.original.utf8), mutated: Data(fixture.mutant.utf8)) {
                    // Make the restore impossible: the file is gone.
                    try FileManager.default.removeItem(at: fixture.file)
                }
                Issue.record("expected restore_failed")
            } catch let error as SlopguardError {
                #expect(error.code == "restore_failed")
                #expect(error.message.contains(fixture.file.path))
                #expect(error.message.contains(fixture.guardDirectory.appendingPathComponent("original").path))
            }
            #expect(throws: SlopguardError.self) { try workspaceGuard.release() }
            #expect(fixture.guardFiles() == ["journal.json", "lock", "original"])
        }
    }
}
