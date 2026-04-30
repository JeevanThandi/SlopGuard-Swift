# slopguard-swift (Alpha, not ready for use)

> **Agentic-first quality guardrail for Swift / iOS.**

`slopguard-swift` measures **complex, undertested code** and surfaces it where AI coding agents — and humans — will see it. It computes the original CRAP (Change Risk Anti-Patterns) score on Swift sources, drives `xcodebuild test` itself to gather coverage, and exposes the result through a **Model Context Protocol (MCP) server** plus a thin CLI.

```
wCRAP(m) = (cyc × cog) × (1 − cov/100)³ + sqrt(cyc × cog)
```

`wCRAP` (weighted CRAP) is the schema-2 score slopguard-swift reports — classic CRAP's complexity input is replaced with a weighted blend of cyclomatic and cognitive complexity, so flat dispatch tables don't dominate the headline metric. Cross-tool comparisons against tools that report classic Pearson CRAP need adjustment.

* `cyc` — cyclomatic complexity (McCabe), parsed via [SwiftSyntax](https://github.com/swiftlang/swift-syntax).
* `cog` — cognitive complexity per the [SonarSource 2023 spec](https://www.sonarsource.com/resources/cognitive-complexity/) — penalises nesting, ignores early-exit shapes (`guard`, `??`, plain `return`).
* `wt`  — `sqrt(cyc × cog)`, the geometric blend fed into the formula. A flat 50-case `switch` (cyc=50, cog=1) scores like a small method; a deeply nested 3-branch tangle (cyc=3, cog=12) scores like medium-complex code. Both raw signals ride the report so the agent can see *why*.
* `cov` — line coverage gathered by slopguard-swift itself; never user-supplied.
* Default crappy threshold: **30** (on wCRAP).

## Why agentic-first

The MCP server is the primary interface; the CLI is a thin shim over the same engine. Every tool returns structured output, every error is machine-readable, every tool description is written for an LLM to plan against. The plugin ships three halves: the **server** (capability), the **skill** at [`skills/slopguard/SKILL.md`](skills/slopguard/SKILL.md) (playbook — when/how to use it), and the **wrapper** [`bin/slopguard-swift.sh`](bin/slopguard-swift.sh) (no-config install).

## Install

**Claude Code:**

```bash
/plugin marketplace add <owner>/slopguard-swift
/plugin install slopguard-swift@<owner>-slopguard-swift
```

That registers the MCP server and skill. First call builds the release binary if absent (~20s, one-time); subsequent calls are instant.

**Other clients:**

| Agent / client    | Setup |
|-------------------|-------|
| **Cursor**        | Add a `slopguard-swift` block to `~/.cursor/mcp.json` pointing at `slopguard-swift serve --transport stdio`. |
| **Custom agents** | Spawn `slopguard-swift serve --transport stdio` and speak MCP. |
| **CLI / CI**      | `swift build -c release && cp .build/release/slopguard-swift /usr/local/bin` (Homebrew tap once published). |

## Quickstart

```bash
# CLI: scan and print top crappy methods (drives xcodebuild test for coverage)
slopguard-swift analyze --path Sources --threshold 30

# CLI: pick a specific scheme / destination for an iOS app
slopguard-swift analyze --path . --scheme MyApp --destination 'platform=iOS Simulator,name=iPhone 17'

# CLI: full JSON for CI
slopguard-swift analyze --path Sources --json

# CLI: fail CI if any method's CRAP > 50
slopguard-swift analyze --path Sources --fail-over 50

# Run as an MCP server (the primary interface)
slopguard-swift serve --transport stdio
```

## MCP tools

| Tool                                | Purpose                                              |
|-------------------------------------|------------------------------------------------------|
| `analyze_directory`                 | Walk a tree, compute CRAP, cache the report.         |
| `analyze_file`                      | Single-file scan. Use after the agent edits a file.  |
| `get_crap_report`                   | Return the cached report, with server-side filters.  |
| `find_crappy_code`                  | Top-N methods (or types) above threshold.            |
| `get_coverage_gaps`                 | Complex AND undertested — the actionable backlog.    |
| `suggest_refactor_for_crappy_method`| Heuristic, deterministic refactor hints.             |

All tools are flagged `readOnlyHint: true`. The only subprocesses ever spawned are `xcrun xcodebuild` and `xcrun xccov`. See [`SECURITY.md`](SECURITY.md).

## Enterprise-grade

Built for security-conscious orgs that vet what they ship to engineers' laptops:

* **Distribute through the channel your security team already trusts.** Build from source with `swift build -c release` — no extra toolchain to vet beyond the Xcode you already have. Or install through the Homebrew tap (formula pinned by SHA-256, source URL, and version). Or let the Claude Code plugin shim cache a release build on first call. Same binary, three procurement paths.
* **Zero runtime dependencies beyond Xcode.** The only subprocesses slopguard-swift ever spawns are `xcrun xcodebuild` and `xcrun xccov` — both shipped by Xcode, which any Swift / iOS developer already has. Nothing else to install on engineer machines.
* **Minimal, audited dependency tree.** Only three Swift packages — all from upstream Apple swiftlang or the MCP foundation: `swift-syntax` (Apache-2.0), `swift-argument-parser` (Apache-2.0), `swift-sdk` (MIT). Transitive deps (swift-log, swift-nio, swift-system, swift-collections, swift-atomics) are pinned in `Package.resolved` and listed in the SBOM attached to every release.
* **No network, no telemetry, no source mutation.** slopguard-swift never opens an outbound socket, never phones home, never writes outside its own temp directory (which it deletes after each `analyze_*` call).
* **Signed, notarized, and SBOM'd.** Release binaries signed with a Developer ID Application certificate and notarized via `xcrun notarytool`; every artifact ships with a SHA-256 checksum and a CycloneDX 1.5 SBOM (`Scripts/sbom.sh`).
* **Reproducible builds** from the same commit on `macos-14` (modulo notarization timestamps).
* **MIT licensed** ([`LICENSE`](LICENSE)).

Full posture and reporting policy in [`SECURITY.md`](SECURITY.md).

## Architecture

```
.claude-plugin/plugin.json    # Plugin manifest
.mcp.json                     # MCP server config (auto-loaded)
bin/slopguard-swift.sh        # Plugin shim: prebuilt → PATH → swift build fallback
skills/slopguard/SKILL.md     # Skill — when/how the agent should reach for it
Sources/
├── slopguard-core/           # CRAP, models, ComplexityVisitor, DirectoryAnalyzer
├── slopguard-coverage/       # xccov runner, xcresult probe, AnalysisPipeline
├── slopguard-mcp/            # MCP server + 6 tools
└── slopguard-cli/            # ArgumentParser entry: analyze / serve / version
```

All targets build under **Swift 6 strict concurrency**, target **macOS 13+**. Linux support is on the v0.2 roadmap (the analyzer & MCP layers are portable; xccov requires Xcode).

## Development

```bash
swift build
swift test                                                    # 123 unit tests
swift run slopguard-swift analyze --path Sources              # dogfood: own sources
swift run slopguard-swift analyze --path SampleApps/TodoList  # known-good fixture
```

We dogfood slopguard-swift against its own sources *and* against the [`SampleApps/`](SampleApps/) fixtures. The fixtures are deliberately tiny, fully covered, low-complexity packages — running the analyzer against them should always produce the same near-zero CRAP report. Drift against that baseline is a regression signal in the analyzer itself.

## Roadmap

* **v0.1** — Stdio MCP, CLI, full Core + Coverage, notarized release. ✅
* **v0.2** — HTTP transport, Linux build (analyzer + MCP only), SARIF output for GitHub code scanning.
* **v0.3** — Per-PR diff mode (`slopguard-swift diff origin/main…HEAD`), branch-aware caching, Xcode build phase.

## Contributing

Open an issue, open a PR. CI runs on `macos-14` with strict Swift 6 concurrency, and we eat our own dog food (`swift run slopguard-swift analyze --path Sources` is part of the pipeline).
