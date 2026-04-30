import Foundation
import SlopguardCore
import SlopguardCoverage

enum SuggestRefactorTool {

    static let definition = ToolDefinition(
        name: "suggest_refactor_for_crappy_method",
        title: "Suggest refactor for a crappy method",
        description: """
            Given a method ID (from MethodCrap.id in a prior report), return heuristic, \
            non-LLM refactor advice tailored to the method's complexity / coverage shape: \
            extract-method, table-driven dispatch, reduce-nesting, write-tests-first, etc. \
            v0.1 produces rule-based hints; the agent then proposes the actual code change.
            """,
        inputSchema: ToolSchemas.suggestRefactor,
        handler: { args, _, cache in
            guard let methodId = ToolUtilities.string(args, "methodId") else {
                return ToolUtilities.errorResult(.init(
                    .invalidArgument(name: "methodId", reason: "required string argument")
                ))
            }
            guard let report = await cache.get() else {
                return ToolUtilities.errorResult(.init(
                    code: "no_report",
                    message: "No CrapReport cached. Run analyze_directory first."
                ))
            }
            guard let method = report.methods.first(where: { $0.id == methodId }) else {
                return ToolUtilities.errorResult(.init(
                    code: "method_not_found",
                    message: "No method with id '\(methodId)' in the cached report."
                ))
            }

            let suggestions = SuggestRefactorTool.makeSuggestions(for: method)
            let payload = SuggestRefactorResponse(
                method: method,
                suggestions: suggestions
            )
            return try ToolUtilities.successResult(payload)
        }
    )

    /// Heuristic, deterministic suggestions. We deliberately avoid invoking an LLM
    /// here — agents using slopguard already *are* LLMs; our job is to give them
    /// signal, not to second-guess their refactor.
    ///
    /// Schema 2: heuristics gate on **cognitive** complexity, not cyclomatic.
    /// A method whose cyclomatic is high but cognitive is low is almost
    /// certainly a flat dispatch table — already the cleanest shape — so we
    /// short-circuit it via `isLikelyFlatDispatch` and skip the
    /// extract-method / table-driven-dispatch suggestions entirely.
    static func makeSuggestions(for method: MethodCrap) -> [Suggestion] {
        var out: [Suggestion] = []

        // Cyclomatic >> cognitive ⇒ flat dispatch (large switch / lookup
        // table). The code already *is* a clean dispatch shape; suggesting
        // "extract method" or "table-driven dispatch" would be misdirection.
        let isLikelyFlatDispatch = method.complexity > 10
            && method.complexity / max(1, method.cognitiveComplexity) >= 5

        if method.coverage < 10 && method.cognitiveComplexity >= 5 {
            out.append(Suggestion(
                code: "write_tests_first",
                priority: 1,
                title: "Write characterization tests before refactoring",
                detail: "Coverage is \(format: method.coverage)% with cognitive complexity \(method.cognitiveComplexity). Refactoring uncovered, branchy code is high-risk — pin behavior with tests first, then extract."
            ))
        }
        if method.cognitiveComplexity >= 15 && !isLikelyFlatDispatch {
            out.append(Suggestion(
                code: "extract_method",
                priority: 2,
                title: "Split into smaller methods",
                detail: "Cognitive complexity \(method.cognitiveComplexity) means the method is hard to follow — likely deeply nested or mixing concerns. Look for repeated patterns or comment-delimited sections inside `\(method.qualifiedName)` and extract them into helpers."
            ))
        }
        if method.cognitiveComplexity >= 8 && method.kind == .function && !isLikelyFlatDispatch {
            out.append(Suggestion(
                code: "table_driven_dispatch",
                priority: 3,
                title: "Consider a table or strategy map",
                detail: "Long if/else chains tend to be the dominant complexity driver in Swift. If `\(method.qualifiedName)` dispatches on a discrete input, replace the chain with a `[Key: Handler]` table."
            ))
        }
        if method.kind == .initializer && method.cognitiveComplexity >= 5 {
            out.append(Suggestion(
                code: "factory_method",
                priority: 3,
                title: "Move construction logic out of init",
                detail: "Branchy initializers are hard to test in isolation. Push the conditional logic into a static factory and keep init as a pure assignment."
            ))
        }
        if method.coverage > 80 && method.cognitiveComplexity >= 12 {
            out.append(Suggestion(
                code: "well_tested_but_complex",
                priority: 4,
                title: "Tested but complex — consider simplification",
                detail: "Coverage is high (\(format: method.coverage)%), but cognitive complexity \(method.cognitiveComplexity) makes future change risky. The tests will let you refactor with confidence — start with extract-method."
            ))
        }
        if out.isEmpty {
            out.append(Suggestion(
                code: "no_action",
                priority: 5,
                title: "No refactor recommended",
                detail: "Method is below the heuristic thresholds. wCRAP score \(format: method.crap) at cyclomatic \(method.complexity) / cognitive \(method.cognitiveComplexity), coverage \(format: method.coverage)%."
            ))
        }
        return out.sorted { $0.priority < $1.priority }
    }

    struct Suggestion: Codable, Sendable, Hashable {
        let code: String
        let priority: Int
        let title: String
        let detail: String
    }
}

private struct SuggestRefactorResponse: Codable, Sendable {
    let method: MethodCrap
    let suggestions: [SuggestRefactorTool.Suggestion]
}

private extension String.StringInterpolation {
    mutating func appendInterpolation(format value: Double) {
        appendLiteral(String(format: "%.1f", value))
    }
}
