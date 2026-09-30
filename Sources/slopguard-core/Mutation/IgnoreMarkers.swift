import Foundation

/// The comment marker that switches mutants off. Use it for equivalent
/// mutants — changes with no observable effect, which no test can kill:
///
///     if a > max { // slopguard-ignore-mutant(boundary): equal values assign the same max
///
/// - `slopguard-ignore-mutant` ignores every mutant on its line.
/// - `slopguard-ignore-mutant(boundary,logical)` ignores only those operators
///   (whitespace allowed; unknown ids are dropped).
/// - On a line holding only a comment, the marker applies to the next line.
///
/// Detection is a plain text search of the source lines, like every port.
public enum IgnoreMarkers {

    public static let marker = "slopguard-ignore-mutant"

    /// Whether a line holds only a comment: after leading whitespace it starts
    /// with `//` or `/*`, or with `*` followed by whitespace, `/` or the end of
    /// the line (the inside of a block comment). Any other `*` start is code.
    static func isCommentOnly(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { return true }
        guard trimmed.hasPrefix("*") else { return false }
        guard let next = trimmed.dropFirst().first else { return true }
        return next.isWhitespace || next == "/"
    }

    /// Which operators a marker switches off on one line.
    public enum Scope: Sendable, Equatable {
        case all
        case operators(Set<MutationOperator>)
    }

    /// Ignored operators per 1-based line, from a file's lines (index 0 = line 1).
    public static func parse(lines: [String]) -> [Int: Scope] {
        var map: [Int: Scope] = [:]
        for (index, text) in lines.enumerated() {
            guard let range = text.range(of: marker) else { continue }
            let scope = markerScope(String(text[range.upperBound...]))
            let line = isCommentOnly(text) ? index + 2 : index + 1
            switch (map[line], scope) {
            case (.all?, _), (_, .all):
                map[line] = .all
            case (.operators(let existing)?, .operators(let added)):
                map[line] = .operators(existing.union(added))
            case (nil, .operators(let added)):
                map[line] = .operators(added)
            }
        }
        return map
    }

    public static func isIgnored(_ map: [Int: Scope], line: Int, operator mutationOperator: MutationOperator) -> Bool {
        switch map[line] {
        case nil: return false
        case .all?: return true
        case .operators(let set)?: return set.contains(mutationOperator)
        }
    }

    /// `(a,b)` right after the marker narrows it to those operators.
    private static func markerScope(_ rest: String) -> Scope {
        guard rest.hasPrefix("(") else { return .all }
        let afterParen = rest.dropFirst()
        let body = afterParen.firstIndex(of: ")").map { afterParen[..<$0] } ?? afterParen
        let ids = body
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { MutationOperator(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return .operators(Set(ids))
    }

    /// Split source text into lines where the Swift parser splits them
    /// (`\n`, `\r\n`, `\r`), so marker line numbers match mutant lines.
    public static func lines(of source: String) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        var previousWasCR = false
        for byte in source.utf8 {
            if byte == UInt8(ascii: "\n") {
                if !previousWasCR { lines.append(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
                previousWasCR = false
            } else if byte == UInt8(ascii: "\r") {
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                previousWasCR = true
            } else {
                current.append(byte)
                previousWasCR = false
            }
        }
        lines.append(String(decoding: current, as: UTF8.self))
        return lines
    }
}
