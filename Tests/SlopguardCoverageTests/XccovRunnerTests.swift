import XCTest
@testable import SlopguardCoverage
import SlopguardCore

final class XccovRunnerTests: XCTestCase {

    /// `runReport` validates the input path before launching the subprocess —
    /// the most common runtime mistake (typo in the xcresult arg). Worth a
    /// fast unit test instead of relying on integration.
    func testMissingXcresultThrowsFileNotFound() async {
        let bogus = URL(fileURLWithPath: "/no/such/path.xcresult")
        do {
            _ = try await XccovRunner().runReport(xcresultURL: bogus)
            XCTFail("expected fileNotFound")
        } catch let SlopguardError.fileNotFound(path) {
            XCTAssertTrue(path.contains("no/such/path.xcresult"))
        } catch {
            XCTFail("expected SlopguardError.fileNotFound, got \(error)")
        }
    }

    /// Decode helper is pure — feed it the JSON we already use as a fixture.
    func testDecodeAcceptsValidPayload() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample.xccov", withExtension: "json", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        let report = try XccovRunner.decode(data: data)
        XCTAssertEqual(report.targets.first?.files.count, 2)
    }

    func testDecodeRejectsGarbage() {
        let bad = Data("{ this is not json }".utf8)
        XCTAssertThrowsError(try XccovRunner.decode(data: bad)) { err in
            guard case SlopguardError.xccovDecodeFailed = err else {
                XCTFail("expected xccovDecodeFailed, got \(err)")
                return
            }
        }
    }

    /// xccov's "No coverage data in result bundle" is the signature slopguard
    /// has to special-case — the same stderr covers both "no tests ran" and
    /// "tests ran with coverage suppressed", so the runner emits a typed
    /// `coverageDataMissing` and lets the pipeline disambiguate.
    func testMapFailureRecognisesNoCoverageDataStderr() {
        let stderr = "Error: Error Domain=XCCovErrorDomain Code=0 \"No coverage data in result bundle\""
        let mapped = XccovRunner.mapFailure(exitCode: 1, stderr: stderr)
        guard case .coverageDataMissing(let reason) = mapped else {
            return XCTFail("expected coverageDataMissing, got \(mapped)")
        }
        guard case .coverageNotGathered(let count) = reason else {
            return XCTFail("runner alone can't probe — expected coverageNotGathered(nil), got \(reason)")
        }
        XCTAssertNil(count)
    }

    func testMapFailureIsCaseInsensitive() {
        let stderr = "no COVERAGE Data anywhere"
        let mapped = XccovRunner.mapFailure(exitCode: 2, stderr: stderr)
        guard case .coverageDataMissing = mapped else {
            return XCTFail("expected coverageDataMissing, got \(mapped)")
        }
    }

    /// Anything that doesn't match the no-coverage signature must keep its
    /// generic shape so the user still sees the raw xccov stderr.
    func testMapFailureFallsThroughForOtherStderr() {
        let mapped = XccovRunner.mapFailure(exitCode: 1, stderr: "Some other xccov failure")
        guard case .xccovInvocationFailed(let exit, let stderr) = mapped else {
            return XCTFail("expected xccovInvocationFailed, got \(mapped)")
        }
        XCTAssertEqual(exit, 1)
        XCTAssertEqual(stderr, "Some other xccov failure")
    }
}
