import Foundation
import SwiftSyntax

/// SyntaxVisitor that walks a parsed Swift file and produces:
///   * one `MethodMetric` per function-like declaration (functions, initializers,
///     deinitializers, subscripts, and explicit/implicit property accessors)
///   * one `TypeMetric` per nominal type, with summed and max complexity for the
///     methods declared inside it
///
/// The visitor computes **two** complexity metrics on a single walk:
///
/// **Cyclomatic complexity (McCabe).** Each method starts at 1. Increments +1 for:
///   `if`, `guard`, `for`, `while`, `repeat`, each non-default `case`, each `catch`,
///   ternary `? :`, `&&`, `||`, `??`. `default:` and optional chaining (`?.`, `try?`,
///   `as?`) are not counted. Preserved for cross-tool comparability.
///
/// **Cognitive complexity (SonarSource 2023 spec).** Each method starts at 0. Three
/// increment kinds:
///   - **B. Structural** (+1 + nesting depth, bumps nesting for inner code):
///     `if` (head of chain), ternary, `for`, `while`, `repeat`, `switch`
///     (the whole switch — *one* increment regardless of case count), `catch`.
///   - **D. Hybrid** (+1 flat OR +0, bumps nesting for inner code):
///     `else` and chained `else if` (each +1, no nesting penalty); closures,
///     lambdas, and nested functions (+0, nesting only).
///   - **C. Fundamental** (+1 flat, no nesting interaction):
///     each new run of like binary boolean operators (`a && b && c` is one run;
///     `a && b || c && d` is three); labeled jumps (`break <label>`); recursion
///     (deferred — TODO).
///
/// Ignored (cognitive +0): the method itself, `try`/`finally`, `??` and `?.` /
/// `as?`, `default:`, individual `case` labels (only the parent switch counts),
/// plain `return`/`break`/`continue` (early exits), and Swift's `guard`
/// (treated as the canonical early-exit pattern per the spec's "no other jumps
/// or early exits cause an increment" rule).
public final class ComplexityVisitor: SyntaxVisitor {

    private let filePath: String
    private let converter: SourceLocationConverter

    private struct MethodFrame {
        let name: String
        let qualifiedName: String
        let typeName: String?
        let kind: MethodKind
        let startLine: Int
        let endLine: Int
        var complexity: Int
        var cognitive: Int
        var cognitiveNesting: Int
    }

    private struct TypeFrame {
        let kind: TypeKind
        let name: String
        let startLine: Int
        let endLine: Int
        var methodIDs: [String] = []
        var methodComplexities: [Int] = []
        var methodCognitiveComplexities: [Int] = []
    }

    private var methodStack: [MethodFrame] = []
    private var typeStack: [TypeFrame] = []
    /// Stack of identifiers from the immediate enclosing pattern binding, so that
    /// AccessorDeclSyntax nodes can borrow the property name.
    private var bindingNameStack: [String] = []
    /// IfExprSyntax nodes that are the elseBody-`if` of a parent IfExprSyntax —
    /// i.e. chained `else if`. Marked from the parent so that when the child is
    /// visited we can score it as Hybrid (+1 flat) instead of Structural (+1+nesting).
    private var hybridIfNodes: Set<SyntaxIdentifier> = []

    public private(set) var methods: [MethodMetric] = []
    public private(set) var types: [TypeMetric] = []

    public init(filePath: String, converter: SourceLocationConverter) {
        self.filePath = filePath
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Type stack

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(.class, name: node.name.text, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: ClassDeclSyntax) { popType() }

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(.struct, name: node.name.text, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: StructDeclSyntax) { popType() }

    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(.enum, name: node.name.text, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: EnumDeclSyntax) { popType() }

    public override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(.actor, name: node.name.text, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: ActorDeclSyntax) { popType() }

    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(.protocol, name: node.name.text, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: ProtocolDeclSyntax) { popType() }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.trimmedDescription
        pushType(.extension, name: name, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: ExtensionDeclSyntax) { popType() }

    // MARK: - Method-like decls

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethod(
            name: ComplexityVisitor.functionName(node),
            kind: .function,
            range: Syntax(node)
        )
        return .visitChildren
    }
    public override func visitPost(_ node: FunctionDeclSyntax) { popMethod() }

    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethod(
            name: ComplexityVisitor.initName(node),
            kind: .initializer,
            range: Syntax(node)
        )
        return .visitChildren
    }
    public override func visitPost(_ node: InitializerDeclSyntax) { popMethod() }

    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethod(name: "deinit", kind: .deinitializer, range: Syntax(node))
        return .visitChildren
    }
    public override func visitPost(_ node: DeinitializerDeclSyntax) { popMethod() }

    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        pushMethod(
            name: ComplexityVisitor.subscriptName(node),
            kind: .subscript,
            range: Syntax(node)
        )
        return .visitChildren
    }
    public override func visitPost(_ node: SubscriptDeclSyntax) { popMethod() }

    /// Maps accessor spec keywords to our internal `MethodKind`. Anything else
    /// (e.g. `_modify`, `_read`, `init`) falls through to `.function` in the
    /// caller. Static so the visitor object stays cheap to construct.
    private static let accessorKinds: [String: MethodKind] = [
        "get":     .getter,
        "set":     .setter,
        "willSet": .willSet,
        "didSet":  .didSet
    ]

    public override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        let propertyName = bindingNameStack.last ?? "<unknown>"
        let spec = node.accessorSpecifier.text
        let kind = Self.accessorKinds[spec] ?? .function
        pushMethod(
            name: "\(propertyName).\(spec)",
            kind: kind,
            range: Syntax(node)
        )
        return .visitChildren
    }
    public override func visitPost(_ node: AccessorDeclSyntax) { popMethod() }

    // MARK: - Property bindings (track names, plus implicit getter handling)

    public override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        let name = node.pattern.trimmedDescription
        bindingNameStack.append(name)

        // `var foo: Int { computeFoo() }` — implicit getter: the accessorBlock holds
        // a CodeBlockItemList directly rather than explicit AccessorDecls.
        if let block = node.accessorBlock, case .getter = block.accessors {
            pushMethod(
                name: "\(name).get",
                kind: .getter,
                range: Syntax(node)
            )
        }
        return .visitChildren
    }

    public override func visitPost(_ node: PatternBindingSyntax) {
        if let block = node.accessorBlock, case .getter = block.accessors {
            popMethod()
        }
        if !bindingNameStack.isEmpty { bindingNameStack.removeLast() }
    }

    // MARK: - Branching constructs

    /// `if` chain handling: the head `if` is B-Structural (+1+nesting); each
    /// chained `else if` is D-Hybrid (+1 flat). A trailing `else { ... }` is
    /// also D-Hybrid (+1 flat). Cyclomatic counts every `if` (head and chained)
    /// as +1.
    public override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()

        if hybridIfNodes.contains(node.id) {
            // Chained else-if: D-Hybrid.
            bumpCognitive(by: 1)
        } else {
            // Head of an if chain: B-Structural.
            bumpCognitive(by: 1 + currentNesting())
        }
        pushNesting()

        // Mark the chained else-if (if any) so its own visit() treats it as Hybrid,
        // and score the trailing plain else (if any) here as Hybrid +1.
        if let elseBody = node.elseBody {
            if let elseIf = elseBody.as(IfExprSyntax.self) {
                hybridIfNodes.insert(elseIf.id)
            } else if elseBody.is(CodeBlockSyntax.self) {
                bumpCognitive(by: 1) // plain else: Hybrid +1
            }
        }
        return .visitChildren
    }
    public override func visitPost(_ node: IfExprSyntax) {
        popNesting()
        hybridIfNodes.remove(node.id)
    }

    /// Swift `guard` is the canonical early-exit pattern. Per the SonarSource
    /// 2023 spec ("an early return can often make code much clearer, no other
    /// jumps or early exits cause an increment"), it does not increment cognitive.
    /// Cyclomatic still counts it (a real branch in McCabe's model).
    public override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        // cognitive: +0 (early exit, see comment above)
        return .visitChildren
    }

    public override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: ForStmtSyntax) { popNesting() }

    public override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: WhileStmtSyntax) { popNesting() }

    public override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: RepeatStmtSyntax) { popNesting() }

    public override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: CatchClauseSyntax) { popNesting() }

    /// Per the Sonar spec, a switch — regardless of case count — is *one*
    /// structural increment. Cases inside it don't add to cognitive (the whole
    /// point of cognitive vs cyclomatic on flat dispatch). Cyclomatic still
    /// increments per non-`default` case for cross-tool parity.
    public override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: SwitchExprSyntax) { popNesting() }

    public override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        // Cyclomatic: +1 per non-default case (preserved).
        // Cognitive: 0 (the parent SwitchExprSyntax already paid the structural bump).
        if case .case = node.label {
            bumpCyclomatic()
        }
        return .visitChildren
    }

    public override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: TernaryExprSyntax) { popNesting() }

    public override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        bumpCyclomatic()
        bumpCognitive(by: 1 + currentNesting())
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: UnresolvedTernaryExprSyntax) { popNesting() }

    /// Cyclomatic: every `&&` / `||` / `??` is a branch. Counts each.
    /// Cognitive: handled at SequenceExprSyntax level via run-collapse, so
    /// this hook does not bump cognitive.
    public override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        let op = node.operator.text
        if op == "&&" || op == "||" || op == "??" {
            bumpCyclomatic()
        }
        return .visitChildren
    }

    /// Cognitive run-collapse for boolean operators. Per spec: a sequence of
    /// like operators is one increment; each transition between operator types
    /// adds another increment. `??` is a null-coalescing shorthand (Ignored).
    /// Parens / negations break the run by producing a child SequenceExprSyntax,
    /// which is visited separately and counted independently.
    public override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        var lastOp: String?
        for element in node.elements {
            guard let binOp = element.as(BinaryOperatorExprSyntax.self) else {
                continue
            }
            let op = binOp.operator.text
            guard op == "&&" || op == "||" else {
                // Non-boolean operator at this level. Reset the cursor so a
                // subsequent &&/|| run gets counted as a new sequence.
                lastOp = nil
                continue
            }
            if op != lastOp {
                bumpCognitive(by: 1)
                lastOp = op
            }
        }
        return .visitChildren
    }

    /// Closures (lambdas) — D-Hybrid: +0 score, but bump nesting for the body.
    /// The SonarSource spec calls this out explicitly: "no structural increment
    /// for lambdas, nested methods, and similar features, such methods do
    /// increment the nesting level when nested inside other method-like
    /// structures."
    public override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushNesting()
        return .visitChildren
    }
    public override func visitPost(_ node: ClosureExprSyntax) { popNesting() }

    // MARK: - Stack ops

    private func pushType(_ kind: TypeKind, name: String, range node: Syntax) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia).line
        typeStack.append(TypeFrame(kind: kind, name: name, startLine: start, endLine: end))
    }

    private func popType() {
        guard let frame = typeStack.popLast() else { return }
        let totalCyc = frame.methodComplexities.reduce(0, +)
        let maxCyc = frame.methodComplexities.max() ?? 0
        let totalCog = frame.methodCognitiveComplexities.reduce(0, +)
        let maxCog = frame.methodCognitiveComplexities.max() ?? 0
        let metric = TypeMetric(
            kind: frame.kind,
            name: frame.name,
            file: filePath,
            startLine: frame.startLine,
            endLine: frame.endLine,
            methodIDs: frame.methodIDs,
            methodCount: frame.methodIDs.count,
            totalComplexity: totalCyc,
            maxComplexity: maxCyc,
            totalCognitiveComplexity: totalCog,
            maxCognitiveComplexity: maxCog
        )
        // Bubble nested-type method IDs up to the parent type so an outer type's
        // metric sees the methods declared in its inner types as part of its file
        // surface area. (Sum/max are deliberately *not* propagated — those are
        // strictly per-type aggregates.)
        types.append(metric)
    }

    private func pushMethod(name: String, kind: MethodKind, range node: Syntax) {
        let start = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        let end = converter.location(for: node.endPositionBeforeTrailingTrivia).line
        let typeChain = typeStack.map(\.name)
        let typeName = typeChain.last
        let qualified: String
        if typeChain.isEmpty {
            qualified = name
        } else {
            qualified = typeChain.joined(separator: ".") + "." + name
        }
        methodStack.append(MethodFrame(
            name: name,
            qualifiedName: qualified,
            typeName: typeName,
            kind: kind,
            startLine: start,
            endLine: end,
            complexity: 1,        // cyclomatic base = 1
            cognitive: 0,          // cognitive base = 0
            cognitiveNesting: 0
        ))
    }

    private func popMethod() {
        guard let frame = methodStack.popLast() else { return }
        let metric = MethodMetric(
            name: frame.name,
            qualifiedName: frame.qualifiedName,
            typeName: frame.typeName,
            kind: frame.kind,
            file: filePath,
            startLine: frame.startLine,
            endLine: frame.endLine,
            complexity: frame.complexity,
            cognitiveComplexity: frame.cognitive
        )
        methods.append(metric)
        if !typeStack.isEmpty {
            typeStack[typeStack.count - 1].methodIDs.append(metric.id)
            typeStack[typeStack.count - 1].methodComplexities.append(frame.complexity)
            typeStack[typeStack.count - 1].methodCognitiveComplexities.append(frame.cognitive)
        }
    }

    private func bumpCyclomatic() {
        guard !methodStack.isEmpty else { return }
        methodStack[methodStack.count - 1].complexity += 1
    }

    private func bumpCognitive(by amount: Int) {
        guard !methodStack.isEmpty, amount > 0 else { return }
        methodStack[methodStack.count - 1].cognitive += amount
    }

    private func currentNesting() -> Int {
        methodStack.last?.cognitiveNesting ?? 0
    }

    private func pushNesting() {
        guard !methodStack.isEmpty else { return }
        methodStack[methodStack.count - 1].cognitiveNesting += 1
    }

    private func popNesting() {
        guard !methodStack.isEmpty else { return }
        methodStack[methodStack.count - 1].cognitiveNesting -= 1
    }

    // MARK: - Name building

    private static func parameterLabels(_ params: FunctionParameterListSyntax) -> String {
        params.map {
            let first = $0.firstName.text
            return first == "_" ? "_:" : "\(first):"
        }.joined()
    }

    static func functionName(_ node: FunctionDeclSyntax) -> String {
        "\(node.name.text)(\(parameterLabels(node.signature.parameterClause.parameters)))"
    }

    static func initName(_ node: InitializerDeclSyntax) -> String {
        "init(\(parameterLabels(node.signature.parameterClause.parameters)))"
    }

    static func subscriptName(_ node: SubscriptDeclSyntax) -> String {
        "subscript(\(parameterLabels(node.parameterClause.parameters)))"
    }
}
