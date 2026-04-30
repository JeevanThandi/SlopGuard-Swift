import Foundation
import Darwin

/// Options controlling how `DirectoryAnalyzer` enumerates files. Globs use `fnmatch`
/// semantics: `*`, `?`, character classes, and pathname matching with `**`-like
/// behavior approximated via the `FNM_PATHNAME` *off* mode (so `*` does match `/`).
public struct AnalysisOptions: Sendable, Hashable, Codable {
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var followSymlinks: Bool

    public init(
        includeGlobs: [String] = [],
        excludeGlobs: [String] = AnalysisOptions.defaultExcludeGlobs,
        followSymlinks: Bool = false
    ) {
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.followSymlinks = followSymlinks
    }

    public static let `default` = AnalysisOptions()

    /// Globs every analyze run filters out unless the caller explicitly opts
    /// in via `--no-default-excludes`. Categories:
    ///
    /// - **Build / dependency dirs** — output of SPM, CocoaPods, Carthage,
    ///   Xcode. Analyzing these is always wrong.
    /// - **Generated code** — codegen tools (SwiftGen, Sourcery, R.swift)
    ///   produce branchy nonsense that swamps real signal.
    /// - **Test / spec code** — Apple `*Tests` convention plus Quick/Nimble
    ///   `*Spec` convention. Test code's CRAP isn't user-facing risk; if you
    ///   genuinely want to inspect test complexity, pass
    ///   `--no-default-excludes`.
    public static let defaultExcludeGlobs: [String] = [
        // Build / dependency dirs
        "**/.build/**",
        "**/Pods/**",
        "**/DerivedData/**",
        "**/.git/**",
        "**/Carthage/**",
        // Generated code
        "**/Generated/**",
        "**/*.generated.swift",
        // Test code (Apple convention)
        "**/*Tests/**",
        "**/*Tests.swift",
        // Test code (Quick / Nimble spec convention)
        "**/*Specs/**",
        "**/*Spec.swift",
        "**/*Specs.swift",
        // Reference fixtures used to benchmark the analyzer itself; deliberately
        // skipped from a top-level scan so they don't pollute dogfood numbers.
        // Pass an explicit `--path SampleApps/...` to analyze them on demand.
        "**/SampleApps/**"
    ]
}

/// Walks a directory tree and analyzes every `.swift` file it finds, in parallel.
public struct DirectoryAnalyzer: Sendable {

    private let analyzer: SwiftFileAnalyzer

    public init(analyzer: SwiftFileAnalyzer = SwiftFileAnalyzer()) {
        self.analyzer = analyzer
    }

    /// Returns one `FileReport` per analyzed file. The `path` on each report is
    /// the path *relative to* `rootURL` (forward-slash, no leading `./`).
    public func analyze(
        rootURL: URL,
        options: AnalysisOptions = .default
    ) async throws -> [FileReport] {
        let (files, rootPrefix) = try resolveFileSet(rootURL: rootURL, options: options)
        let reports = try await analyzeInParallel(files: files, rootPrefix: rootPrefix)
        return reports.sorted { $0.path < $1.path }
    }

    // MARK: - Decomposition

    private func resolveFileSet(rootURL: URL, options: AnalysisOptions) throws -> (files: [URL], rootPrefix: String) {
        let rootPath = rootURL.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir) else {
            throw SlopguardError.fileNotFound(path: rootPath)
        }
        if isDir.boolValue {
            return (try enumerateSwiftFiles(under: rootURL, options: options), rootPath)
        }
        return ([rootURL], rootURL.deletingLastPathComponent().path)
    }

    private func analyzeInParallel(files: [URL], rootPrefix: String) async throws -> [FileReport] {
        let analyzer = self.analyzer
        return try await withThrowingTaskGroup(of: FileReport.self) { group in
            for url in files {
                group.addTask {
                    let absolute = url.standardizedFileURL.path
                    let relative = relativize(absolute, under: rootPrefix)
                    return try analyzer.analyze(url: url, reportedPath: relative)
                }
            }
            var collected: [FileReport] = []
            for try await report in group {
                collected.append(report)
            }
            return collected
        }
    }

    // MARK: - File enumeration

    private func enumerateSwiftFiles(under rootURL: URL, options: AnalysisOptions) throws -> [URL] {
        guard let enumerator = makeEnumerator(at: rootURL, options: options) else {
            throw SlopguardError.unreadableFile(path: rootURL.path, underlying: "Could not enumerate")
        }
        let rootPath = rootURL.standardizedFileURL.path
        var results: [URL] = []
        for case let url as URL in enumerator {
            let relative = relativize(url.standardizedFileURL.path, under: rootPath)
            if isDirectory(url) {
                if matchesAny(options.excludeGlobs, path: relative) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if shouldAnalyze(file: url, relative: relative, options: options) {
                results.append(url)
            }
        }
        return results
    }

    private func makeEnumerator(at rootURL: URL, options: AnalysisOptions) -> FileManager.DirectoryEnumerator? {
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !options.followSymlinks { enumOptions.insert(.skipsPackageDescendants) }
        return FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: enumOptions
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func shouldAnalyze(file url: URL, relative: String, options: AnalysisOptions) -> Bool {
        guard url.pathExtension == "swift" else { return false }
        if matchesAny(options.excludeGlobs, path: relative) { return false }
        if !options.includeGlobs.isEmpty && !matchesAny(options.includeGlobs, path: relative) {
            return false
        }
        return true
    }
}

/// `fnmatch`-based glob matcher. We deliberately *do not* set `FNM_PATHNAME`,
/// so a single `*` matches across path separators — which is the behavior most
/// people expect from `**`-style globs ("everything under .build").
@inline(__always)
private func fnmatchOne(pattern: String, path: String) -> Bool {
    pattern.withCString { p in
        path.withCString { s in
            fnmatch(p, s, 0) == 0
        }
    }
}

/// Match the relative path against each glob, also trying a leading-slash
/// variant. Without this, `**/Foo/**` patterns fail to match a top-level
/// `Foo/Bar.swift` because fnmatch's `*` needs a separator to anchor against —
/// matching gitignore semantics where a leading `**/` is effectively implicit.
private func matchesAny(_ globs: [String], path: String) -> Bool {
    let withSlash = "/" + path
    for g in globs {
        if fnmatchOne(pattern: g, path: path) { return true }
        if fnmatchOne(pattern: g, path: withSlash) { return true }
    }
    return false
}

private func relativize(_ absolute: String, under root: String) -> String {
    if absolute == root { return (absolute as NSString).lastPathComponent }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    if absolute.hasPrefix(prefix) {
        return String(absolute.dropFirst(prefix.count))
    }
    return absolute
}
