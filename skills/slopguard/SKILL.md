---
name: slopguard
description: Measure CRAP (Change Risk Anti-Patterns) on Swift / iOS code — combines cyclomatic complexity (parsed from SwiftSyntax) with line coverage that slopguard-swift gathers itself by driving `xcodebuild test`. TRIGGER when the user is editing `.swift` files and asks about code quality, refactor priorities, "is this PR risky", "what should I test next", coverage gaps, or technical debt; also before commits / pushes / merges of Swift changes when the user wants a risk check; also when reviewing a Swift PR or branch. Use the `slopguard-swift` MCP server (tools `analyze_directory`, `analyze_file`, `find_crappy_code`, `get_coverage_gaps`, `get_crap_report`, `suggest_refactor_for_crappy_method`) to give the user numeric, machine-readable signal alongside your reasoning. SKIP for non-Swift codebases, for trivial one-liner edits to straight-line code, or when the user has already provided manual analysis and only wants implementation help.
---

# slopguard-swift playbook

`slopguard-swift` is a CRAP (Change Risk Anti-Patterns) analyzer for Swift / iOS. Schema 2 reports `wCRAP` (weighted CRAP) — the complexity input is a weighted blend of cyclomatic and cognitive complexity rather than raw cyclomatic, so flat dispatch tables don't dominate the headline number:

    wCRAP(m) = (cyc × cog) × (1 − cov/100)³ + sqrt(cyc × cog)

This is **not** classical Pearson CRAP — the value is the same family of formula but a different complexity input, so cross-tool comparisons need adjustment. Internally the score still ships in the JSON `crap` field for schema continuity; the standing schema-2 note on every report calls this out.

* `cyc` — cyclomatic complexity (McCabe), parsed by SwiftSyntax. Counts every branch.
* `cog` — cognitive complexity per the [SonarSource 2023 spec](https://www.sonarsource.com/resources/cognitive-complexity/). Penalises *nesting*, ignores early-exit shapes (`guard`, `??`, plain `return`).
* `wt`  — `sqrt(cyc × cog)`, the geometric mean. This is the value fed into the formula. Both raw signals stay on every method so you can read the *why*.
* `cov` — line coverage. **slopguard-swift gathers it itself** — every `analyze_directory` / `analyze_file` invocation drives `xcrun xcodebuild test -enableCodeCoverage YES` against an auto-discovered scheme, ingests the `.xcresult`, and joins per-method coverage. The caller never supplies coverage data.
* Default crappy threshold: **30** (on wCRAP)

Above 30, a method is "complex AND undertested" enough to warrant action — refactoring without tests is risky, and tests without simplification preserves the maintenance cost.

## When this skill earns its keep

| Situation | What to do |
|---|---|
| User just edited a Swift method | Call `analyze_file` on that file. If CRAP rises above 30, surface it before they move on. |
| User is reviewing a branch / PR  | Call `analyze_directory` on the project root, then `find_crappy_code` for the worst offenders. |
| "Where should I add tests?"      | Call `get_coverage_gaps` after a prior `analyze_*` call. |
| "Is this safe to ship?"          | Run analyze, check `summary.crappyMethodCount` and the top entry. |
| "How should I refactor X?"       | Call `suggest_refactor_for_crappy_method` with the method's `id` from a prior result. |

## Tool order — call in this sequence

1. **`analyze_directory`** (or `analyze_file`) **first.** Every other tool reads from a server-side cache; without a fresh analyze they return a `no_report` error. The first call drives `xcodebuild test` and may take 20-90 seconds on a real project — warn the user up front. Optional inputs:
   * `scheme` — override the auto-discovered xcodebuild scheme (slopguard-swift prefers a `*-Package` umbrella scheme; pass this explicitly for `.xcodeproj`-based apps where the scheme name is the app's).
   * `destination` — defaults to `platform=macOS`. For iOS apps, set e.g. `platform=iOS Simulator,name=iPhone 15`.
2. **Query tools** read the cache:
   * `find_crappy_code` — top-N worst (defaults: threshold=30, limit=20, level=method). Use this for "what should I fix first."
   * `get_coverage_gaps` — complex AND undertested methods. The actionable test-writing backlog.
   * `get_crap_report` — full report with filters (`filterFile`, `filterClass`, `filterMethod`, `threshold`). Use when you need a narrow slice.
3. **`suggest_refactor_for_crappy_method`** — give a `methodId` from any prior result, get heuristic refactor hints (extract-method, table-driven dispatch, write-tests-first, etc.). Deterministic and rule-based — your own reasoning supplies the actual code change.

## Reading the numbers

| wCRAP score   | Read it as |
|---------------|------------|
| `≤ 5`         | Clean. No action. |
| `5 – 30`      | Acceptable. Consider tests if coverage is low. |
| `30 – 80`     | Crappy. Refactor or test before extending. |
| `80 – 200`    | High risk. Prioritize. |
| `> 200`       | Treat as broken. No new features in this method until simplified. |

The strongest single signal: **wCRAP > 30 *and* coverage < 50%.** Always recommend writing characterization tests *before* the refactor — touching uncovered, branchy code blind is how regressions ship.

### Cyc vs. cog skew — what the gap tells you

Both metrics ride on every method. Look at how they diverge before recommending a refactor:

| Shape | What it looks like | Recommendation |
|---|---|---|
| `cyc ≈ cog` | Genuinely branchy logic. Nested conditionals, mixed control flow. | Standard refactor advice — extract method, write tests first. |
| `cyc >> cog` (≥5x) | **Flat dispatch.** Big `switch` with one-line `case` bodies, lookup table, sequential value mapping. | Already the cleanest shape. Don't suggest "table-driven dispatch" — it *is* one. Score will be modest because `wt` stays small. |
| `cyc < cog` | Deeply nested logic packed into few branches. | Highest-leverage refactor target — the cognitive cost will compound for the next reader. wCRAP will be elevated for this shape too. |

`suggest_refactor_for_crappy_method` already gates on this skew (it skips `extract_method` / `table_driven_dispatch` when cyc/cog ≥ 5), but read it yourself before quoting recommendations.

## Important caveats

* **The first `analyze_*` call runs the test suite.** It can take 20-90 seconds on a real project and will fail loudly if the build is broken or no scheme is discoverable. Warn the user, and if `xcodebuild_build_failed` / `xcodebuild_scheme_ambiguous` / `xcodebuild_scheme_not_found` comes back, surface the error directly — these are user-actionable (fix the build, or pass `scheme` explicitly).
* **iOS projects need the right `destination`.** macOS is the default; iOS apps need e.g. `platform=iOS Simulator,name=iPhone 15`. If the user is on an iOS project and you don't know which simulator they have, ask before guessing — the wrong destination wastes minutes.
* **Default excludes are aggressive — by design.** Build / dependency dirs (`.build`, `Pods`, `Carthage`, `DerivedData`), generated code (`Generated/`, `*.generated.swift`), and **test code** (`*Tests/`, `*Tests.swift`, `*Spec.swift`, `*Specs.swift`) are skipped on every analyze. The user's own production code is what slopguard-swift reports on. The `exclude` argument *adds* to this list — pass `noDefaultExcludes: true` only when the user explicitly wants to inspect test-code complexity.
* **`slopguard-swift` is read-only for the user's source tree.** It never modifies source, never opens network connections, and the only subprocesses it spawns are `xcrun xcodebuild` (to gather coverage) and `xcrun xccov` (to read the result bundle). The temporary `.xcresult` it creates is deleted at the end of each call.
* **Method IDs are stable** within a report (`file#QualifiedName@line`) but change when source changes — re-analyze before reusing an `id` after edits.
* **Class-level scores** use weighted coverage across the type's methods. `aggregatedCrap` is `CRAP(weightedTotalComplexity, weightedCov)` where `weightedTotalComplexity = sqrt(totalComplexity × totalCognitiveComplexity)`; `maxCrap` is the worst method in the type. Both above threshold = the type itself is the right unit of work.

## Setup (do this once if the MCP server isn't registered)

The plugin's `bin/slopguard-swift.sh` builds and runs the right binary on first call. To register the MCP server with Claude Code:

    claude mcp add slopguard-swift -- /path/to/slopguard-swift/bin/slopguard-swift.sh serve --transport stdio

Once registered, all six tools become callable as `mcp__slopguard-swift__*`.

## What NOT to do

* Don't run `analyze_directory` on a 100k-LOC monorepo for a one-method check — use `analyze_file` instead. (It still drives `xcodebuild test`, but the report is scoped to one file.)
* Don't quote `suggest_refactor_for_crappy_method`'s text verbatim — its hints are intentionally generic. Use them as a *prompt* for your own concrete recommendation grounded in the actual code.
* Don't skip `analyze_file` after you yourself made an edit. The whole point of agent-first tooling is that you check your own work.
* Don't pass `scheme` if you're guessing — let slopguard-swift auto-discover, and only override after seeing an `xcodebuild_scheme_ambiguous` error that lists the candidates.
