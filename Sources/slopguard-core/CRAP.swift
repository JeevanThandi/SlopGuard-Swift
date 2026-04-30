import Foundation

/// The CRAP (Change Risk Anti-Patterns) formula.
///
///     CRAP(m) = comp(m)² × (1 − cov(m)/100)³ + comp(m)
///
/// Where:
///   - `comp` is whatever complexity weighting the caller chooses to feed in.
///     Since schema 2, slopguard-swift feeds `weightedComplexity =
///     sqrt(cyclomatic × cognitive)` so the score reflects both raw branching
///     (cyclomatic) and human-perceived difficulty (cognitive). The formula
///     itself is metric-agnostic — call sites that explicitly want classic
///     cyclomatic-driven CRAP can still pass `Double(method.complexity)`.
///   - `cov` is the line/branch coverage percentage in `[0, 100]`.
///
/// Interpretation:
///   - Fully covered code (cov = 100) collapses to `comp` — complexity alone.
///   - Untested code (cov = 0) penalises quadratically: `comp² + comp`.
///   - The cubed coverage factor sharply rewards even partial test coverage.
///
/// The default "crappy" threshold is `30`, matching the original CRAP paper.
public enum CRAP: Sendable {

    /// Default threshold above which a method/type is considered "crappy".
    public static let defaultThreshold: Double = 30.0

    /// Compute the CRAP score for a single unit of code.
    ///
    /// - Parameters:
    ///   - complexity: Complexity weighting. Negative values are clamped to 0.
    ///     Slopguard-swift feeds `weightedComplexity` (geometric mean of
    ///     cyclomatic × cognitive); other callers may pass any non-negative
    ///     value the formula's `comp²` should square.
    ///   - coveragePercent: Coverage in `[0, 100]`. Out-of-range values are clamped.
    /// - Returns: The CRAP score (always ≥ 0).
    public static func score(complexity: Double, coveragePercent: Double) -> Double {
        let comp = max(0.0, complexity)
        let cov = max(0.0, min(100.0, coveragePercent))
        let covFactor = 1.0 - cov / 100.0
        return comp * comp * (covFactor * covFactor * covFactor) + comp
    }

    /// Aggregate CRAP for a type by summing per-method CRAP.
    ///
    /// We expose three aggregations because each is useful:
    ///   - `sum`: total burden of the type — comparable across types.
    ///   - `max`: worst single method — drives the "biggest fire" metric.
    ///   - `weightedCoverage`: covered / executable across the type's methods.
    public struct Aggregate: Sendable, Hashable, Codable {
        public let sum: Double
        public let max: Double
        public let methodCount: Int

        public init(sum: Double, max: Double, methodCount: Int) {
            self.sum = sum
            self.max = max
            self.methodCount = methodCount
        }

        public static let zero = Aggregate(sum: 0, max: 0, methodCount: 0)
    }

    /// Aggregate scores for a collection of method CRAP values.
    public static func aggregate(_ scores: some Sequence<Double>) -> Aggregate {
        var sum = 0.0
        var max = 0.0
        var count = 0
        for s in scores {
            sum += s
            if s > max { max = s }
            count += 1
        }
        return Aggregate(sum: sum, max: max, methodCount: count)
    }
}
