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
| 0.1.x   | ✅        |

## Threat model

slopguard-swift is read-only over the source code it analyzes:

* It parses `.swift` files via [SwiftSyntax](https://github.com/swiftlang/swift-syntax) — no compilation, no execution.
* It invokes `xcrun xcodebuild test` and `xcrun xccov view` as child processes when gathering coverage. Those are the **only** subprocesses slopguard-swift spawns. All arguments are passed as argv, never concatenated into a shell command.

Specifically, slopguard-swift does **not**:

* Send telemetry or analytics anywhere.
* Open outbound network connections.
* Execute, link, or import the user's code.
* Modify or write to source files.
* Read environment variables for credentials or tokens.

## Supply-chain integrity

* Every release is **signed with a Developer ID Application certificate** and **notarized by Apple** via `xcrun notarytool`.
* Every release ships with a **SHA-256 checksum** of every artifact and a **CycloneDX SBOM** listing all transitive dependencies and their resolved versions (`Package.resolved` + git SHAs).
* Reproducibility: builds from the same commit on `macos-14` reproduce byte-for-byte modulo notarization timestamps.

## Dependencies

slopguard-swift depends on (top-level):

| Dependency | License | Purpose |
|---|---|---|
| `swift-syntax`            | Apache-2.0 | Parsing, cyclomatic & cognitive complexity. |
| `swift-argument-parser`   | Apache-2.0 | CLI argument parsing. |

No transitive dependencies. The two packages above are the entire dependency graph.
