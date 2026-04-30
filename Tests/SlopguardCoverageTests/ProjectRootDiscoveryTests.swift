import XCTest
@testable import SlopguardCoverage

final class ProjectRootDiscoveryTests: XCTestCase {

    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopguard-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    /// A `Package.swift` sibling at the search start is the simplest match
    /// — no climbing required.
    func testDiscoversPackageSwiftAtStart() throws {
        try touch(workspace.appendingPathComponent("Package.swift"))
        let result = ProjectRootDiscovery.discover(searchingFrom: workspace)
        XCTAssertEqual(result.standardizedFileURL.path, workspace.standardizedFileURL.path)
    }

    /// Walking up from `Sources/Foo` should find `Package.swift` at the
    /// project root — the common "I analyzed a subdir" case.
    func testWalksUpToFindPackageSwift() throws {
        try touch(workspace.appendingPathComponent("Package.swift"))
        let nested = workspace.appendingPathComponent("Sources/Foo", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = ProjectRootDiscovery.discover(searchingFrom: nested)
        XCTAssertEqual(result.standardizedFileURL.path, workspace.standardizedFileURL.path)
    }

    /// `.xcodeproj` siblings should also count as a project root, even
    /// without a Package.swift — this is the "Xcode app" case.
    func testRecognisesXcodeprojDirectory() throws {
        let xcodeproj = workspace.appendingPathComponent("MyApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let nested = workspace.appendingPathComponent("MyApp/Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let result = ProjectRootDiscovery.discover(searchingFrom: nested)
        XCTAssertEqual(result.standardizedFileURL.path, workspace.standardizedFileURL.path)
    }

    func testRecognisesXcworkspaceDirectory() throws {
        let xcworkspace = workspace.appendingPathComponent("MyApp.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: xcworkspace, withIntermediateDirectories: true)

        let result = ProjectRootDiscovery.discover(searchingFrom: workspace)
        XCTAssertEqual(result.standardizedFileURL.path, workspace.standardizedFileURL.path)
    }

    /// When two markers exist at different levels, the *nearest* (deepest)
    /// wins — that's the user's actual project boundary, not whatever
    /// happens to be further up the filesystem.
    func testPicksNearestMarkerWhenNested() throws {
        try touch(workspace.appendingPathComponent("Package.swift"))
        let nestedRoot = workspace.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        try touch(nestedRoot.appendingPathComponent("Package.swift"))

        let inner = nestedRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let result = ProjectRootDiscovery.discover(searchingFrom: inner)
        XCTAssertEqual(result.standardizedFileURL.path, nestedRoot.standardizedFileURL.path)
    }

    /// Source-file inputs must walk from the parent dir, not from the file
    /// itself (markers are siblings, not children, of files).
    func testStartsFromContainingDirWhenInputIsAFile() throws {
        try touch(workspace.appendingPathComponent("Package.swift"))
        let file = workspace.appendingPathComponent("Sources/Foo.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try touch(file)

        let result = ProjectRootDiscovery.discover(searchingFrom: file)
        XCTAssertEqual(result.standardizedFileURL.path, workspace.standardizedFileURL.path)
    }

    /// No marker anywhere → fall back to the input directory rather than
    /// throw. Downstream `xcodebuild` will surface its own error if that
    /// directory isn't actually buildable.
    func testFallsBackToInputWhenNoMarkerFound() throws {
        let isolated = workspace.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)

        let result = ProjectRootDiscovery.discover(searchingFrom: isolated)
        XCTAssertEqual(result.standardizedFileURL.path, isolated.standardizedFileURL.path)
    }

    // MARK: - Helpers

    private func touch(_ url: URL) throws {
        try Data().write(to: url)
    }
}
