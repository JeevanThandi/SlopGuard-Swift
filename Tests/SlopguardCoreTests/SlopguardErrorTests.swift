import XCTest
@testable import SlopguardCore

final class SlopguardErrorTests: XCTestCase {

    /// Each variant carries a stable code and a non-empty message that mentions
    /// the parameters it embeds. Walking every case keeps the lookup table honest —
    /// if a new variant is added without a code, this test fails immediately.
    func testEveryVariantHasStableCodeAndMessage() {
        let cases: [(SlopguardError, expectedCode: String, expectInMessage: [String])] = [
            (.fileNotFound(path: "/x"),                                       "file_not_found",          ["/x"]),
            (.notADirectory(path: "/y"),                                      "not_a_directory",         ["/y"]),
            (.unreadableFile(path: "/z", underlying: "EACCES"),               "unreadable_file",         ["/z", "EACCES"]),
            (.parseFailed(path: "/p", underlying: "syntax"),                  "parse_failed",            ["/p", "syntax"]),
            (.xccovUnavailable(reason: "no Xcode"),                           "xccov_unavailable",       ["no Xcode"]),
            (.xccovInvocationFailed(exitCode: 13, stderr: "boom"),            "xccov_invocation_failed", ["13", "boom"]),
            (.xccovDecodeFailed(underlying: "bad json"),                      "xccov_decode_failed",     ["bad json"]),
            (.xcodebuildUnavailable(reason: "no Xcode"),                      "xcodebuild_unavailable",  ["no Xcode"]),
            (.xcodebuildSchemeAmbiguous(schemes: ["A", "B-Package"]),         "xcodebuild_scheme_ambiguous", ["A", "B-Package"]),
            (.xcodebuildSchemeNotFound(projectDirectory: "/q"),               "xcodebuild_scheme_not_found", ["/q"]),
            (.xcodebuildBuildFailed(exitCode: 65, stderr: "compile error"),   "xcodebuild_build_failed", ["65", "compile error"]),
            (.invalidArgument(name: "path", reason: "missing"),               "invalid_argument",        ["path", "missing"]),
            (.unsupported(reason: "no Linux"),                                "unsupported",             ["no Linux"]),
            (.mcpToolError(name: "find_crappy_code", reason: "no report"),    "mcp_tool_error",          ["find_crappy_code", "no report"])
        ]
        for (err, expectedCode, expectInMessage) in cases {
            XCTAssertEqual(err.code, expectedCode, "code mismatch for \(err)")
            for token in expectInMessage {
                XCTAssertTrue(err.message.contains(token), "expected '\(token)' in message of \(err): \(err.message)")
            }
            XCTAssertEqual(err.description, "[\(err.code)] \(err.message)")
        }
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        let env = SlopguardErrorEnvelope(.fileNotFound(path: "/q"))
        let data = try JSONEncoder().encode(env)
        let decoded = try JSONDecoder().decode(SlopguardErrorEnvelope.self, from: data)
        XCTAssertEqual(decoded.code, "file_not_found")
        XCTAssertEqual(decoded.message, env.message)
    }

    func testEnvelopeFromExplicitCodeAndMessage() {
        let env = SlopguardErrorEnvelope(code: "custom", message: "anything")
        XCTAssertEqual(env.code, "custom")
        XCTAssertEqual(env.message, "anything")
    }
}
