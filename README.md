# slopguard-swift (Alpha, not ready for use)

> **CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS.**

`slopguard-swift` measures **complex, undertested code** in Swift sources. It computes a weighted CRAP score combining cyclomatic and cognitive complexity with line coverage, and prints a structured report you can pipe into `jq` or fail CI on.

```
wCRAP(m) = (cyc × cog) × (1 − cov/100)³ + sqrt(cyc × cog)
```

* `cyc` — cyclomatic complexity (McCabe), parsed via [SwiftSyntax](https://github.com/swiftlang/swift-syntax).
* `cog` — cognitive complexity per the [SonarSource 2023 spec](https://www.sonarsource.com/resources/cognitive-complexity/) — penalises nesting, ignores early-exit shapes (`guard`, `??`, plain `return`).
* `wt`  — `sqrt(cyc × cog)`, the geometric blend fed into the formula. A flat 50-case `switch` (cyc=50, cog=1) scores like a small method; a deeply nested 3-branch tangle (cyc=3, cog=12) scores like medium-complex code.
* `cov` — line coverage gathered by slopguard-swift itself, via `xcodebuild test`. Never user-supplied.
* Default crappy threshold: **30** (on wCRAP).

## Install

```bash
git clone git@github.com:JeevanThandi/SlopGuard-Swift.git
cd SlopGuard-Swift
swift build -c release
cp .build/release/slopguard-swift /usr/local/bin
```

Requires Xcode 16 / Swift 6.0+ on macOS 13+.

## Quickstart

```bash
# Scan a directory and print the top crappy methods (drives xcodebuild test for coverage)
slopguard-swift analyze --path Sources --threshold 30

# iOS app: pick a scheme and destination
slopguard-swift analyze --path . --scheme MyApp --destination 'platform=iOS Simulator,name=iPhone 17'

# Full JSON for CI / downstream tooling
slopguard-swift analyze --path Sources --json | jq '.methods | sort_by(-.crap)[:10]'

# Fail CI when any method's CRAP exceeds 50
slopguard-swift analyze --path Sources --fail-over 50

# Complexity only (skip the test build — every method shows 0% coverage)
slopguard-swift analyze --path Sources --no-coverage
```

## Subcommands

| Command   | Purpose |
|-----------|---------|
| `analyze` | Walk a directory of Swift sources, drive `xcodebuild test` for coverage, emit a wCRAP report (text or JSON). |
| `version` | Print version metadata as JSON. |

`analyze` is the default subcommand — `slopguard-swift --path Sources` works.

## JSON output

`--json` emits a stable, versioned (`schemaVersion: "2"`) report with:

* `summary` — file/type/method counts, average + max wCRAP, weighted coverage.
* `methods[]` — every analyzed function/initializer/subscript/accessor with `complexity`, `cognitiveComplexity`, `weightedComplexity`, `coverage`, `crap`, `isCrappy`, and a stable `id`.
* `types[]` — per-class aggregation: `aggregatedCrap` (formula applied to type totals) and `maxCrap` (worst single-method offender).

Slice with `jq`:

```bash
# Top 10 worst methods
slopguard-swift analyze --path Sources --json | jq '.methods | sort_by(-.crap)[:10]'

# Only crappy types
slopguard-swift analyze --path Sources --json | jq '.types[] | select(.isCrappy)'

# Coverage gaps: high complexity, low coverage
slopguard-swift analyze --path Sources --json \
  | jq '.methods[] | select(.complexity >= 5 and .coverage <= 50)'
```

## Why it exists

Test coverage alone says "this code ran in a test"; complexity alone says "this code has many paths." Neither tells you whether the *risky* code is tested. CRAP combines them: a method with 20 branches and 0% coverage scores 420; the same method at 100% coverage scores 20 (just its complexity). The score lights up the code most likely to break under a refactor *and* be the hardest to verify the fix for.

## Posture

* **Zero runtime dependencies beyond Xcode.** The only subprocesses slopguard-swift spawns are `xcrun xcodebuild` and `xcrun xccov`.
* **Two top-level Swift dependencies** — both upstream Apple swiftlang: `swift-syntax` (Apache-2.0) and `swift-argument-parser` (Apache-2.0). No transitive deps.
* **No network, no telemetry, no source mutation.**
* **Signed, notarized, and SBOM'd** release binaries. See [`SECURITY.md`](SECURITY.md).
* **MIT licensed** ([`LICENSE`](LICENSE)).

## Architecture

```
Sources/
├── slopguard-core/       # CRAP formula, models, ComplexityVisitor, DirectoryAnalyzer
├── slopguard-coverage/   # xccov runner, xcresult probe, AnalysisPipeline
├── slopguard-cli/        # ArgumentParser entry: analyze / version
└── slopguard-cli-bin/    # Tiny @main executable shim
```

All targets build under **Swift 6 strict concurrency**, target **macOS 13+**.

## Development

```bash
swift build
swift test                                                    # 124 unit tests
swift run slopguard-swift analyze --path Sources              # dogfood
swift run slopguard-swift analyze --path SampleApps/TodoList  # known-good fixture
```

We dogfood slopguard-swift against its own sources *and* against the [`SampleApps/`](SampleApps/) fixtures. The fixtures are deliberately tiny, fully covered, low-complexity packages — running the analyzer against them should always produce the same near-zero CRAP report. Drift against that baseline is a regression signal in the analyzer itself.

## Roadmap

* **v0.1** — CLI, full Core + Coverage, notarized release. ✅
* **v0.2** — Linux build (analyzer-only; no Xcode there), SARIF output for GitHub code scanning.
* **v0.3** — Per-PR diff mode (`slopguard-swift diff origin/main…HEAD`).

## Contributing

Open an issue, open a PR. CI runs on `macos-14` with strict Swift 6 concurrency, and we eat our own dog food (`swift run slopguard-swift analyze --path Sources` is part of the pipeline).
