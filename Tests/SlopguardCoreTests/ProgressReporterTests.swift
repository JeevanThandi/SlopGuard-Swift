import XCTest
@testable import SlopguardCore

/// ProgressReporter is the stderr side channel for phase markers and
/// (under `--verbose`) raw subprocess passthrough. These tests pin down the
/// verbosity gating: what each level emits, and that the silent reporter
/// truly swallows everything.
final class ProgressReporterTests: XCTestCase {

    /// Collects everything a reporter emits, for assertions.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        private var _rawChunks: [Data] = []

        var messages: [String] { lock.withLock { _messages } }
        var rawChunks: [Data] { lock.withLock { _rawChunks } }

        func message(_ line: String) { lock.withLock { _messages.append(line) } }
        func raw(_ chunk: Data) { lock.withLock { _rawChunks.append(chunk) } }
    }

    private func reporter(_ verbosity: ProgressReporter.Verbosity, sink: Sink) -> ProgressReporter {
        ProgressReporter(
            verbosity: verbosity,
            messageSink: { sink.message($0) },
            rawSink: { sink.raw($0) }
        )
    }

    // MARK: - Phase markers

    func testNormalEmitsPhaseMarkersWithPrefix() {
        let sink = Sink()
        reporter(.normal, sink: sink).phase("running xcodebuild test")
        XCTAssertEqual(sink.messages, ["slopguard: running xcodebuild test"])
    }

    func testVerboseEmitsPhaseMarkers() {
        let sink = Sink()
        reporter(.verbose, sink: sink).phase("walking Sources")
        XCTAssertEqual(sink.messages, ["slopguard: walking Sources"])
    }

    func testSilentSuppressesPhaseMarkers() {
        let sink = Sink()
        reporter(.silent, sink: sink).phase("anything")
        XCTAssertTrue(sink.messages.isEmpty)
    }

    // MARK: - Raw passthrough

    func testVerbosePassesRawBytesThroughVerbatim() {
        let sink = Sink()
        let chunk = Data("Test Suite 'All tests' passed\n".utf8)
        reporter(.verbose, sink: sink).raw(chunk)
        XCTAssertEqual(sink.rawChunks, [chunk])
    }

    func testNormalSuppressesRawBytes() {
        let sink = Sink()
        reporter(.normal, sink: sink).raw(Data("chatter".utf8))
        XCTAssertTrue(sink.rawChunks.isEmpty)
    }

    func testSilentSuppressesRawBytes() {
        let sink = Sink()
        reporter(.silent, sink: sink).raw(Data("chatter".utf8))
        XCTAssertTrue(sink.rawChunks.isEmpty)
    }

    // MARK: - Static factories

    func testSilentReporterIsSilentVerbosity() {
        XCTAssertEqual(ProgressReporter.silent.verbosity, .silent)
        XCTAssertFalse(ProgressReporter.silent.isVerbose)
    }

    func testStderrFactoryDefaultsToNormal() {
        XCTAssertEqual(ProgressReporter.stderr().verbosity, .normal)
    }

    func testIsVerboseOnlyForVerbose() {
        let sink = Sink()
        XCTAssertTrue(reporter(.verbose, sink: sink).isVerbose)
        XCTAssertFalse(reporter(.normal, sink: sink).isVerbose)
        XCTAssertFalse(reporter(.silent, sink: sink).isVerbose)
    }
}
