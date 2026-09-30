# Changelog

All notable changes to slopguard-swift are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-09-30

### Added

- A `mutate` command for mutation testing. It writes one small change (a
  mutant) into a source file, runs the project's tests, and restores the file.
  The report lists the mutants that no test catches, with the file, line,
  column, original text, replacement text and enclosing method of each. The
  flags, operator ids, statuses, JSON shape, exit codes and error codes are the
  same as in the TypeScript, Go, Python and Kotlin ports, except for an unknown
  flag. That is an ArgumentParser usage error, which exits with 64 instead of 1.
- Nine operators: `arithmetic`, `boolean_literal`, `boundary`, `increment`,
  `invert_negative`, `logical`, `negate_conditional`, `remove_call` and
  `remove_not`. `increment` is accepted and produces no mutants, because Swift
  has no `++` or `--`.
- Two test runners. The `swift test` runner builds each mutant with
  `swift build --build-tests` and tests it with `swift test --skip-build`. The
  `xcodebuild` runner uses `build-for-testing` and `test-without-building`. A
  mutant that does not build is `compile_error`. `--runner` picks the runner.
  Without it, `mutate` picks `xcodebuild` when `--scheme` or `--workspace` is
  passed or the project directory holds an `.xcodeproj` or `.xcworkspace`, and
  `swift test` when it holds a `Package.swift`.
- A plain baseline run of the unmutated code, which must pass
  (`baseline_failed`). Its duration sets the per-mutant timeout of
  `ceil(3 × baseline) + 60` seconds, unless `--timeout` is given.
- A coverage baseline run. A mutant on a line that no test executes is
  `no_coverage` and does not run. The `swift test` runner reads per-line counts
  from `xcrun llvm-cov export -format=lcov`. The `xcodebuild` runner reads
  xccov, which reports coverage per function, so with that runner a mutant is
  `no_coverage` when its enclosing method never ran. `--no-coverage` skips this
  run.
- A workspace guard for the in-place edits. The original bytes and timestamps
  come back after every mutant, on errors, and on SIGINT, SIGTERM and SIGHUP,
  which end the run with exit code 130, 143 or 129. A lock, a journal and a
  backup in `$TMPDIR/slopguard-mutate/<hash>/` allow one run per project and
  let the next run recover a file that a killed run left mutated.
- A changed-file guard. When a file changes during a run, `mutate` writes no
  further mutant into it. Its remaining mutants stay `pending`, and a note names
  the file.
- Every test-runner command runs in its own process group. A timeout or an
  interrupt kills the whole group.
- The `mutate` flags `--path`, `--include`, `--exclude`,
  `--no-default-excludes`, `--operators`, `--project-dir`, `--runner`,
  `--scheme`, `--workspace`, `--destination`, `--only-testing`,
  `--no-coverage`, `--timeout`, `--dry-run`, `--json`, `--fail-under`,
  `--verbose` and `--quiet`. `--fail-under` exits with code 2 when the mutation
  score is strictly below the given number.
- The `slopguard-ignore-mutant` and `slopguard-ignore-mutant(<ids>)` comment
  markers for equivalent mutants.
- A JSON report with `reportType: "mutation"` and `schemaVersion: "1"`, and a
  text report.
- The error codes `baseline_failed`, `mutation_in_progress`, `restore_failed`,
  `runner_unavailable` and `runner_not_detected`.
- A `SlopguardMutation` library product with the runners, the workspace guard
  and `MutationPipeline`. `SlopguardCore` gains mutant generation, planning,
  the mutation report types and `DirectoryAnalyzer.sourceFiles(rootURL:options:)`,
  which gives `mutate` the same file set as `analyze`.
- `analyze --workspace <path>` passes `-workspace` to `xcodebuild`, for a
  directory that holds more than one container, such as a CocoaPods workspace
  next to its project. Scheme discovery and the test run both use it. A
  relative path resolves against the current directory.
- `analyze --only-testing <id>` limits the coverage run with
  `-only-testing:<id>`. The flag repeats or takes space-separated values. Code
  that the selected tests do not run reports 0% coverage.
- CI pins the mutation baseline of `SampleApps/TodoList`: 11 mutants, 11 killed
  and 0 survived. The release build smoke test also runs `mutate --dry-run`.

### Changed

- `Package.swift` and `Package@swift-*.swift` are default excludes. `analyze`
  no longer reports package manifests, and `mutate` does not edit them, unless
  you pass `--no-default-excludes` or pass the manifest itself as `--path`.
- slopguard-swift now writes to source files, but only in `mutate`. `analyze`
  still never does. `mutate` edits one file at a time, in place, and restores
  it. `SECURITY.md` describes the new threat model.
- `SlopguardError` has five new cases for `mutate`. Code that switches over it
  exhaustively must handle them.

### Fixed

- The release workflow runs on `macos-15`. The v0.1.0 release run failed at
  `swift build` on `macos-14`, whose SwiftPM rejects Swift language mode 6.
- `DirectoryAnalyzer` reports a single-file root by its file name when the URL
  spells a `/private/var/…` or `/private/tmp/…` path. It used to report the
  file's absolute path. The CLI was not affected, because it standardises
  `--path` first.

## [0.1.0] - 2026-06-10

Initial alpha release.

### Added

- The `analyze` command, which is the default, and the `version` command.
- A weighted CRAP score per method,
  `wCRAP = (cyc × cog) × (1 − cov/100)³ + sqrt(cyc × cog)`. Cyclomatic
  complexity (McCabe) and cognitive complexity (SonarSource 2023 spec) come
  from a SwiftSyntax parse. The default threshold is 30.
- Coverage that slopguard-swift gathers itself. It drives
  `xcodebuild test -enableCodeCoverage YES` and reads the result bundle with
  `xcrun xccov`. When they are not given, it discovers the scheme and the
  project directory.
- The flags `--path` (default `.`), `--threshold`, `--scheme`, `--destination`,
  `--project-dir`, `--no-coverage`, `--include`, `--exclude`,
  `--no-default-excludes`, `--json`, `--fail-over`, `--verbose` and `--quiet`.
- A versioned JSON report (`schemaVersion: "2"`) with per-method and per-type
  results, and a text report. The report goes to stdout and progress goes to
  stderr.
- Exit codes `0`, `1` and `2` (a method above `--fail-over`), and an error
  envelope with stable error codes, as JSON under `--json`.
- Default excludes for build and dependency directories, generated code, test
  and spec files, and `SampleApps/`.
- The `SampleApps/TodoList` fixture as a CI regression baseline.
- A release workflow that builds a universal binary with an SBOM and SHA-256
  checksums. The binaries are not code-signed or notarized.

[Unreleased]: https://github.com/JeevanThandi/SlopGuard-Swift/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/JeevanThandi/SlopGuard-Swift/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JeevanThandi/SlopGuard-Swift/releases/tag/v0.1.0
