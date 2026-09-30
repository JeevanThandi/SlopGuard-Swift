import Foundation
import Testing
@testable import SlopguardCore

/// Mutants of `source` (as file `F.swift`), optionally for one operator.
private func sites(_ source: String, _ mutationOperator: MutationOperator? = nil) -> [MutantSite] {
    let all = MutantGenerator().generate(source: source, reportedPath: "F.swift")
    guard let mutationOperator else { return all }
    return all.filter { $0.mutationOperator == mutationOperator }
}

/// `source` with each mutant of `mutationOperator` applied.
private func mutated(_ source: String, _ mutationOperator: MutationOperator) -> [String] {
    sites(source, mutationOperator).map { $0.apply(to: source) }
}

@Suite("arithmetic")
struct ArithmeticOperatorTests {

    @Test("binary operators", arguments: zip(["+", "-", "*", "/", "%"], ["-", "+", "/", "*", "*"]))
    func binary(op: String, replacement: String) {
        let source = "func f(a: Int, b: Int) -> Int { a \(op) b }\n"
        #expect(mutated(source, .arithmetic) == ["func f(a: Int, b: Int) -> Int { a \(replacement) b }\n"])
        #expect(sites(source, .arithmetic).first?.original == op)
    }

    @Test("compound assignments", arguments: zip(["+=", "-=", "*=", "/=", "%="], ["-=", "+=", "/=", "*=", "*="]))
    func compound(op: String, replacement: String) {
        let source = "func f() {\n    var a = 6\n    a \(op) 2\n    use(a)\n}\n"
        #expect(mutated(source, .arithmetic) == ["func f() {\n    var a = 6\n    a \(replacement) 2\n    use(a)\n}\n"])
    }

    @Test("string concatenation is skipped", arguments: [
        #"let s = "a" + b"#,
        #"let s = b + "a""#,
        #"let s = "a" + b + c"#,
        #"let s = b + c + "a""#,
        #"let s = ("a" + b) + c"#,
        #"let s = c + (b + ("a"))"#,
        #"let s = "\(x) items" + y"#,
        ##"let s = #"raw"# + y"##,
        "let s = \"\"\"\n    multi\n    \"\"\" + y",
        #"s += "x""#,
        #"s += a + "x""#,
        #"s += "x" + a"#
    ])
    func stringConcatenation(source: String) {
        #expect(sites(source, .arithmetic).isEmpty, "\(source)")
    }

    @Test("numbers beside a string chain are still mutated")
    func numbersBesideStrings() {
        // The call argument is its own sequence with no stringy operand.
        let source = #"let s = "n=" + String(a + b)"#
        let found = sites(source, .arithmetic)
        #expect(found.count == 1)
        #expect(found.first?.column == 25)
        // A comparison splits chains: only the right-hand chain is stringy.
        let split = sites(#"let t = a + b == c + "d""#, .arithmetic)
        #expect(split.map(\.column) == [11])
    }

    @Test("unary minus and operator references are not arithmetic")
    func notBinary() {
        #expect(sites("let x = -a", .arithmetic).isEmpty)
        #expect(sites("let t = xs.reduce(0, +)", .arithmetic).isEmpty)
        #expect(sites("let r = 0..<n", .arithmetic).isEmpty)
    }
}

@Suite("boolean_literal")
struct BooleanLiteralTests {

    @Test func flipsBothLiterals() {
        #expect(mutated("let a = true", .booleanLiteral) == ["let a = false"])
        #expect(mutated("let b = false", .booleanLiteral) == ["let b = true"])
    }

    @Test("identifiers and strings are not literals")
    func skips() {
        #expect(sites(#"let isTrue = trueValue; let s = "true""#, .booleanLiteral).isEmpty)
    }
}

@Suite("boundary and negate_conditional")
struct ComparisonTests {

    @Test("boundary", arguments: zip(["<", "<=", ">", ">="], ["<=", "<", ">=", ">"]))
    func boundary(op: String, replacement: String) {
        #expect(mutated("let x = a \(op) b", .boundary) == ["let x = a \(replacement) b"])
    }

    @Test("negate_conditional", arguments: zip(
        ["==", "!=", "===", "!==", "<", "<=", ">", ">="],
        ["!=", "==", "!==", "===", ">=", ">", "<=", "<"]
    ))
    func negate(op: String, replacement: String) {
        #expect(mutated("let x = a \(op) b", .negateConditional) == ["let x = a \(replacement) b"])
    }

    @Test("an ordering operator yields one mutant per operator id")
    func bothIDs() {
        let found = sites("let x = a < b")
        #expect(found.map(\.mutationOperator) == [.boundary, .negateConditional])
        #expect(Set(found.map(\.id)).count == 2)
    }

    @Test("equality has no boundary mutant; generics are not comparisons")
    func skips() {
        #expect(sites("let x = a == b", .boundary).isEmpty)
        #expect(sites("let x: Array<Int> = []").isEmpty)
        #expect(sites("func f<T: Comparable>(_ x: T) {}").isEmpty)
    }
}

@Suite("logical, increment, invert_negative, remove_not")
struct UnaryAndLogicalTests {

    @Test func logical() {
        #expect(mutated("let x = a && b", .logical) == ["let x = a || b"])
        #expect(mutated("let x = a || b", .logical) == ["let x = a && b"])
        #expect(sites("let x = a ?? b", .logical).isEmpty)
    }

    @Test("Swift has no ++ / --, so increment never produces a mutant")
    func increment() {
        #expect(sites("func f() { var i = 0\n i += 1\n i -= 1 }", .increment).isEmpty)
    }

    @Test func invertNegative() {
        #expect(mutated("let x = -a", .invertNegative) == ["let x = a"])
        #expect(mutated("let y = -1", .invertNegative) == ["let y = 1"])
        #expect(sites("let z = a - b", .invertNegative).isEmpty)
    }

    @Test func removeNot() {
        #expect(mutated("let x = !a", .removeNot) == ["let x = a"])
        #expect(mutated("if !(a && b) {}", .removeNot) == ["if (a && b) {}"])
    }

    @Test("postfix ! (force unwrap) and != are never remove_not")
    func removeNotSkips() {
        #expect(sites("let x = a!", .removeNot).isEmpty)
        #expect(sites("let x = a!.b!", .removeNot).isEmpty)
        #expect(sites("let x = a != b", .removeNot).isEmpty)
    }
}

@Suite("remove_call")
struct RemoveCallTests {

    @Test("removes call statements, with try / await, as the whole statement")
    func positives() {
        let source = """
        func f() {
            doThing()
            try risky()
            await later()
            try await both()
            list.forEach { item in
                use(item)
                other(item)
            }
            a.b.c(1)
        }
        """
        let originals = sites(source, .removeCall).map(\.original)
        #expect(originals.contains("doThing()"))
        #expect(originals.contains("try risky()"))
        #expect(originals.contains("await later()"))
        #expect(originals.contains("try await both()"))
        #expect(originals.contains("use(item)"))
        #expect(originals.contains("other(item)"))
        #expect(originals.contains("a.b.c(1)"))
        #expect(originals.contains { $0.hasPrefix("list.forEach { item in\n") })
        #expect(sites(source, .removeCall).allSatisfy { $0.replacement.isEmpty })
    }

    @Test("result discarded: Void functions, initializers, setters, observers, defer, top level")
    func discardedPositions() {
        let source = """
        func v() -> Void { effect() }
        func u() -> () { effect() }
        struct S {
            init() { setUp() }
            var p: Int { get { 1 } set { store(newValue) } }
            var q = 0 { didSet { notify() } }
            func g() { defer { cleanUp() } }
        }
        start()
        """
        let originals = sites(source, .removeCall).map(\.original)
        #expect(originals == ["effect()", "effect()", "setUp()", "store(newValue)", "notify()", "cleanUp()", "start()"])
    }

    @Test("a semicolon belongs to its statement")
    func semicolon() {
        let source = "func f() { a(); b() }"
        #expect(mutated(source, .removeCall) == ["func f() {  b() }", "func f() { a();  }"])
    }

    @Test("printing, logging and constructor delegation are kept", arguments: [
        #"print("x")"#, #"debugPrint(1)"#, #"NSLog("x")"#, #"os_log("x")"#, #"Swift.print("x")"#,
        #"logger.info("x")"#, #"self.logger.debug("y")"#, #"Self.logger.error("z")"#,
        "super.init()", "self.init(value: 1)", "try super.init(from: decoder)"
    ])
    func skippedCalls(call: String) {
        let source = "func f() {\n    \(call)\n    other()\n}"
        #expect(sites(source, .removeCall).map(\.original) == ["other()"], "\(call)")
    }

    @Test("values that are returned are not discarded results")
    func implicitReturns() {
        let source = """
        func g() -> Int { compute() }
        var p: Int { compute() }
        var q: Int { get { compute() } }
        struct S { subscript(i: Int) -> Int { value(i) } }
        let c = { compute() }
        func w() -> Int { if flag { a() } else { b() } }
        func x() -> Int { switch k { case .a: a() default: b() } }
        let y = if flag { a() } else if other { b() } else { c() }
        """
        #expect(sites(source, .removeCall).isEmpty)
    }

    @Test("removals that can never compile are skipped")
    func neverCompiles() {
        let source = """
        func f(_ x: E, _ y: Int?) {
            switch x {
            case .a: one()
            case .b:
                two()
                three()
            default: break
            }
            guard let y else {
                log(y)
                fail()
            }
        }
        """
        #expect(sites(source, .removeCall).map(\.original) == ["two()", "three()", "log(y)"])
    }

    @Test("assignments, declarations and returns are not call statements")
    func notCallStatements() {
        let source = """
        func f() -> Int {
            _ = compute()
            let x = compute()
            return compute() + x
        }
        """
        #expect(sites(source, .removeCall).isEmpty)
    }
}

@Suite("scope and positions")
struct GeneratorScopeTests {

    @Test("#if conditions are skipped; the code inside is mutated")
    func conditionalCompilation() {
        let source = """
        #if DEBUG && !os(Linux) || swift(>=5.9)
        let x = a > b
        #elseif false
        let y = true
        #endif
        """
        let found = sites(source)
        #expect(found.map(\.line) == [2, 2, 4])
        #expect(found.map(\.mutationOperator) == [.boundary, .negateConditional, .booleanLiteral])
    }

    @Test("comments and string contents are never mutated; interpolations are code")
    func commentsAndStrings() {
        let source = """
        // a > b && !c
        /* true - false */
        let s = "a > b && !c + 1"
        let t = "\\(a > b)"
        """
        let found = sites(source)
        #expect(found.map(\.line) == [4, 4])
        #expect(found.map(\.original) == [">", ">"])
    }

    @Test("columns count Unicode code points, not bytes or graphemes")
    func nonASCIIColumns() {
        let emoji = sites(#"let s = "héllo 🎉"; let t = a > b"#, .boundary)
        #expect(emoji.map(\.column) == [30])
        // "e" + COMBINING ACUTE ACCENT is one grapheme but two code points.
        let combining = sites("let s = \"e\u{301}\"; let t = a > b", .boundary)
        #expect(combining.map(\.column) == [25])
        // Offsets stay byte offsets: applying the mutant lands on the operator.
        #expect(emoji.first?.apply(to: #"let s = "héllo 🎉"; let t = a > b"#) == #"let s = "héllo 🎉"; let t = a >= b"#)
    }

    @Test("lines count \\n, \\r\\n and \\r, like the parser")
    func lineEndings() {
        let found = sites("let a = 1\r\nlet b = x > y\rlet c = !d\n", nil)
        #expect(found.map(\.line) == [2, 2, 3])
        #expect(found.map(\.column) == [11, 11, 9])
    }

    @Test("ids are <file>:<line>:<column>:<operator>")
    func ids() {
        let found = MutantGenerator().generate(source: "\nlet x = a < b\n", reportedPath: "Sub/Dir/F.swift")
        #expect(found.map(\.id) == ["Sub/Dir/F.swift:2:11:boundary", "Sub/Dir/F.swift:2:11:negate_conditional"])
    }

    @Test("each mutant replaces exactly its original text")
    func spans() {
        let source = "func f() -> Bool {\n    let v = -(a * b) >= c && !d\n    return v || true\n}\n"
        for site in sites(source) {
            let bytes = Array(source.utf8)
            #expect(String(decoding: bytes[site.utf8Start..<site.utf8End], as: UTF8.self) == site.original)
        }
        #expect(sites(source).count == 8)
    }
}
