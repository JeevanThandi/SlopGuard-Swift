import Foundation
import Testing
@testable import SlopguardCore
@testable import SlopguardMutation

/// A tiny SwiftPM package whose six mutants cover every status a real run
/// can produce: killed, survived, no_coverage, compile_error and ignored.
/// Its tests use swift-testing, so the run works both under Xcode and on a
/// machine with only the Command Line Tools (no XCTest).
private enum CalcFixture {
    static let manifest = """
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "Calc",
        platforms: [.macOS(.v13)],
        targets: [
            .target(name: "Calc"),
            .testTarget(name: "CalcTests", dependencies: ["Calc"])
        ]
    )

    """

    static let source = """
    public enum Calc {
        public static func isAdult(_ age: Int) -> Bool {
            age >= 18
        }

        public static func double(_ x: Int) -> Int {
            x * 2
        }

        public static func untested(_ x: Int) -> Int {
            x - 1
        }

        public static func alwaysSeven() -> Int {
            while true { return 7 }
        }

        public static func increment(_ x: Int) -> Int {
            x + 1 // slopguard-ignore-mutant: covered by another suite
        }
    }

    """

    static let tests = """
    import Testing
    import Calc

    @Test func adults() {
        #expect(Calc.isAdult(30))
        #expect(!Calc.isAdult(17))
    }

    @Test func doubling() {
        #expect(Calc.double(3) == 6)
    }

    @Test func seven() {
        #expect(Calc.alwaysSeven() == 7)
    }

    """
}

/// Runs only where `swift` can build and test a package: skipped under
/// `xcodebuild test` (slopguard's own analyze run) and with SLOPGUARD_SKIP_E2E=1.
private let canRunSwiftPM: Bool = {
    let environment = ProcessInfo.processInfo.environment
    if environment["SLOPGUARD_SKIP_E2E"] == "1" { return false }
    if environment["XCODE_PRODUCT_BUILD_VERSION"] != nil || environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
        return false
    }
    return (try? ProcessGroupCommandRunner.resolveExecutable("swift")) != nil
}()

@Suite("end to end")
struct EndToEndTests {

    @Test("mutate a real package with the real swift test runner",
          .enabled(if: canRunSwiftPM),
          .timeLimit(.minutes(30)))
    func swiftTestRunner() async throws {
        try await withTemporaryDirectory { root in
            // Always a fresh temporary copy — never a checked-in fixture that
            // parallel tests might read while a mutant is in place.
            let package = root.appendingPathComponent("Calc", isDirectory: true)
            try write(CalcFixture.manifest, to: "Package.swift", in: package)
            let source = try write(CalcFixture.source, to: "Sources/Calc/Calc.swift", in: package)
            try write(CalcFixture.tests, to: "Tests/CalcTests/CalcTests.swift", in: package)
            var old = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
            _ = utimensat(AT_FDCWD, source.path, &old, 0)

            let guardRoot = root.appendingPathComponent("guards", isDirectory: true)
            try FileManager.default.createDirectory(at: guardRoot, withIntermediateDirectories: true)
            let pipeline = MutationPipeline(guardRoot: guardRoot, interrupts: noInterrupts)
            let sink = ProgressSink()
            let report = try await pipeline.run(MutationPipeline.Options(sourceURL: package), progress: sink.reporter())

            let statuses = Dictionary(uniqueKeysWithValues: report.mutants.map { ($0.id, $0.status) })
            #expect(statuses == [
                "Sources/Calc/Calc.swift:3:13:boundary": .survived,
                "Sources/Calc/Calc.swift:3:13:negate_conditional": .killed,
                "Sources/Calc/Calc.swift:7:11:arithmetic": .killed,
                "Sources/Calc/Calc.swift:11:11:arithmetic": .noCoverage,
                "Sources/Calc/Calc.swift:15:15:boolean_literal": .compileError,
                "Sources/Calc/Calc.swift:19:11:arithmetic": .ignored
            ], "progress:\n\(sink.messages.joined(separator: "\n"))")
            #expect(report.runner == "swift test")
            #expect(report.projectRoot == package.standardizedFileURL.path)
            #expect(report.coverageAvailable)
            #expect((report.timeoutSeconds ?? 0) >= 60)
            #expect(report.summary.fileCount == 1)   // Package.swift is default-excluded
            #expect(report.summary.mutationScore == 50)
            #expect(report.notes == ["1 mutant(s) did not compile and are excluded from the score."])

            // The source is byte-identical, with its old modification time.
            #expect(try read(source) == CalcFixture.source)
            var info = stat()
            _ = stat(source.path, &info)
            #expect(info.st_mtimespec.tv_sec == 1_600_000_000)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: guardRoot.appendingPathComponent("slopguard-mutate").path)) ?? []).isEmpty)
        }
    }
}
