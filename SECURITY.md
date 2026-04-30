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
* It optionally invokes `xcrun xccov view --report --json <path>.xcresult` as a child process. This is the **only** subprocess slopguard-swift ever spawns. The xcresult path comes from the user (CLI flag) or the MCP client (tool argument).
* The MCP server, when launched with `slopguard-swift serve`, communicates over stdio (or, in v0.2, HTTP). It exposes only the six documented read-only tools.

Specifically, slopguard-swift does **not**:

* Send telemetry or analytics anywhere.
* Open outbound network connections.
* Execute, link, or import the user's code.
* Modify or write to source files.
* Read environment variables for credentials or tokens.

## Supply-chain integrity

* Every release is **signed with a Developer ID Application certificate** and **notarized by Apple** via `xcrun notarytool`.
* Every release ships with a **SHA-256 checksum** of every artifact and a **CycloneDX SBOM** listing all transitive dependencies and their resolved versions (`Package.resolved` + git SHAs).
* The Homebrew tap formula pins by SHA-256.
* Reproducibility: builds from the same commit on `macos-14` reproduce byte-for-byte modulo notarization timestamps.

## Dependencies

slopguard-swift depends on (top-level):

| Dependency | License | Purpose |
|---|---|---|
| `swift-syntax`            | Apache-2.0 | Parsing & cyclomatic complexity. |
| `swift-argument-parser`   | Apache-2.0 | CLI argument parsing. |
| `mcp-swift-sdk` (`MCP`)   | MIT        | Model Context Protocol server. |

Transitive dependencies (swift-log, swift-nio, swift-system, eventsource, swift-collections, swift-atomics) are pinned in `Package.resolved` and listed in the SBOM artifact attached to each release.

## MCP server posture

When `slopguard-swift serve` is running:

* All tools are flagged `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`.
* No tool writes to disk, mutates source, or initiates outbound network connections.
* Path arguments to `analyze_directory` / `analyze_file` are resolved relative to the *current working directory* of the MCP server process — your client controls the working directory.
* The HTTP transport (v0.2) will require explicit `--host` binding; the default is `127.0.0.1`.
