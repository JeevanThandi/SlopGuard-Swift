# slopguard-swift

[![CI](https://github.com/JeevanThandi/SlopGuard-Swift/actions/workflows/ci.yml/badge.svg)](https://github.com/JeevanThandi/SlopGuard-Swift/actions/workflows/ci.yml)

> **CRAP (Change Risk Anti-Patterns) guardrail for Swift / iOS.**

`slopguard-swift` measures **complex, undertested code** in Swift sources. It computes a weighted CRAP score combining cyclomatic and cognitive complexity with line coverage, and prints a structured report you can pipe into `jq` or fail CI on. Its `mutate` command checks the other half: that the tests *verify* the code they run (see [Mutation testing](#mutation-testing)).

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
git clone https://github.com/JeevanThandi/SlopGuard-Swift.git
cd SlopGuard-Swift
swift build -c release
cp .build/release/slopguard-swift /usr/local/bin
```

Requires Xcode 16 / Swift 6.0+ on macOS 13+.

## Quickstart

```bash
# Zero-config: analyze the current directory (drives xcodebuild test for coverage)
slopguard-swift

# Scan a specific directory and print the top crappy methods
slopguard-swift analyze --path Sources --threshold 30

# iOS app: pick a scheme and destination
slopguard-swift analyze --path . --scheme MyApp --destination 'platform=iOS Simulator,name=iPhone 16'

# CocoaPods-style project: point xcodebuild at the workspace explicitly
slopguard-swift analyze --path . --workspace MyApp.xcworkspace --scheme MyApp

# Measuring one module? Scope the test run instead of running the whole suite
# (code the selected tests don't exercise reports 0% coverage)
slopguard-swift analyze --path Sources/Login --only-testing MyAppTests/LoginTests

# Full JSON for CI / downstream tooling
slopguard-swift analyze --path Sources --json | jq '.methods | sort_by(-.crap)[:10]'

# Fail CI when any method's CRAP exceeds 50
slopguard-swift analyze --path Sources --fail-over 50

# Complexity only (skip the test build — every method shows 0% coverage)
slopguard-swift analyze --path Sources --no-coverage
```

Progress markers (`slopguard: running xcodebuild test…`) go to **stderr**, so
piped stdout stays clean. `--verbose` streams the underlying xcodebuild output
through; `--quiet` silences progress entirely.

## Subcommands

| Command   | Purpose |
|-----------|---------|
| `analyze` | Walk a directory of Swift sources, drive `xcodebuild test` for coverage, emit a wCRAP report (text or JSON). |
| `mutate`  | Change the source one small step at a time, run the tests against each change, and report the changes no test notices (text or JSON). |
| `version` | Print version metadata as JSON. |

`analyze` is the default subcommand and `--path` defaults to the current
directory — a bare `slopguard-swift` in your project root just works.

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

## Mutation testing

Coverage shows which code ran during the tests. It does not show that a test would fail if that code were wrong. `mutate` checks this. It changes the source one small step at a time, runs the tests against each change, and reports the changes that every test still passes. Each change is a mutant. A mutant that survives is behaviour that no test checks. The report gives the mutant's file, line, column, original text, replacement text and enclosing method, so a developer or an AI agent can write the test that kills it.

`analyze` and `mutate` work together. CRAP finds complex code that the tests do not run. `mutate` finds code that the tests run but do not check.

### Quickstart

```bash
# List the mutants without running tests or changing files
slopguard-swift mutate --path Sources --dry-run

# SwiftPM package: one `swift build` and one `swift test` per mutant
slopguard-swift mutate --path Sources

# One file, two operators, JSON for an agent
slopguard-swift mutate --path Sources/MyLib/Store.swift --operators boundary,negate_conditional --json

# Xcode project or iOS app, with the same scheme, workspace and destination flags as analyze
slopguard-swift mutate --path App --scheme MyApp --destination 'platform=iOS Simulator,name=iPhone 16'

# Fail CI when the mutation score is below 80
slopguard-swift mutate --path Sources --fail-under 80

# Survivors only
slopguard-swift mutate --path Sources --json | jq '.mutants[] | select(.status == "survived")'
```

### What a run does

1. `mutate` walks `--path` with the same include, exclude and default-exclude rules as `analyze`. It never mutates test files or package manifests (`Package.swift`, `Package@swift-*.swift`) unless you target them.
2. It generates mutants with SwiftSyntax and names each mutant's enclosing method, with the same `qualifiedName` as the CRAP report. It applies ignore markers, keeps the `--operators`, and sorts the mutants by file, line, column and operator.
3. It takes the workspace guard, so only one `mutate` run per project can edit files at a time.
4. It runs the plain baseline: the exact mutant command, once, with no mutation and no timeout. If the plain baseline fails, the run stops with `baseline_failed`. Its wall time sets the default timeout of `ceil(3 × baseline) + 60` seconds per mutant. The 60 seconds cover the compile in each Swift mutant run.
5. It runs the coverage baseline, unless you pass `--no-coverage`. A mutant on a line that no test executes gets `no_coverage` and does not run. The coverage baseline never fails the command. When it gives no usable coverage, every mutant runs and a note says so. After the coverage baseline, `mutate` rebuilds the project once without coverage, so the first mutant does not pay for that rebuild.
6. For each mutant, it writes the mutant into the file, builds and tests, restores the file, and classifies the result.

When no mutant is left to run because none was generated or all are ignored, `mutate` skips both baselines. The report then has `runner`, `projectRoot` and `timeoutSeconds` set to `null`.

### Runners

| Runner | Chosen when | Mutant run | Coverage baseline |
|---|---|---|---|
| `swift test` | `--runner swift-test`, or the project directory holds a `Package.swift` and no `.xcodeproj` or `.xcworkspace` | `swift build --build-tests` (non-zero: `compile_error`), then `swift test --skip-build --disable-code-coverage` (non-zero: `killed`) | `swift test --enable-code-coverage`, then `xcrun llvm-cov export -format=lcov` of the test binary, which gives per-line execution counts |
| `xcodebuild` | `--runner xcodebuild`, `--scheme` or `--workspace` is passed, or the project directory holds an `.xcodeproj` or `.xcworkspace` | `xcodebuild build-for-testing` (non-zero: `compile_error`), then `xcodebuild test-without-building` (non-zero: `killed`), both with `-enableCodeCoverage NO` | The `analyze` path: `xcodebuild test -enableCodeCoverage YES`, then `xccov`. xccov reports coverage per function, so a mutant is `no_coverage` when its enclosing method never ran. |

The project directory is `--project-dir`, or else the nearest directory at or above `--path` that holds a `Package.swift`, `.xcodeproj` or `.xcworkspace`, as in `analyze`. Every test-runner command (the build and test steps) runs with `CI=1` and `NO_COLOR=1`, in its own process group. `--only-testing MyAppTests/LoginTests` becomes `-only-testing:MyAppTests/LoginTests` for xcodebuild and `--filter MyAppTests.LoginTests` for `swift test`.

### Flags

| Flag | Meaning |
|---|---|
| `-p, --path <path>` | Directory or single `.swift` file to mutate. Default `.`. |
| `--include <glob>` | Only mutate files that match the globs. Repeat the flag or pass the globs space-separated. |
| `--exclude <glob>` | Extra globs to skip, added to the default excludes. |
| `--no-default-excludes` | Drop the built-in excludes, which are the same list as for `analyze`. |
| `--operators <ids>` | Comma-separated operator ids. The flag may repeat. Default: all. An unknown id is `invalid_argument`. |
| `--project-dir <dir>` | Directory the tests run in. Default: discovered from `--path`. |
| `--runner <swift-test\|xcodebuild>` | Force a runner. |
| `--scheme`, `--workspace`, `--destination`, `--only-testing` | The same as for `analyze`. The first three apply to xcodebuild only. |
| `--no-coverage` | Skip the coverage baseline and run every mutant. |
| `--timeout <seconds>` | Per-mutant timeout for build and test together. Default: `ceil(3 × baseline) + 60`. |
| `--dry-run` | List the mutants. No test runs and no file changes. |
| `--json` | Emit the JSON report on stdout. |
| `--fail-under <score>` | Exit 2 when the mutation score is strictly below this number. A `null` score never fails. Ignored with `--dry-run`. |
| `-v, --verbose` | Stream the test runner's output to stderr. |
| `--quiet` | No progress on stderr. `--quiet` wins over `--verbose`. |

`mutate` rejects the `analyze`-only flags `--threshold` and `--fail-over` as unknown options. ArgumentParser prints a usage error and exits with 64, as it does for any unknown flag. Invalid values such as `--operators bogus`, `--timeout 0`, `--fail-under abc` or `--runner gradle` are `invalid_argument` errors with exit 1.

### Operators

The operator ids are the same in every slopguard port.

| id | Mutation | Swift notes |
|---|---|---|
| `arithmetic` | `+`→`-`, `-`→`+`, `*`→`/`, `/`→`*`, `%`→`*`. Compound assignments: `+=`↔`-=`, `*=`↔`/=`, `%=`→`*=`. | Binary operators only. `mutate` skips `+` and `+=` for string concatenation, that is when an operand is a string literal (plain, raw, multi-line or interpolated) or a parenthesised `+` chain that contains one. Every `+` in `"a" + b + c` is skipped. |
| `boolean_literal` | `true`↔`false` | |
| `boundary` | `<`→`<=`, `<=`→`<`, `>`→`>=`, `>=`→`>` | |
| `increment` | `++`↔`--` | Swift has no `++` or `--`, so this operator produces nothing. The id is still valid. |
| `invert_negative` | `-x` → `x` | Unary minus only, including negative literals. |
| `logical` | `&&`↔`\|\|` | |
| `negate_conditional` | `==`↔`!=`, `===`↔`!==`, `<`→`>=`, `<=`→`>`, `>`→`<=`, `>=`→`<` | |
| `remove_call` | Remove a statement that is only a call whose result is discarded, also under `try` or `await` | Keeps `print`, `debugPrint`, `NSLog`, `os_log`, `logger.*` (and `self.logger.*`), `super.init(…)` and `self.init(…)`. Skips a single-expression body whose value is returned: closures, getters, functions with a return type, and branches of `if` or `switch` expressions. Also skips the only statement of a `switch` case and the last statement of a `guard … else` body. |
| `remove_not` | `!x` → `x` | Postfix `!` (force unwrap) is never touched. |

No operator changes comments, string contents or `#if` conditions. `mutate` does mutate the code inside `#if` blocks and inside string interpolations.

### Statuses

| Status | Meaning | Score |
|---|---|---|
| `killed` | A test failed with the mutant in place. | Detected |
| `timeout` | The run exceeded the timeout, and the whole process group was killed. | Detected |
| `survived` | Every test passed. | Not detected |
| `no_coverage` | No test executes the line, so the mutant did not run. | Not detected |
| `compile_error` | The mutant did not compile. | Excluded |
| `ignored` | An ignore marker switched the mutant off. | Excluded |
| `pending` | The mutant did not run, because of `--dry-run` or because its file changed during the run. | Excluded |

`mutationScore = (killed + timeout) / (killed + timeout + survived + no_coverage) × 100`, unrounded. It is `null` when the denominator is 0.

### Ignore marker

Some mutants cannot be killed because the change has no observable effect. These are equivalent mutants. Mark them in the source:

```swift
if m.complexity > maxComplexity { // slopguard-ignore-mutant(boundary): equal values assign the same max
```

* `slopguard-ignore-mutant` anywhere on a line ignores every mutant on that line.
* `slopguard-ignore-mutant(boundary,negate_conditional)` ignores only the listed operators. Unknown ids are dropped.
* On a line that holds only a comment, the marker applies to the next line. Such a line starts with `//`, `/*`, or `*` followed by a space, `/` or the line end.

### JSON

`--json` emits a versioned report (`reportType: "mutation"`, `schemaVersion: "1"`) with sorted keys. The shape is the same in every port. This is `SampleApps/TodoList`, with one of its 11 mutants shown:

```json
{
  "coverageAvailable" : true,
  "generatedAt" : "2026-09-30T13:34:45.795Z",
  "mutants" : [
    {
      "column" : 59,
      "file" : "Sources/TodoList/TodoStore.swift",
      "id" : "Sources/TodoList/TodoStore.swift:19:59:negate_conditional",
      "line" : 19,
      "method" : "TodoStore.toggle(id:)",
      "operator" : "negate_conditional",
      "original" : "==",
      "replacement" : "!=",
      "status" : "killed"
    }
  ],
  "notes" : [

  ],
  "operators" : [
    "arithmetic",
    "boolean_literal",
    "boundary",
    "increment",
    "invert_negative",
    "logical",
    "negate_conditional",
    "remove_call",
    "remove_not"
  ],
  "projectRoot" : "/abs/SampleApps/TodoList",
  "reportType" : "mutation",
  "runner" : "swift test",
  "schemaVersion" : "1",
  "sourceRoot" : "/abs/SampleApps/TodoList",
  "summary" : {
    "compileErrors" : 0,
    "fileCount" : 3,
    "ignored" : 0,
    "killed" : 11,
    "mutantCount" : 11,
    "mutationScore" : 100,
    "noCoverage" : 0,
    "pending" : 0,
    "survived" : 0,
    "timedOut" : 0
  },
  "timeoutSeconds" : 73,
  "tool" : "slopguard-swift",
  "toolVersion" : "0.2.0"
}
```

`column` counts Unicode code points. `method` is `null` for code outside any method. In a dry run, `runner`, `projectRoot`, `timeoutSeconds` and `mutationScore` are `null`.

Exit codes: `0` success, `1` error, `2` score below `--fail-under`, and `130`, `143` or `129` when SIGINT, SIGTERM or SIGHUP interrupts the run. On exit 1 the error envelope goes to stderr, as JSON with `--json`. The new error codes are `baseline_failed`, `mutation_in_progress`, `restore_failed`, `runner_unavailable` and `runner_not_detected`.

### Safety model

`mutate` edits your source files, so it guards them.

* It mutates one file at a time, in place. Before a file's first mutant it keeps the original bytes and the atime and mtime in memory. It writes a mutant with truncate + write, so the inode, the mode and hard links survive. After each test run it writes the original bytes back and restores the timestamps. SwiftPM's next build still sees the change and recompiles the file.
* Immediately before it writes a mutant, `mutate` checks that the file still holds the bytes the mutants were planned from. If you edit the file before its first mutant or between two mutants, it writes no further mutant into that file. The file's remaining mutants stay `pending`, and a note names the file. An edit saved while a mutant is in the file is not detected: the restore writes the original bytes over it. Do not edit files under `--path` while `mutate` runs.
* The file is restored after every mutant, when an error is thrown, and on SIGINT, SIGTERM and SIGHUP. On a signal, `mutate` kills the running test process group, restores the file, prints `slopguard: interrupted — restored <file>` and exits with 130, 143 or 129.
* The guard directory is `$TMPDIR/slopguard-mutate/<first 16 hex chars of sha256(real project path)>/`, never inside your project. It holds three files. `lock` holds the pid and is created exclusively, so a second live run fails with `mutation_in_progress`. `journal.json` names the file and the mutant's sha256 and is written before each mutant. `original` is a backup of the file's bytes. The TypeScript, Kotlin and Python ports, which also edit files in place, use the same layout.
* SIGKILL cannot be trapped. The next run finds the stale lock and recovers. When the file still holds exactly the mutant named in the journal, it writes the backup back and adds a note. When the file has changed since, it leaves the file alone, keeps the backup in the guard directory, and adds a note that says where the backup is.
* After a power loss, recovery works only if the OS temp directory survives the restart. If it does not, check the files under `--path` against version control.
* If restoring a file fails, the run ends with `restore_failed`, which names the file and the backup path. The guard files stay in place for recovery.

### Port parity

`mutate` follows the shared slopguard contract. The flags, operator ids, statuses, JSON shape, exit codes, error codes and ignore marker are the same as in the TypeScript, Go, Python and Kotlin ports. The guard directory is the same as in the TypeScript, Python and Kotlin ports. The Go port never edits source files, so it needs no guard. These parts are specific to Swift:

* There are two runners, `swift test` and `xcodebuild`.
* The timeout grace is 60 seconds.
* For xcodebuild, `no_coverage` is decided per method, because xccov has no per-line counts.
* `remove_call` has the extra skips listed under Operators.
* `increment` produces nothing, because Swift has no `++`.
* An unknown flag is an ArgumentParser usage error. It exits with 64, not 1, and prints no error envelope, even with `--json`.

## Posture

* **Zero runtime dependencies beyond Xcode.** `analyze` spawns only `xcrun xcodebuild`, `xcrun xccov` and `xcrun xcresulttool`. `mutate` spawns the project's test runner: `swift build`, `swift test` and `xcrun llvm-cov`, or `xcrun xcodebuild` and `xcrun xccov`.
* **Two top-level Swift dependencies** — both upstream Apple swiftlang: `swift-syntax` (Apache-2.0) and `swift-argument-parser` (Apache-2.0). No transitive deps.
* **No network, no telemetry.** `analyze` never writes to your source files. `mutate` edits one source file at a time, in place, and always restores it. See [Safety model](#safety-model).
* **SBOM'd and SHA-256-checksummed** release binaries. Release binaries are not yet code-signed or notarized. Verify the checksum, or build from source. Signing and notarization are planned before v0.3. See [`SECURITY.md`](SECURITY.md).
* **MIT licensed** ([`LICENSE`](LICENSE)).

## Architecture

```
Sources/
├── slopguard-core/       # CRAP formula, models, ComplexityVisitor, DirectoryAnalyzer,
│                         # Mutation/ (MutantGenerator, IgnoreMarkers, MutationPlanner, report models)
├── slopguard-coverage/   # xccov runner, xcresult probe, AnalysisPipeline
├── slopguard-mutation/   # mutate: swift test / xcodebuild runners, process-group spawning,
│                         # WorkspaceGuard, SignalTrap, MutationPipeline
├── slopguard-cli/        # ArgumentParser entry: analyze / mutate / version
└── slopguard-cli-bin/    # Tiny @main executable shim
```

All targets build under **Swift 6 strict concurrency**, target **macOS 13+**.

Invariants of `slopguard-mutation`:

* A mutated file is always restored: after each mutant, on a thrown error, and on SIGINT, SIGTERM and SIGHUP. A failed restore is `restore_failed` and keeps the guard files, so the next run recovers the file.
* Mutants run one at a time, in report order. Only the workspace guard writes to source files, and only with truncate + write.
* A mutant is only written into a file that still holds the bytes the mutants were planned from.
* Every test-runner command runs in its own process group. A timeout or an interrupt kills the whole group.
* The plain baseline alone decides whether the suite passes. The coverage run never fails a run. Without usable coverage, every mutant runs.

## Development

```bash
swift build
swift test                                                    # unit tests
swift run slopguard-swift analyze --path Sources              # dogfood
swift run slopguard-swift analyze --path SampleApps/TodoList  # known-good fixture
swift run slopguard-swift mutate --path SampleApps/TodoList   # mutation baseline: 11 mutants, 11 killed
```

The `mutate` tests (`Tests/SlopguardMutationTests`) use swift-testing rather than XCTest. One of them builds and mutates a small temporary SwiftPM package with the real `swift test` runner. Set `SLOPGUARD_SKIP_E2E=1` to skip it.

We dogfood slopguard-swift against its own sources *and* against the [`SampleApps/`](SampleApps/) fixtures. The fixtures are deliberately tiny, fully covered, low-complexity packages — running the analyzer against them should always produce the same near-zero CRAP report. Drift against that baseline is a regression signal in the analyzer itself.

## Roadmap

* v0.1: CLI, full Core + Coverage, checksummed release binaries with an SBOM. ✅
* v0.2: `mutate`, mutation testing with the `swift test` and `xcodebuild` runners. ✅
* v0.3: Linux build (analyzer only, because Linux has no Xcode), SARIF output for GitHub code scanning.
* v0.4: Per-PR diff mode (`slopguard-swift diff origin/main…HEAD`).

## Contributing

Open an issue, open a PR. CI runs on `macos-15` with strict Swift 6 concurrency, and we eat our own dog food: every CI run analyzes slopguard's own sources, asserts the full-coverage baseline report on `SampleApps/TodoList`, and asserts that `mutate` kills every mutant of `SampleApps/TodoList`.
