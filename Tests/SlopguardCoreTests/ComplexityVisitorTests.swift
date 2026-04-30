import XCTest
@testable import SlopguardCore

final class ComplexityVisitorTests: XCTestCase {

    private let analyzer = SwiftFileAnalyzer()

    private func cc(_ source: String, named name: String) throws -> Int {
        let report = try analyzer.analyze(source: source, reportedPath: "Test.swift")
        guard let m = report.methods.first(where: { $0.qualifiedName == name }) else {
            XCTFail("Method \(name) not found in: \(report.methods.map(\.qualifiedName))")
            return 0
        }
        return m.complexity
    }

    func testStraightLineFunctionIsOne() throws {
        let src = """
        func foo() {
            let x = 1
            let y = x + 1
            print(y)
        }
        """
        XCTAssertEqual(try cc(src, named: "foo()"), 1)
    }

    func testIfElseChain() throws {
        let src = """
        func foo(_ x: Int) -> Int {
            if x > 0 { return 1 }
            else if x < 0 { return -1 }
            else { return 0 }
        }
        """
        // Two `if`s (chained) → 1 + 2 = 3
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 3)
    }

    func testGuardCounts() throws {
        let src = """
        func foo(_ x: Int?) -> Int {
            guard let x else { return 0 }
            return x
        }
        """
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 2)
    }

    func testLoops() throws {
        let src = """
        func foo() {
            for _ in 0..<10 {}
            while true {}
            repeat {} while false
        }
        """
        XCTAssertEqual(try cc(src, named: "foo()"), 4)
    }

    func testSwitchSkipsDefault() throws {
        let src = """
        func foo(_ x: Int) -> String {
            switch x {
            case 0: return "z"
            case 1: return "o"
            case 2: return "t"
            default: return "?"
            }
        }
        """
        // 1 base + 3 cases (default skipped)
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 4)
    }

    func testCatchClause() throws {
        let src = """
        func foo() {
            do {
                try maybe()
            } catch is FooError {
                return
            } catch {
                return
            }
        }
        """
        // 1 base + 2 catches
        XCTAssertEqual(try cc(src, named: "foo()"), 3)
    }

    func testLogicalOperators() throws {
        let src = """
        func foo(_ a: Bool, _ b: Bool, _ c: Bool) -> Bool {
            return a && b || c
        }
        """
        // 1 base + && + ||
        XCTAssertEqual(try cc(src, named: "foo(_:_:_:)"), 3)
    }

    func testNilCoalescing() throws {
        let src = """
        func foo(_ a: Int?) -> Int {
            return a ?? 0
        }
        """
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 2)
    }

    func testTernary() throws {
        let src = """
        func foo(_ a: Bool) -> Int {
            return a ? 1 : 0
        }
        """
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 2)
    }

    func testNestedTypeAndMethodNaming() throws {
        let src = """
        class Outer {
            struct Inner {
                func bar(label: Int) { if label > 0 {} }
            }
        }
        """
        let report = try analyzer.analyze(source: src, reportedPath: "Test.swift")
        XCTAssertEqual(report.methods.count, 1)
        XCTAssertEqual(report.methods[0].qualifiedName, "Outer.Inner.bar(label:)")
        XCTAssertEqual(report.methods[0].typeName, "Inner")
        XCTAssertEqual(report.methods[0].complexity, 2)

        // Two type aggregates: Outer (no methods of its own) + Inner (one method).
        XCTAssertEqual(report.types.count, 2)
        let inner = report.types.first { $0.name == "Inner" }
        XCTAssertEqual(inner?.methodCount, 1)
        XCTAssertEqual(inner?.totalComplexity, 2)
        XCTAssertEqual(inner?.maxComplexity, 2)
    }

    func testImplicitGetterIsCounted() throws {
        let src = """
        struct S {
            var value: Int { if a { return 1 } else { return 2 } }
            var a: Bool = false
        }
        """
        let report = try analyzer.analyze(source: src, reportedPath: "Test.swift")
        let getter = report.methods.first { $0.qualifiedName == "S.value.get" }
        XCTAssertNotNil(getter)
        XCTAssertEqual(getter?.kind, .getter)
        XCTAssertEqual(getter?.complexity, 2) // base + if
    }

    /// Explicit accessor blocks (get / set / willSet / didSet) take a different
    /// visitor path than implicit getters — covers `visit(AccessorDeclSyntax)`.
    func testExplicitAccessorsAreCountedSeparately() throws {
        let src = """
        struct S {
            private var _x = 0
            var x: Int {
                get { return _x > 0 ? _x : 0 }
                set { if newValue >= 0 { _x = newValue } else { _x = 0 } }
            }
            var y: Int = 0 {
                willSet { if newValue < 0 {} }
                didSet { if y > 100 || y < -100 {} }
            }
        }
        """
        let report = try analyzer.analyze(source: src, reportedPath: "Test.swift")
        let kinds = Dictionary(uniqueKeysWithValues:
            report.methods.map { ($0.qualifiedName, $0.kind) }
        )
        XCTAssertEqual(kinds["S.x.get"], .getter)
        XCTAssertEqual(kinds["S.x.set"], .setter)
        XCTAssertEqual(kinds["S.y.willSet"], .willSet)
        XCTAssertEqual(kinds["S.y.didSet"], .didSet)

        let getter = report.methods.first { $0.qualifiedName == "S.x.get" }
        XCTAssertEqual(getter?.complexity, 2) // base + ternary
        let setter = report.methods.first { $0.qualifiedName == "S.x.set" }
        XCTAssertEqual(setter?.complexity, 2) // base + if
        let didSet = report.methods.first { $0.qualifiedName == "S.y.didSet" }
        XCTAssertEqual(didSet?.complexity, 3) // base + if + ||
    }

    func testInitAndDeinit() throws {
        let src = """
        class C {
            init(x: Int) { if x > 0 {} }
            deinit { while false {} }
        }
        """
        let report = try analyzer.analyze(source: src, reportedPath: "Test.swift")
        let initMethod = report.methods.first { $0.kind == .initializer }
        XCTAssertEqual(initMethod?.qualifiedName, "C.init(x:)")
        XCTAssertEqual(initMethod?.complexity, 2)
        let deinitMethod = report.methods.first { $0.kind == .deinitializer }
        XCTAssertEqual(deinitMethod?.qualifiedName, "C.deinit")
        XCTAssertEqual(deinitMethod?.complexity, 2)
    }

    func testExtensionTypeChain() throws {
        let src = """
        extension Array where Element == Int {
            func sumIfPositive() -> Int {
                var s = 0
                for x in self where x > 0 { s += x }
                return s
            }
        }
        """
        let report = try analyzer.analyze(source: src, reportedPath: "Test.swift")
        XCTAssertEqual(report.methods.first?.qualifiedName, "Array.sumIfPositive()")
        XCTAssertEqual(report.types.first?.kind, .extension)
        XCTAssertEqual(report.types.first?.name, "Array")
    }

    // MARK: - Cognitive complexity (SonarSource 2023 spec)

    /// Convenience that mirrors `cc(...)` — fetches the cognitive count for a
    /// named method out of a parsed source. Keeps the cognitive tests below
    /// scannable without ceremony per case.
    private func cog(_ source: String, named name: String) throws -> Int {
        let report = try analyzer.analyze(source: source, reportedPath: "Test.swift")
        guard let m = report.methods.first(where: { $0.qualifiedName == name }) else {
            XCTFail("Method \(name) not found in: \(report.methods.map(\.qualifiedName))")
            return -1
        }
        return m.cognitiveComplexity
    }

    /// Flat dispatch — the headline schema-2 case. Cyclomatic ramps with each
    /// case but cognitive stays at 1 (the switch itself), since no case body
    /// is nested or branchy. Anchors the user-reported `mapToDevice` shape.
    func testCognitiveFlatSwitchIsOne() throws {
        let src = """
        func describe(_ x: Int) -> String {
            switch x {
            case 0: return "z"
            case 1: return "o"
            case 2: return "t"
            case 3: return "th"
            case 4: return "f"
            default: return "?"
            }
        }
        """
        XCTAssertEqual(try cog(src, named: "describe(_:)"), 1)
    }

    /// SonarSource 2023 spec example: nested `if` inside `if` inside `while`.
    /// Cognitive = 1 (while) + 2 (inner if at depth 1) + 3 (inner-inner if at
    /// depth 2) = 6.
    func testCognitiveNestedIfInIfInWhile() throws {
        let src = """
        func foo(_ x: Int) {
            while x > 0 {
                if x > 1 {
                    if x > 2 {
                        print(x)
                    }
                }
            }
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:)"), 6)
    }

    /// `guard` is treated as 0 (early-exit), per the spec's "no other jumps or
    /// early exits cause an increment" rule. Cyclomatic still counts it.
    func testCognitiveGuardIsZero() throws {
        let src = """
        func foo(_ x: Int?) -> Int {
            guard let x else { return 0 }
            return x
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:)"), 0)
        XCTAssertEqual(try cc(src, named: "foo(_:)"), 2)
    }

    /// Bare ternary at top level — Structural at depth 0, +1.
    func testCognitiveTernary() throws {
        let src = """
        func foo(_ a: Bool) -> Int {
            return a ? 1 : 0
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:)"), 1)
    }

    /// A run of like operators collapses to a single +1 — `a && b && c && d`
    /// is a single Fundamental contribution.
    func testCognitiveLogicalRunCollapses() throws {
        let src = """
        func foo(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool) -> Bool {
            return a && b && c && d
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:_:_:_:)"), 1)
    }

    /// Mixed operators — each transition between `&&` / `||` adds +1.
    /// Spec's `a && b || c && d` example expects 3.
    func testCognitiveMixedLogicalOperators() throws {
        let src = """
        func foo(_ a: Bool, _ b: Bool, _ c: Bool, _ d: Bool) -> Bool {
            return a && b || c && d
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:_:_:_:)"), 3)
    }

    /// `if` inside a switch case — the switch counts at depth 0 (+1), the case
    /// body lives at depth 1 (the switch bumps nesting), so the inner `if`
    /// contributes +1+1=2. Total cog = 1 + 2 = 3.
    func testCognitiveIfInsideSwitchCase() throws {
        let src = """
        func foo(_ x: Int) -> Int {
            switch x {
            case 0:
                if x == 0 { return 1 }
                return 2
            default:
                return 3
            }
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:)"), 3)
    }

    /// `else if` chain — head if is Structural (+1), each subsequent
    /// `else if` / `else` is Hybrid (+1 flat, no nesting penalty).
    /// `if a {} else if b {} else if c {}` → cog = 1 + 1 + 1 = 3.
    func testCognitiveElseIfChainIsThreeFlatIncrements() throws {
        let src = """
        func foo(_ a: Bool, _ b: Bool, _ c: Bool) -> Int {
            if a { return 1 }
            else if b { return 2 }
            else if c { return 3 }
            return 0
        }
        """
        XCTAssertEqual(try cog(src, named: "foo(_:_:_:)"), 3)
    }

    /// Closure body counts at depth+1 (the closure is Hybrid: bumps nesting
    /// without scoring itself). An `if` inside a closure inside a function
    /// scores at depth 1, so cog = 0 + (1 + 1) = 2.
    func testCognitiveClosureBumpsNestingWithoutScoring() throws {
        let src = """
        func foo() {
            let f = { (x: Int) in
                if x > 0 { print(x) }
            }
            _ = f
        }
        """
        XCTAssertEqual(try cog(src, named: "foo()"), 2)
    }

    /// Recursion increment is deferred to v0.3 — Sonar parity is undercounted
    /// here. Skipped explicitly so the gap is visible.
    func testCognitiveRecursionIncrementDeferred() throws {
        try XCTSkipIf(true, "cognitive recursion increment deferred to v0.3")
        let src = """
        func fact(_ n: Int) -> Int {
            return n <= 1 ? 1 : n * fact(n - 1)
        }
        """
        // When implemented: ternary +1 + recursion +1 = 2
        XCTAssertEqual(try cog(src, named: "fact(_:)"), 2)
    }
}
