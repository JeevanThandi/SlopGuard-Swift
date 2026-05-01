import Foundation

/// Walks up from a source URL looking for a Swift project root marker
/// (`Package.swift`, an `.xcodeproj`, or an `.xcworkspace`). The result is
/// where `xcodebuild test` should run from when the user hasn't explicitly
/// said otherwise.
///
/// Treating the analyzed source URL as a hint to find the *real* project
/// root means `slopguard-swift analyze --path Sources` runs xcodebuild
/// against the package whose `Sources/` folder that is, not against
/// whatever the current working directory happens to be.
public enum ProjectRootDiscovery {

    /// File / directory names that mark a Swift project root. Order matters
    /// only as documentation — any single match wins.
    static let markers: [String] = [
        "Package.swift"
    ]

    /// Suffixes that mark a Swift project root when present as a child
    /// directory (e.g. `MyApp.xcodeproj`, `MyApp.xcworkspace`).
    static let markerSuffixes: [String] = [
        ".xcodeproj",
        ".xcworkspace"
    ]

    /// Find the nearest project root at or above `searchingFrom`. Walks up
    /// the filesystem, stopping at the first directory containing any
    /// marker. If `searchingFrom` is a file, the search starts at its
    /// parent directory. Returns `searchingFrom`'s nearest existing
    /// directory when nothing is found — callers downstream (`xcodebuild`)
    /// will surface their own error if the path isn't actually buildable.
    public static func discover(searchingFrom url: URL) -> URL {
        let fileManager = FileManager.default
        var dir = url.standardizedFileURL

        // If the input is a file, climb to its containing directory before
        // starting the walk — markers are siblings, not children, of source
        // files.
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }

        let fallback = dir
        // Cap the climb at root ("/") to avoid an infinite loop on broken
        // filesystems / sandboxed paths. Real project trees are nowhere
        // near 64 levels deep.
        for _ in 0..<64 {
            if hasMarker(dir, fileManager: fileManager) {
                return dir
            }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            if parent.path == dir.path { break }
            dir = parent
        }
        return fallback
    }

    private static func hasMarker(_ dir: URL, fileManager: FileManager) -> Bool {
        for marker in markers {
            if fileManager.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                return true
            }
        }
        // Suffix markers are directories — list the parent and look for any
        // child whose name ends in the suffix. We cap at the first hit.
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        for entry in entries {
            for suffix in markerSuffixes where entry.hasSuffix(suffix) {
                return true
            }
        }
        return false
    }
}
