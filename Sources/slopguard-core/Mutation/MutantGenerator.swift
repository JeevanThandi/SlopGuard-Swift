import Foundation
import SwiftSyntax
import SwiftParser

/// Walks a parsed Swift file and lists every mutant the shared operator set
/// defines (see `MutationOperator`). Only real syntax nodes are mutated —
/// never comments, string contents or `#if` conditions — and each mutant
/// replaces one contiguous span of the original text.
///
/// Binary operators are read from the parser's *unfolded* `SequenceExprSyntax`
/// (no operator folding), where each operator is a `BinaryOperatorExprSyntax`
/// between two operands. Prefix `!` / `-` are `PrefixOperatorExprSyntax`;
/// postfix `!` (force unwrap) is a different node and is never touched.
public struct MutantGenerator: Sendable {

    public init() {}

    /// Mutants for `source`, in source order.
    public func generate(source: String, reportedPath: String) -> [MutantSite] {
        generate(tree: Parser.parse(source: source), source: source, reportedPath: reportedPath)
    }

    /// Mutants for an already-parsed tree of `source`.
    public func generate(tree: SourceFileSyntax, source: String, reportedPath: String) -> [MutantSite] {
        let visitor = MutantVisitor(
            bytes: Array(source.utf8),
            reportedPath: reportedPath,
            converter: SourceLocationConverter(fileName: reportedPath, tree: tree)
        )
        visitor.walk(tree)
        return visitor.sites
    }
}

// MARK: - Operator tables

private let arithmeticReplacements: [String: String] = [
    "+": "-", "-": "+", "*": "/", "/": "*", "%": "*",
    "+=": "-=", "-=": "+=", "*=": "/=", "/=": "*=", "%=": "*="
]

private let boundaryReplacements: [String: String] = [
    "<": "<=", "<=": "<", ">": ">=", ">=": ">"
]

private let negateConditionalReplacements: [String: String] = [
    "==": "!=", "!=": "==", "===": "!==", "!==": "===",
    "<": ">=", "<=": ">", ">": "<=", ">=": "<"
]

private let logicalReplacements: [String: String] = [
    "&&": "||", "||": "&&"
]

/// Calls `remove_call` never removes: printing and logging.
private let loggingFunctions: Set<String> = ["print", "debugPrint", "NSLog", "os_log"]

// MARK: - Visitor

private final class MutantVisitor: SyntaxVisitor {

    private let bytes: [UInt8]
    private let reportedPath: String
    private let converter: SourceLocationConverter
    private(set) var sites: [MutantSite] = []

    init(bytes: [UInt8], reportedPath: String, converter: SourceLocationConverter) {
        self.bytes = bytes
        self.reportedPath = reportedPath
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    /// `#if` conditions are compile-time configuration, not code under test:
    /// walk the clause's body and skip its condition.
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        let conditionID = node.condition?.id
        for child in node.children(viewMode: .sourceAccurate) where child.id != conditionID {
            walk(child)
        }
        return .skipChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() {
            guard let binary = element.as(BinaryOperatorExprSyntax.self) else { continue }
            binaryMutants(binary.operator, index: index, elements: elements)
        }
        return .visitChildren
    }

    override func visit(_ node: PrefixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        // No token-join guard needed: Swift lexes a prefix operator only after whitespace or an opening delimiter, so `return!x` / `return-x` never compile.
        switch node.operator.text {
        case "!": emit(.removeNot, token: node.operator, replacement: "")
        case "-": emit(.invertNegative, token: node.operator, replacement: "")
        default: break
        }
        return .visitChildren
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        emit(.booleanLiteral, token: node.literal, replacement: node.literal.text == "true" ? "false" : "true")
        return .visitChildren
    }

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        if isRemovableCallStatement(node) {
            emit(.removeCall, node: Syntax(node), replacement: "")
        }
        return .visitChildren
    }

    // MARK: Binary operators

    private func binaryMutants(_ token: TokenSyntax, index: Int, elements: [ExprSyntax]) {
        let text = token.text
        if let replacement = arithmeticReplacements[text],
           !Self.isStringConcatenation(text, index: index, elements: elements) {
            emit(.arithmetic, token: token, replacement: replacement)
        }
        if let replacement = boundaryReplacements[text] {
            emit(.boundary, token: token, replacement: replacement)
        }
        if let replacement = negateConditionalReplacements[text] {
            emit(.negateConditional, token: token, replacement: replacement)
        }
        if let replacement = logicalReplacements[text] {
            emit(.logical, token: token, replacement: replacement)
        }
    }

    /// `+` / `+=` joining strings is concatenation, not arithmetic. An operand
    /// is "stringy" when it is a string literal (plain, raw, multi-line or
    /// interpolated), or — through parentheses — a `+` chain with a stringy
    /// operand. In the unfolded sequence a whole `+` chain is stringy when any
    /// operand of it is, so every `+` in `"a" + b + c` is skipped.
    static func isStringConcatenation(_ text: String, index: Int, elements: [ExprSyntax]) -> Bool {
        switch text {
        case "+":
            return plusChainIsStringy(elements, operandIndex: index - 1)
        case "+=":
            return plusChainIsStringy(elements, operandIndex: index - 1)
                || plusChainIsStringy(elements, operandIndex: index + 1)
        default:
            return false
        }
    }

    /// Operands sit at even indices of an unfolded sequence, operators at odd
    /// ones. Collect the run of operands joined by `+` around `operandIndex`.
    private static func plusChainIsStringy(_ elements: [ExprSyntax], operandIndex: Int) -> Bool {
        guard elements.indices.contains(operandIndex) else { return false }
        var low = operandIndex
        var high = operandIndex
        while low >= 2, isPlus(elements[low - 1]) { low -= 2 }
        while high + 2 < elements.count, isPlus(elements[high + 1]) { high += 2 }
        return stride(from: low, through: high, by: 2).contains { isStringy(elements[$0]) }
    }

    private static func isPlus(_ element: ExprSyntax) -> Bool {
        element.as(BinaryOperatorExprSyntax.self)?.operator.text == "+"
    }

    static func isStringy(_ expr: ExprSyntax) -> Bool {
        if expr.is(StringLiteralExprSyntax.self) { return true }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let only = tuple.elements.first, only.label == nil {
            return isStringy(only.expression)
        }
        if let sequence = expr.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            let operators = stride(from: 1, to: elements.count, by: 2).map { elements[$0] }
            guard !operators.isEmpty, operators.allSatisfy(isPlus) else { return false }
            return stride(from: 0, to: elements.count, by: 2).contains { isStringy(elements[$0]) }
        }
        return false
    }

    // MARK: remove_call

    /// A statement that is nothing but a call (optionally under `try` /
    /// `await`) whose result is discarded. Swift always braces `if` / loop
    /// bodies, so every statement sits in a block or statement list. Skipped:
    ///
    /// - printing / logging (`print`, `debugPrint`, `NSLog`, `os_log`, `logger.*`)
    ///   and constructor delegation (`super.init(…)`, `self.init(…)`);
    /// - a single-expression body whose value is returned — closures, getters,
    ///   functions with a return type, branches of `if` / `switch` expressions —
    ///   because the result is not discarded there;
    /// - the only statement of a `switch` case and the last statement of a
    ///   `guard … else` body, whose removal can never compile.
    private func isRemovableCallStatement(_ item: CodeBlockItemSyntax) -> Bool {
        guard case .expr(let expr) = item.item, let call = Self.unwrapCall(expr),
              let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return false }
        if Self.isSkippedCall(call) { return false }
        if list.count == 1 {
            if Self.yieldsValue(list) { return false }
            if list.parent?.is(SwitchCaseSyntax.self) == true { return false }
        }
        if let block = list.parent?.as(CodeBlockSyntax.self), block.parent?.is(GuardStmtSyntax.self) == true,
           list.last?.id == item.id {
            return false
        }
        return true
    }

    private static func unwrapCall(_ expr: ExprSyntax) -> FunctionCallExprSyntax? {
        var current = expr
        while true {
            if let tryExpr = current.as(TryExprSyntax.self) {
                current = tryExpr.expression
            } else if let awaitExpr = current.as(AwaitExprSyntax.self) {
                current = awaitExpr.expression
            } else {
                return current.as(FunctionCallExprSyntax.self)
            }
        }
    }

    private static func isSkippedCall(_ call: FunctionCallExprSyntax) -> Bool {
        guard var names = memberChain(call.calledExpression) else { return false }
        if names == ["super", "init"] || names == ["self", "init"] { return true }
        if names.first == "self" || names.first == "Self" { names.removeFirst() }
        if names.count == 1, loggingFunctions.contains(names[0]) { return true }
        if names.count == 2, names[0] == "Swift", loggingFunctions.contains(names[1]) { return true }
        return names.count >= 2 && names[0] == "logger"
    }

    /// `a.b.c` → `["a", "b", "c"]`; `nil` for anything that is not a plain
    /// name chain (implicit members, calls, subscripts, closures).
    private static func memberChain(_ expr: ExprSyntax) -> [String]? {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return [reference.baseName.text]
        }
        if expr.is(SuperExprSyntax.self) {
            return ["super"]
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base,
           let chain = memberChain(base) {
            return chain + [member.declName.baseName.text]
        }
        return nil
    }

    /// Whether a statement list is a body whose single expression is its value
    /// (implicit return).
    private static func yieldsValue(_ list: CodeBlockItemListSyntax) -> Bool {
        guard let parent = list.parent else { return false }
        if parent.is(ClosureExprSyntax.self) || parent.is(AccessorBlockSyntax.self) { return true }
        if let block = parent.as(CodeBlockSyntax.self), let owner = block.parent {
            if let function = owner.as(FunctionDeclSyntax.self) {
                return returnsValue(function.signature.returnClause)
            }
            if let accessor = owner.as(AccessorDeclSyntax.self) {
                return accessor.accessorSpecifier.tokenKind == .keyword(.get)
            }
            if let ifExpr = owner.as(IfExprSyntax.self) {
                return producesValue(ExprSyntax(ifExpr))
            }
            return false
        }
        if let switchCase = parent.as(SwitchCaseSyntax.self),
           let switchExpr = switchCase.parent?.parent?.as(SwitchExprSyntax.self) {
            return producesValue(ExprSyntax(switchExpr))
        }
        return false
    }

    private static func returnsValue(_ clause: ReturnClauseSyntax?) -> Bool {
        guard let clause else { return false }
        let type = clause.type.trimmedDescription
        return type != "Void" && type != "()" && type != "Swift.Void"
    }

    /// Whether an `if` / `switch` is used for its value: anywhere outside
    /// statement position, or as the implicit return of a value-yielding body.
    private static func producesValue(_ expr: ExprSyntax) -> Bool {
        guard let parent = expr.parent else { return false }
        if let statement = parent.as(ExpressionStmtSyntax.self) {
            guard let item = statement.parent?.as(CodeBlockItemSyntax.self),
                  let list = item.parent?.as(CodeBlockItemListSyntax.self) else { return false }
            return list.count == 1 && yieldsValue(list)
        }
        if let outer = parent.as(IfExprSyntax.self) {   // `else if`: part of the outer chain
            return producesValue(ExprSyntax(outer))
        }
        return true
    }

    // MARK: Emitting

    private func emit(_ mutationOperator: MutationOperator, token: TokenSyntax, replacement: String) {
        emit(mutationOperator, node: Syntax(token), replacement: replacement)
    }

    private func emit(_ mutationOperator: MutationOperator, node: Syntax, replacement: String) {
        let startPosition = node.positionAfterSkippingLeadingTrivia
        let start = startPosition.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        guard start >= 0, start < end, end <= bytes.count else { return }
        let original = String(decoding: bytes[start..<end], as: UTF8.self)
        // Offsets index the source bytes; never emit a span that does not
        // hold the node's own text.
        guard original == node.trimmedDescription else { return }
        let location = converter.location(for: startPosition)
        let lineStart = max(0, start - (location.column - 1))
        let prefix = String(decoding: bytes[lineStart..<start], as: UTF8.self)
        sites.append(MutantSite(
            file: reportedPath,
            line: location.line,
            column: prefix.unicodeScalars.count + 1,
            mutationOperator: mutationOperator,
            original: original,
            replacement: replacement,
            utf8Start: start,
            utf8End: end
        ))
    }
}
