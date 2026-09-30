import Foundation

/// Mutation operator ids. Every slopguard port uses the same ids — in
/// `--operators`, in the JSON `operator` field, and in ignore markers — so keep
/// them in step with the siblings.
///
/// - `arithmetic` — `+`↔`-`, `*`↔`/`, `%`→`*` and the compound assignments.
/// - `boolean_literal` — `true`↔`false`.
/// - `boundary` — `<`↔`<=`, `>`↔`>=`.
/// - `increment` — `++`↔`--`. Swift has no `++`, so it produces nothing here;
///   the id stays valid for `--operators`.
/// - `invert_negative` — `-x` → `x`.
/// - `logical` — `&&`↔`||`.
/// - `negate_conditional` — `==`↔`!=`, `===`↔`!==`, `<`→`>=`, `<=`→`>`, `>`→`<=`, `>=`→`<`.
/// - `remove_call` — drop a call statement whose result is discarded.
/// - `remove_not` — `!x` → `x`.
///
/// Cases are declared in id order, so `allCases` is sorted.
public enum MutationOperator: String, Sendable, Codable, CaseIterable, Comparable {
    case arithmetic
    case booleanLiteral = "boolean_literal"
    case boundary
    case increment
    case invertNegative = "invert_negative"
    case logical
    case negateConditional = "negate_conditional"
    case removeCall = "remove_call"
    case removeNot = "remove_not"

    public static func < (lhs: MutationOperator, rhs: MutationOperator) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    /// Resolve `--operators` values (comma-separated, and the flag may repeat)
    /// into a sorted, de-duplicated list. No ids at all means every operator.
    /// Unknown ids throw `invalid_argument`.
    public static func parse(_ values: [String]) throws -> [MutationOperator] {
        let ids = values
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if ids.isEmpty { return allCases }
        let unknown = ids.filter { MutationOperator(rawValue: $0) == nil }
        guard unknown.isEmpty else {
            let expected = allCases.map(\.rawValue).joined(separator: ", ")
            throw SlopguardError.invalidArgument(
                name: "--operators",
                reason: "unknown operator(s): \(unknown.joined(separator: ", ")) (expected: \(expected))"
            )
        }
        let requested = Set(ids)
        return allCases.filter { requested.contains($0.rawValue) }
    }
}
