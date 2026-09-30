# CLAUDE.md — slopguard-swift

Guidance for Claude when working in this repo. Read this first.

## What this is

`slopguard-swift` is the **Swift / iOS port** of slopguard — a CRAP (Change
Risk Anti-Patterns) guardrail. It scores every function, initializer,
subscript and accessor by **complexity × lack-of-coverage** (wCRAP) and emits
a text or JSON report you can gate CI on. Its `mutate` command is a mutation
tester: it writes one small change (a mutant) into a source file at a time,
runs the project's tests against it, restores the file, and reports the
mutants the tests do not catch.

**Parity mandate:** `slopguard-swift` is one of five sibling ports that must
stay **behaviourally aligned**. The wCRAP formula, the schema-2 JSON shape, the
CLI UX (flags, exit codes, stderr/stdout split), and the error-envelope shape
are a shared contract — don't change them unilaterally here, or you break
cross-tool consumers and drift from the siblings:

- TypeScript (the reference port for intent): https://github.com/JeevanThandi/slopguard-typescript
- Go: https://github.com/JeevanThandi/slopguard-go
- Kotlin: https://github.com/JeevanThandi/slopguard-kotlin
- Python: https://github.com/JeevanThandi/slopguard-python

The `mutate` command follows a second shared contract, implemented by all five
ports: the same flags, operator ids, statuses, JSON report (`reportType:
"mutation"`, schema 1), text layout, progress lines, note wording, exit codes
and error codes, plus the guard-directory layout in the four ports that edit
files in place (Go uses `go test -overlay` and needs no guard). The TypeScript
port is the reference (`src/mutation/`, `src/core/mutation/`,
`src/core/formatting/mutationReportFormatter.ts`). Change any of these only
together with the siblings. The Swift-specific parts are the two runners, the
60 s timeout grace, per-method `no_coverage` under xcodebuild, the extra
`remove_call` skips, and `increment` producing nothing (Swift has no `++`).

## Environment gotcha (important)

This Mac has **only the Command Line Tools** (`xcode-select -p` →
`/Library/Developer/CommandLineTools`, no Xcode.app):

- `swift build` works (Apple Swift 6.3 ships with the CLT).
- `xcrun xcodebuild` fails with `unable to find utility "xcodebuild"`.
  `analyze` cannot gather coverage here, so pass `--no-coverage`. `mutate`'s
  xcodebuild runner fails too: `runner_unavailable` with `--scheme`, or
  `xcodebuild_build_failed` when it first has to discover the scheme.
- **XCTest is not installed.** The three XCTest targets (`SlopguardCoreTests`,
  `SlopguardCoverageTests`, `SlopguardCLITests`) do not build, so a plain
  `swift test` in the repo fails at build time. `SampleApps/TodoList` has
  XCTest tests too: its `analyze` and `mutate` baselines only run where Xcode
  is installed (CI).
- The CLT SwiftPM does not add the swift-testing framework search path or
  rpaths. A test target that imports `Testing` then compiles its
  swift-testing branch out, and `swift test` silently runs **nothing**. A
  `swift` shim placed first on `PATH` adds the flags to `swift build` and
  `swift test`:

  ```sh
  #!/bin/sh
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  if [ "$1" = "build" ] || [ "$1" = "test" ]; then
    sub="$1"; shift
    exec /usr/bin/swift "$sub" -Xswiftc -F -Xswiftc "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
  fi
  exec /usr/bin/swift "$@"
  ```

  `mutate`'s swift test runner looks `swift` up on `PATH`, so the shim also
  covers the `swift build` / `swift test` calls that `mutate` makes.

**The swift-testing harness.** `SlopguardMutationTests` uses swift-testing,
not XCTest, so it can run here, but not through the repo's own manifest,
which also declares the XCTest targets. Run it through a local harness
package that lives in a scratch directory and is never committed:

- Its `Package.swift` mirrors the repo's manifest: the same five targets,
  paths and `.swiftLanguageMode(.v6)`, with `swift-syntax` and
  `swift-argument-parser` as path dependencies on copies of
  `.build/checkouts/` (so it builds offline).
- `Sources/<dir>` and `Tests/<dir>` are symlinks into this repo, so the
  harness always builds the working tree.
- The three XCTest targets become plain `.target`s that depend on a stub
  `XCTest` target (no-op `XCTestCase`, `XCTAssert*`, `XCTUnwrap` and
  `XCTSkip*` signatures). `swift build` type-checks them; nothing in them runs.
- `SlopguardMutationTests` is the only `.testTarget`.

```bash
cd <harness> && PATH="<shim dir>:$PATH" swift test   # 118 tests in 22 suites, ~80 s
```

The end-to-end test builds and mutates a temporary SwiftPM package with the
real `swift test` runner; `SLOPGUARD_SKIP_E2E=1` skips it. The link step
prints `ld: warning: building for macOS-13.0, but linking with dylib
'@rpath/Testing.framework/…' which was built for newer version 14.0`. That
comes from the CLT's Testing framework, not from slopguard sources.

## Build / test / run

```bash
swift build                    # -> .build/debug/slopguard-swift
swift build -c release         # -> .build/release/slopguard-swift
swift test --parallel          # every test target; needs Xcode (CI)
```

Run it against itself:

```bash
.build/debug/slopguard-swift version                                  # {"name": …, "version": "0.2.0"}
.build/debug/slopguard-swift analyze --path Sources --no-coverage     # fast, complexity-only
.build/debug/slopguard-swift analyze --path Sources --no-coverage --json | jq '.methods | sort_by(-.crap)[:10]'
.build/debug/slopguard-swift mutate --path Sources --dry-run          # list mutants, run nothing
.build/debug/slopguard-swift mutate --path SampleApps/TodoList        # the mutation baseline (needs XCTest)
```

## Architecture

Four library targets, one executable shim and four test targets. Two
dependencies, both upstream swiftlang: `swift-syntax` (parsing) and
`swift-argument-parser` (CLI). No transitive dependencies — keep it that way.

- **`SlopguardCore`** (`Sources/slopguard-core/`) — pure logic, no
  subprocesses. `CRAP.swift` (the formula), `Analysis/` (`ComplexityVisitor`
  computes cyclomatic and cognitive complexity in one SwiftSyntax walk;
  `SwiftFileAnalyzer`; `DirectoryAnalyzer` applies the include / exclude /
  default-exclude globs and exposes `sourceFiles(rootURL:options:)`, the file
  set both commands share), `Aggregation/` (`CrapAggregator` joins complexity
  with a `CoverageProvider`), `Models/`, `Formatting/` (`CrapReportFormatter`,
  `MutationReportFormatter`), `Errors/SlopguardError.swift`,
  `ProgressReporter`, `Version.swift`. Mutation testing, still pure, lives in
  `Mutation/`: `MutationOperator` (ids, `--operators` parsing),
  `MutantGenerator` (the SwiftSyntax mutant visitor), `IgnoreMarkers`,
  `MutationPlanner` (generate → enclosing method via `ComplexityVisitor` →
  ignore markers → operator filter → sort; reads files, runs nothing) and
  `MutationModels` (`MutantSite`, `PlannedMutant`, `MutantResult`,
  `MutationReport` with its summary and score, `MutationNotes`).
- **`SlopguardCoverage`** (`Sources/slopguard-coverage/`) — `analyze`'s
  coverage. `XcodebuildRunner` (scheme discovery via `xcodebuild -list -json`,
  then `xcodebuild test -enableCodeCoverage YES`), `XccovRunner` +
  `XccovReport` (`xcrun xccov view --report --json`), `CoverageIndex`
  (per-function lookup with a basename fallback), `XcresultProbe` (tells "no
  tests" from "no coverage"), `ProjectRootDiscovery`, `ProcessRunner`,
  `AnalysisPipeline`.
- **`SlopguardMutation`** (`Sources/slopguard-mutation/`) — runs `mutate`.
  `MutationTestRunner.swift` (the runner protocol, `RunnerSelection`,
  `BaselineCoverage`), `SwiftTestMutationRunner`, `XcodebuildMutationRunner`,
  `CommandRunner.swift` (`ProcessGroupCommandRunner`: `posix_spawn` into a new
  process group, bounded output tail, timeout kill), `LineCoverageIndex`
  (lcov `DA:` records), `WorkspaceGuard` (lock, journal, backup, restore,
  recovery), `SignalTrap`, and `MutationPipeline` (plan → guard → plain
  baseline → coverage baseline → one run per mutant → report).
- **`SlopguardCLI`** (`Sources/slopguard-cli/`) — ArgumentParser. `Slopguard`
  is the root command (`analyze` is the default subcommand), plus
  `AnalyzeCommand`, `MutateCommand` and `VersionCommand`. It is a library so
  tests can `@testable import` it (xcodebuild rejects testable imports of
  executable targets).
- **`slopguard-bin`** (`Sources/slopguard-cli-bin/`) — the `@main` shim. The
  product is `slopguard-swift`.
- **Tests.** `SlopguardCoreTests`, `SlopguardCoverageTests` (with
  `Fixtures/`) and `SlopguardCLITests` are XCTest. `SlopguardMutationTests` is
  **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), so it also
  builds with the CLT. It covers every operator, the planner, both report
  formats, the command, both runners (against a fake `CommandRunning`), the
  guard, the pipeline, the process-group runner and one real end-to-end run.
- **`SampleApps/TodoList/`** — a separate package and the CI regression
  baseline (`analyze`: 11 methods, 0 crappy, 100% coverage; `mutate`: 11
  mutants, 11 killed). The `**/SampleApps/**` default exclude keeps it out of
  scans of the repo. When a mutant survives there, strengthen the tests, never
  the sources.

## Key invariants — don't break these

### `analyze`

- **wCRAP formula** (`CRAP.swift`): `score = comp² × (1 − cov/100)³ + comp`,
  fed `comp = weightedComplexity = sqrt(cyclomatic × cognitive)`. Inputs are
  clamped; `isCrappy` is `crap > threshold`; the default threshold is 30.
- **Cyclomatic** starts at 1 and adds 1 for `if`, `guard`, `for`, `while`,
  `repeat`, each non-default `case`, `catch`, ternary, `&&`, `||` and `??`.
  **Cognitive** follows the SonarSource 2023 spec: one increment per `switch`,
  nesting-amplified structural increments, `else` / `else if` +1 flat,
  boolean-run collapse, labelled jumps +1, closures bump nesting only, `guard`
  and early exits free, recursion deferred. `ComplexityVisitorTests` pins the
  exact numbers — if you touch the visitor, those tests are the contract.
- **Types aggregate by lexical nesting** (as in the TypeScript, Kotlin and
  Python ports; Go aggregates by receiver).
- **JSON schema 2** is encoded with sorted keys and unescaped slashes. Method
  `id` is `file#qualifiedName@line`. `generatedAt` uses `.iso8601` (whole
  seconds).
- **Coverage is an artifact, never an input.** `analyze` runs `xcodebuild test
  -enableCodeCoverage YES` into a temporary `.xcresult` (deleted afterwards)
  and reads it with xccov. Failing tests do not abort while a bundle exists;
  no bundle is `xcodebuild_build_failed`. When xccov finds no coverage,
  `XcresultProbe` decides between "no tests" and "coverage not gathered", a
  note says which, and every method reads 0%. The hidden `--xcresult` flag
  feeds a prebuilt bundle (tests and CI fixtures only).
- **Project directory and scheme.** `--project-dir`, else
  `ProjectRootDiscovery` walks up from `--path` to the nearest directory that
  holds a `Package.swift`, `.xcodeproj` or `.xcworkspace`. `--scheme`, else
  `xcodebuild -list -json` prefers a `<name>-Package` umbrella scheme, then a
  single scheme; several are `xcodebuild_scheme_ambiguous`. `--workspace`
  reaches both `-list` and `test`. `--only-testing <id>` becomes
  `-only-testing:<id>`.
- **Default excludes** (`AnalysisOptions.defaultExcludeGlobs`) are shared by
  `analyze` and `mutate`: build and dependency directories, generated code,
  `*Tests` / `*Spec(s)`, `Package.swift` / `Package@swift-*.swift`, and
  `SampleApps`. A single-file `--path` bypasses them. `mutate` must never edit
  a manifest, which is why manifests are excluded.

### `mutate`

- **Runner selection:** `--runner swift-test|xcodebuild` wins. Otherwise
  xcodebuild when `--scheme` or `--workspace` is passed or the project
  directory holds an `.xcodeproj` / `.xcworkspace`, else swift test when it
  holds a `Package.swift`, else `runner_not_detected`. `--scheme`,
  `--workspace` or `--destination` with `--runner swift-test` is
  `invalid_argument`.
- **Two-step classification** (both runners). The build step runs first:
  `swift build --build-tests` or `xcodebuild build-for-testing`; non-zero is
  `compile_error`. Then the test step: `swift test --skip-build
  --disable-code-coverage` or `xcodebuild test-without-building` (both
  xcodebuild steps pass `-enableCodeCoverage NO`); exit 0 is `survived`,
  non-zero is `killed`. A timeout in either step is `timeout`; the test step
  gets what the build left of the timeout. Output that starts with
  `xcrun: error:` is `runner_unavailable`, not a kill.
- **The plain baseline alone decides pass/fail.** It is the exact mutant
  command (both steps) with no mutation and no timeout; non-zero is
  `baseline_failed` quoting the output tail. Its wall time sets the timeout:
  `ceil(3 × seconds) + 60` (`MutationPipeline.timeoutGraceSeconds`), unless
  `--timeout` is given.
- **The coverage baseline is never fatal.** swift test: `swift test
  --enable-code-coverage`, then `swift build --show-bin-path` →
  `<bin>/codecov/default.profdata` (it must be fresh, written by this run) and
  the `.xctest` binaries → `xcrun llvm-cov export -format=lcov` →
  `LineCoverageIndex` (`DA:<line>,<count>`; exact real-path match, no basename
  fallback). A mutant is `no_coverage` when its line's count is exactly 0;
  unknown lines run. xcodebuild: `analyze`'s `xcodebuild test` + xccov →
  `CoverageIndex`, which has **per-function** data only, so a mutant is
  `no_coverage` when its enclosing method's coverage is exactly 0, and a
  mutant outside any method always runs. After the coverage run,
  `prepareMutantRuns` rebuilds once without coverage, so the first mutant does
  not pay for (and time out on) that rebuild.
- **Process groups:** `ProcessGroupCommandRunner` spawns with `posix_spawn`
  and `POSIX_SPAWN_SETPGROUP` (pgid = child pid), `SETSIGDEF` (the child gets
  default SIGINT / SIGTERM / SIGHUP / SIGQUIT / SIGPIPE although slopguard
  ignores them), an empty signal mask, `CLOEXEC_DEFAULT` (only stdin, stdout
  and stderr survive), `/dev/null` as stdin, and `CI=1` + `NO_COLOR=1`. A
  timeout or `stop()` sends SIGKILL to the whole group. After the child exits,
  the pipes drain for at most 2 s, in case an escaped grandchild holds them.
  `analyze` keeps using Foundation `Process`, and so do two `mutate` calls in
  the xcodebuild runner: scheme discovery (`xcodebuild -list -json`, through
  `XcodebuildRunner.discoverDefaultScheme`) and the xccov read
  (`XcodebuildMutationRunner.readXccov`). They inherit the environment
  unchanged (no `CI=1` / `NO_COLOR=1`), have no timeout, and `stop()` does not
  reach them.
- **Signals:** `SignalTrap` sets SIGINT, SIGTERM and SIGHUP to `SIG_IGN` and
  routes them through `DispatchSource.makeSignalSource` on a private queue, so
  the process never dies before the restore. The handler stops the runner
  (kills the group, refuses new commands), restores the file, releases the
  guard, prints `slopguard: interrupted — restored <file>` and exits with
  128 + signal (130, 143, 129). The pipeline uninstalls the trap when the run
  ends. Tests inject `MutationPipeline.InterruptHandling` instead.
- **Workspace guard:** `<TMPDIR>/slopguard-mutate/<16 hex of sha256(real
  project path)>/`, never inside the project, with `lock` (O_EXCL, holds the
  pid; a live holder is `mutation_in_progress`, a dead one triggers recovery
  and one retry), `journal.json` (`{"file", "mutantSha256"}`, temp + rename,
  written before each mutant) and `original` (the backup, once per file).
  Mutants and restores are truncate + write, so the inode, mode and hard links
  survive; the restore also puts back atime / mtime (`utimensat`). The file is
  restored after every mutant, on thrown errors, in `release()` and from the
  signal handler, all under one `NSLock`. A failed restore is
  `restore_failed` and keeps the guard files. Recovery (`recoverFile`) writes
  the backup back when the file's sha256 still equals `mutantSha256`
  (`Restored …` note). If that write fails, it keeps the backup as
  `original-<ms>` (`… writing the original back failed …` note, Swift only).
  When the file changed since, it keeps the backup as `original-<ms>` (`… has
  changed since …` note). A missing backup gets the `… backup is missing …`
  note, but only when the file still holds the mutant. A file that already
  equals the backup gets no note.
- **Changed-file guard:** in the same locked step as the write, the file must
  still hold the bytes the mutants were planned from. Otherwise nothing is
  written, `WorkspaceGuard.FileChanged` is thrown, that mutant and the rest of
  the file stay `pending`, and a note names the file.
- **No token-join guard is needed.** Swift lexes an operator as prefix only
  when whitespace or an opening delimiter precedes it, so `return!x` and
  `return-x` never compile, and removing a prefix `!` or `-` can never join two
  identifiers. The sibling ports replace such a token with a space; Swift
  replaces it with empty text.
- **Generator rules** (pinned by `MutantGeneratorTests`): binary operators come
  from the parser's unfolded `SequenceExprSyntax`; prefix `!` / `-` are
  `PrefixOperatorExprSyntax`, and postfix `!` (force unwrap) is a different
  node that is never touched; `#if` conditions are skipped, their bodies are
  mutated; comments and string contents never mutate, interpolations do;
  `+` / `+=` with a stringy operand (recursively through parentheses and `+`
  chains) is skipped; `remove_call` skips logging (`print`, `debugPrint`,
  `NSLog`, `os_log`, `logger.*`), `super.init` / `self.init`, single-expression
  bodies whose value is returned, the only statement of a `switch` case and the
  last statement of a `guard … else`; every span must equal its node's trimmed
  text; columns count code points; lines split at `\n`, `\r\n` and `\r`, like
  the parser.
- **Ignore marker:** plain text search per line. The bare marker ignores every
  operator; `(ids)` narrows it (unknown ids dropped). On a comment-only line
  (`//`, `/*`, or `*` followed by whitespace, `/` or the line end) it applies
  to the next line.
- **Report shape:** `MutationReport` encodes sorted keys with explicit nulls
  (`projectRoot`, `runner`, `timeoutSeconds`, `method`, `mutationScore`).
  `generatedAt` is UTC with milliseconds, the format every port writes (the
  CRAP report writes whole seconds). Whole numbers print without `.0`. Text
  layout, note wording and progress lines mirror the TypeScript reference
  character for character.

## Swift 6 strict concurrency

Every target builds with `.swiftLanguageMode(.v6)`, and the build has zero
warnings — keep it that way. Every type that crosses a task boundary is
`Sendable`; `ComplexityVisitor` (a `SyntaxVisitor` subclass) stays inside the
task that analyzes one file. The classes that hold mutable state
(`ProcessGroupCommandRunner`, `WorkspaceGuard`, `SignalTrap`'s installed
sources) are `final class … : @unchecked Sendable` with every access under an
`NSLock`. Closures stored in `Sendable` values are
`@Sendable`. Blocking subprocess work runs on `Task.detached`: `analyze`'s
`Process` calls and `MutationPipeline.run`, whose runners are synchronous.
`ISO8601DateFormatter` is not `Sendable`, so each call builds its own.

## Conventions

- Errors are `SlopguardError` cases with a stable snake_case `code`, surfaced
  through `SlopguardErrorEnvelope` as `{"error": {"code", "message"}}` (JSON on
  stderr under `--json`, one line of text otherwise).
- Exit codes: 0 ok, 1 error, 2 `--fail-over` exceeded or mutation score below
  `--fail-under`, 64 an ArgumentParser usage error (unknown flag, bad value
  for a typed option), 130 / 143 / 129 when a signal stops `mutate`.
- stdout carries only the report. Progress goes to stderr through
  `ProgressReporter` with the `slopguard: ` prefix; `--quiet` wins over
  `--verbose`.
- `Sources/slopguard-core/Version.swift` holds the version. The release
  workflow fails when it differs from the pushed tag (without the `v`).

## When verifying a change

On this Mac (Command Line Tools only):

```bash
swift build 2>&1 | grep -E "warning:|error:"      # must print nothing
# An incremental build only reports the files it recompiled. For every
# warning, build once into a fresh scratch path:
swift build --scratch-path "$TMPDIR/slopguard-clean-build" 2>&1 | grep -E "warning:|error:"
cd <harness> && PATH="<shim dir>:$PATH" swift test  # all swift-testing tests pass
.build/debug/slopguard-swift version                 # "version" : "0.2.0"
.build/debug/slopguard-swift mutate --path SampleApps/TodoList --dry-run --json --quiet \
  | jq '{mutants:.summary.mutantCount, pending:.summary.pending}'
# expect {"mutants":11,"pending":11}
```

With Xcode (CI runs these):

```bash
swift test --parallel
swift run slopguard-swift analyze --path SampleApps/TodoList --json --quiet \
  | jq '{methods:.summary.methodCount, crappy:.summary.crappyMethodCount, coverage:.summary.weightedCoverage}'
# expect {"methods":11,"crappy":0,"coverage":100} — the regression baseline
swift run slopguard-swift mutate --path SampleApps/TodoList --json --quiet \
  | jq '{runner, mutants:.summary.mutantCount, killed:.summary.killed, survived:.summary.survived}'
# expect {"runner":"swift test","mutants":11,"killed":11,"survived":0} — the mutation baseline
```
