# Security Policy

## Reporting a vulnerability

Please report suspected security issues **privately**, not in public issues
or pull requests.

Open a [GitHub Security Advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository — that is the preferred and only supported channel.

We aim to acknowledge reports within **3 business days** and to publish a fix
within **30 days** for confirmed issues.

## Supported versions

Until v1.0, only the **latest minor release** receives security patches. Once
v1.0 ships, we will support the latest two minor releases.

| Version | Supported |
|---------|-----------|
| 0.2.x   | ✅        |

## Threat model

`analyze` is read-only over the source code it analyzes:

* It parses `.swift` files via [SwiftSyntax](https://github.com/swiftlang/swift-syntax) — no compilation, no execution.
* It invokes `xcrun xcodebuild test`, `xcrun xccov view` and `xcrun xcresulttool` as child processes when gathering coverage. Those are the **only** subprocesses `analyze` spawns.

`mutate` writes to source files by design. It changes one file at a time, in place, runs the project's tests, and writes the original bytes and timestamps back:

* It spawns the project's test runner: `swift build`, `swift test` and `xcrun llvm-cov export`, or `xcrun xcodebuild` (`-list`, `build-for-testing`, `test-without-building` and `test`) and `xcrun xccov`. Each build and test command runs in its own process group, which is killed on timeout or interrupt.
* It restores the file after every mutant, on errors, and on SIGINT, SIGTERM and SIGHUP. A lock, a journal and a backup of the original live in `$TMPDIR/slopguard-mutate/<hash>/`, never inside the project, so the next run recovers a run that was killed outright. See "Safety model" in the README.
* It never writes a mutant into a file that someone edited during the run.
* It only writes files that its own directory walk selected under `--path`, plus its guard files.

All subprocess arguments are passed as argv, never concatenated into a shell command.

Specifically, slopguard-swift does **not**:

* Send telemetry or analytics anywhere.
* Open outbound network connections.
* Load, link, or import the user's code into its own process. (The test runners it launches build and run the user's tests, as they would in CI.)
* Modify or write to source files, except `mutate`'s guarded, restored, one-file-at-a-time edits.
* Read environment variables for credentials or tokens.

## Supply-chain integrity

* Every release ships with a **SHA-256 checksum** of every artifact and a **CycloneDX SBOM** listing all transitive dependencies and their resolved versions (`Package.resolved` + git SHAs).
* **The v0.1.x and v0.2.x release binaries are not code-signed or notarized.** The release pipeline supports Developer ID signing + Apple notarization via `xcrun notarytool` and will produce signed binaries once credentials are provisioned (planned before v0.3). Until then: verify the published SHA-256 checksum, or build from source. macOS Gatekeeper will quarantine the downloaded binary. Clear it with `xattr -d com.apple.quarantine slopguard-swift` after verifying the checksum.
* Reproducibility: builds from the same commit on `macos-15` reproduce byte-for-byte modulo notarization timestamps.

## Dependencies

slopguard-swift depends on (top-level):

| Dependency | License | Purpose |
|---|---|---|
| `swift-syntax`            | Apache-2.0 | Parsing, cyclomatic & cognitive complexity, mutant generation. |
| `swift-argument-parser`   | Apache-2.0 | CLI argument parsing. |

No transitive dependencies. The two packages above are the entire dependency graph.
