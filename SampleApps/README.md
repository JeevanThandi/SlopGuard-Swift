# SampleApps

Reference fixtures used to benchmark slopguard-swift's analyzer against
known-good Swift code. Each app is a standalone Swift package — not a target
of the main `slopguard-swift` package — so its build state never affects the
parent project.

| Fixture | Shape | Expected baseline |
|---|---|---|
| `TodoList/` | Tiny logic-only package: `Todo`, `TodoFilter`, `TodoStore`. No UI. | Zero crappy methods at threshold 30, weighted coverage ≥ 95%. |

## Why these exist

Without a stable known-clean codebase, every slopguard-swift report is a
mystery diff: a regression in the complexity counter or coverage join would
ride along undetected through the dogfood numbers because the dogfood
codebase keeps changing. SampleApps gives us a fixture that *doesn't* change
between releases — any drift in the report against it points at the analyzer,
not the app.

## Running slopguard-swift against a fixture

From the repo root, after building the release binary:

```bash
swift build -c release --product slopguard-swift
.build/release/slopguard-swift analyze --path SampleApps/TodoList
```

Or via `swift run` directly inside the fixture (uses the fixture's own
`swift test` to gather coverage):

```bash
cd SampleApps/TodoList
swift test --enable-code-coverage
```

## Adding a new fixture

1. Make a new directory under `SampleApps/`.
2. Give it its own `Package.swift` (no shared targets with the parent).
3. Keep it logic-only — UI views can't be unit-covered without UI tests, and
   that pollutes the coverage number we benchmark against.
4. Add a row above describing its expected baseline.
