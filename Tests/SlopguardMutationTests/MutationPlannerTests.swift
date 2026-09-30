import Foundation
import Testing
@testable import SlopguardCore

@Suite("ignore markers")
struct IgnoreMarkerTests {

    @Test("a bare marker ignores every operator on its line")
    func bare() {
        let map = IgnoreMarkers.parse(lines: ["let x = a > b // slopguard-ignore-mutant"])
        #expect(map == [1: .all])
        #expect(IgnoreMarkers.isIgnored(map, line: 1, operator: .boundary))
        #expect(IgnoreMarkers.isIgnored(map, line: 1, operator: .removeCall))
        #expect(!IgnoreMarkers.isIgnored(map, line: 2, operator: .boundary))
    }

    @Test("a listed marker ignores only those ids; whitespace allowed, unknown ids dropped")
    func listed() {
        let map = IgnoreMarkers.parse(lines: [
            "if m > max { // slopguard-ignore-mutant( boundary , negate_conditional, bogus): equal values"
        ])
        #expect(map == [1: .operators([.boundary, .negateConditional])])
        #expect(IgnoreMarkers.isIgnored(map, line: 1, operator: .boundary))
        #expect(!IgnoreMarkers.isIgnored(map, line: 1, operator: .logical))
        #expect(IgnoreMarkers.parse(lines: ["x // slopguard-ignore-mutant()"]) == [1: .operators([])])
    }

    @Test("on a comment-only line the marker applies to the next line", arguments: [
        "    // slopguard-ignore-mutant(boundary)",
        "/* slopguard-ignore-mutant(boundary) */",
        " * slopguard-ignore-mutant(boundary)"
    ])
    func commentOnly(line: String) {
        let map = IgnoreMarkers.parse(lines: [line, "if a > b {}"])
        #expect(map == [2: .operators([.boundary])])
    }

    @Test("`*` starts a comment-only line only before whitespace, `/` or the line end")
    func starLines() {
        #expect(IgnoreMarkers.parse(lines: [" *", "x"]).isEmpty)
        #expect(IgnoreMarkers.parse(lines: [" */ // slopguard-ignore-mutant", "x"]) == [2: .all])
        #expect(IgnoreMarkers.parse(lines: ["\t*\tslopguard-ignore-mutant", "x"]) == [2: .all])
        // Code that starts with `*` keeps the marker on its own line.
        #expect(IgnoreMarkers.parse(lines: ["*pointer = 1 // slopguard-ignore-mutant", "x"]) == [1: .all])
        #expect(IgnoreMarkers.isCommentOnly("   *"))
        #expect(!IgnoreMarkers.isCommentOnly("*x"))
        #expect(!IgnoreMarkers.isCommentOnly("let a = 1 // comment"))
    }

    @Test("markers aimed at the same line merge")
    func merge() {
        let map = IgnoreMarkers.parse(lines: [
            "// slopguard-ignore-mutant(boundary)",
            "if a > b && c {} // slopguard-ignore-mutant(logical)"
        ])
        #expect(map == [2: .operators([.boundary, .logical])])
        let widened = IgnoreMarkers.parse(lines: ["// slopguard-ignore-mutant(boundary)", "x // slopguard-ignore-mutant"])
        #expect(widened == [2: .all])
    }

    @Test("lines split at \\n, \\r\\n and \\r")
    func lines() {
        #expect(IgnoreMarkers.lines(of: "a\nb\r\nc\rd") == ["a", "b", "c", "d"])
        #expect(IgnoreMarkers.lines(of: "a\n\nb\n") == ["a", "", "b", ""])
    }
}

@Suite("mutation planner")
struct MutationPlannerTests {

    @Test("markers set status ignored for matching operators only")
    func ignoreMarkersApply() {
        let source = """
        func f(a: Int, b: Int) -> Bool {
            // slopguard-ignore-mutant(boundary): equal values behave the same
            return a > b
        }
        """
        let planned = MutationPlanner().plan(source: source, reportedPath: "F.swift", operators: MutationOperator.allCases)
        #expect(planned.map(\.site.mutationOperator) == [.boundary, .negateConditional])
        #expect(planned.map(\.ignored) == [true, false])
    }

    @Test("--operators filters after the markers")
    func operatorFilter() {
        let source = "func f() -> Bool { a > b && !c }"
        let planned = MutationPlanner().plan(source: source, reportedPath: "F.swift", operators: [.logical, .removeNot])
        #expect(planned.map(\.site.mutationOperator) == [.logical, .removeNot])
    }

    @Test("each mutant names its innermost enclosing method")
    func methodNames() {
        let source = """
        let top = a + b
        struct Store {
            func outer() -> Int {
                let inner = { (x: Int) -> Int in x * 2 }
                return inner(1) - 1
            }
            var count: Int { items.count + 1 }
        }
        """
        let planned = MutationPlanner().plan(source: source, reportedPath: "F.swift", operators: [.arithmetic])
        #expect(planned.map(\.method) == [nil, "Store.outer()", "Store.outer()", "Store.count.get"])
        #expect(planned[1].methodLines == 3...6)
    }

    @Test("the smallest span wins; on a tie the later start wins")
    func enclosingMethodRules() {
        func method(_ name: String, _ start: Int, _ end: Int) -> MethodMetric {
            MethodMetric(name: name, qualifiedName: name, typeName: nil, kind: .function, file: "F.swift",
                         startLine: start, endLine: end, complexity: 1, cognitiveComplexity: 0)
        }
        let methods = [method("wide", 1, 20), method("narrow", 5, 8), method("sameSpanLater", 6, 9)]
        #expect(MutationPlanner.enclosingMethod(methods, line: 6)?.qualifiedName == "sameSpanLater")
        #expect(MutationPlanner.enclosingMethod(methods, line: 5)?.qualifiedName == "narrow")
        #expect(MutationPlanner.enclosingMethod(methods, line: 15)?.qualifiedName == "wide")
        #expect(MutationPlanner.enclosingMethod(methods, line: 30) == nil)
    }

    @Test("files sort byte-wise, mutants by line, column and operator; test files are skipped")
    func planFilesSortsAndFilters() throws {
        try withTemporaryDirectory { root in
            // Byte-wise order puts upper case first: "Empty" < "Zeta" < "alpha".
            try write("func b() -> Bool { x < y }\n", to: "Sources/alpha.swift", in: root)
            try write("func a() -> Bool { x < y }\nfunc c() -> Bool { !z }\n", to: "Sources/Zeta.swift", in: root)
            try write("let nothing = 1\n", to: "Sources/Empty.swift", in: root)
            try write("func t() -> Bool { x > y }\n", to: "Tests/ATests/ATests.swift", in: root)
            let files = try MutationPlanner().planFiles(rootURL: root)
            #expect(files.map(\.relativePath) == ["Sources/Empty.swift", "Sources/Zeta.swift", "Sources/alpha.swift"])
            let ids = files.flatMap(\.mutants).map(\.site.id)
            #expect(ids == [
                "Sources/Zeta.swift:1:22:boundary",
                "Sources/Zeta.swift:1:22:negate_conditional",
                "Sources/Zeta.swift:2:20:remove_not",
                "Sources/alpha.swift:1:22:boundary",
                "Sources/alpha.swift:1:22:negate_conditional"
            ])
            #expect(files[0].mutants.isEmpty)
        }
    }

    @Test("package manifests are default-excluded, like test files")
    func manifestsExcluded() throws {
        try withTemporaryDirectory { root in
            try write("let ci = env != nil\n", to: "Package.swift", in: root)
            try write("let ci = env != nil\n", to: "Package@swift-5.9.swift", in: root)
            try write("let x = a > b\n", to: "Sources/Lib/Lib.swift", in: root)
            let defaults = try MutationPlanner().planFiles(rootURL: root)
            #expect(defaults.map(\.relativePath) == ["Sources/Lib/Lib.swift"])
            let everything = try MutationPlanner().planFiles(rootURL: root, options: AnalysisOptions(excludeGlobs: []))
            #expect(everything.map(\.relativePath) == ["Package.swift", "Package@swift-5.9.swift", "Sources/Lib/Lib.swift"])
        }
    }

    @Test("include / exclude globs and a single-file root")
    func includeExcludeAndSingleFile() throws {
        try withTemporaryDirectory { root in
            try write("let a = x > y\n", to: "Keep/A.swift", in: root)
            let skip = try write("let b = x > y\n", to: "Skip/B.swift", in: root)
            let excluded = try MutationPlanner().planFiles(
                rootURL: root,
                options: AnalysisOptions(excludeGlobs: AnalysisOptions.defaultExcludeGlobs + ["**/Skip/**"])
            )
            #expect(excluded.map(\.relativePath) == ["Keep/A.swift"])
            let included = try MutationPlanner().planFiles(
                rootURL: root,
                options: AnalysisOptions(includeGlobs: ["**/B.swift"])
            )
            #expect(included.map(\.relativePath) == ["Skip/B.swift"])
            let single = try MutationPlanner().planFiles(rootURL: skip)
            #expect(single.map(\.relativePath) == ["B.swift"])
            #expect(single.first?.absolutePath == skip.standardizedFileURL.path)
        }
    }

    @Test("a missing path and a non-UTF-8 file are errors")
    func errors() throws {
        #expect(throws: SlopguardError.self) {
            try MutationPlanner().planFiles(rootURL: URL(fileURLWithPath: "/no/such/slopguard/path"))
        }
        try withTemporaryDirectory { root in
            try Data([0x6C, 0x65, 0x74, 0x20, 0xFF, 0xFE]).write(to: root.appendingPathComponent("Bad.swift"))
            do {
                _ = try MutationPlanner().planFiles(rootURL: root)
                Issue.record("expected unreadable_file")
            } catch let error as SlopguardError {
                #expect(error.code == "unreadable_file")
            }
        }
    }

    @Test("--operators parsing: comma-separated, repeated, sorted, de-duplicated")
    func parseOperators() throws {
        #expect(try MutationOperator.parse([]) == MutationOperator.allCases)
        #expect(try MutationOperator.parse([" , "]) == MutationOperator.allCases)
        #expect(try MutationOperator.parse(["remove_not, boundary", "boundary"]) == [.boundary, .removeNot])
        #expect(try MutationOperator.parse(["increment"]) == [.increment])
        do {
            _ = try MutationOperator.parse(["boundary,bogus,nope"])
            Issue.record("expected invalid_argument")
        } catch let error as SlopguardError {
            #expect(error.code == "invalid_argument")
            #expect(error.message.contains("unknown operator(s): bogus, nope"))
        }
        #expect(MutationOperator.allCases.map(\.rawValue) == MutationOperator.allCases.map(\.rawValue).sorted())
    }
}
