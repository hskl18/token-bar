# Architecture

Token Bar keeps provider quota, local transcript aggregation, pricing, and presentation as separate layers.
A schema failure in one layer must not terminate the process or erase a last-known-good value from another layer.

## Runtime flow

```text
Claude OAuth endpoint ─┐
                      ├─ ProviderSnapshot ───────────────┐
Codex app-server ─────┘                                  │
                                                         ├─ AppSnapshot ─ SwiftUI panel
Claude JSONL ─ Claude samplers ─ MixLedger/TokenActivity ┤
Codex JSONL ─ shared parser ─ window/year ledgers ───────┤
Official prices + fallback ─ PriceCatalog ─ CostLedger ──┘
```

`ProviderSnapshot` contains official percentages, reset times, connection state, cooldowns, and freshness.
`TokenActivity` contains calendar token totals.
`CostLedger` contains day-specific local model and token-category prices.
`WeeklyCapacityHistory` contains a bounded set of derived 7-day capacity observations.

These values remain separate because an official quota percentage is not a token counter and an API-equivalent dollar estimate is not a bill.

Codex CLI and Codex Desktop are alternate app-server runtimes for one provider.
Runtime discovery uses `CODEX_BIN`, the remembered working executable, `PATH`, common CLI locations, and Launch Services bundle lookup.
Token Bar tries the next candidate when a runtime is missing, incompatible, or signed out, and never sums multiple Codex runtimes.

The presentation layer derives one of four states from displayable provider data: none, Claude-only, Codex-only, or both.
Only the dual-provider state renders All, and each state has its own compact panel height.
Codex shows every returned quota window and expands the panel for additional rows.
The UI groups rows by quota bucket, places the main Codex bucket first, and orders each bucket by duration.
The parser retains the server's `limitName` for presentation; older cached Spark windows use a known-name fallback.
A missing 5-hour window is never inferred from the plan name; Plus, Pro, and future plans follow the account response.
Provider headers and combined capacity continue to use the weekly percentage.

The status item owns a native `NSMenu` containing the SwiftUI view.
AppKit handles menu tracking and dismissal, and the app refreshes stale data when the menu opens.
The root SwiftUI view leaves the outer background to the native menu to avoid stacked glass borders.

## Transcript parsing

`ClaudeMixSampler` owns the available calendar-year Claude ledger.
`ClaudeWindowSampler` owns the current official Claude weekly interval.
Both use the same Claude record parser and the same `message.id + requestId` identity.

`CodexTranscriptParser` owns Codex schema interpretation, token delta normalization, model context, stable identity, and fork/subagent copied-history suppression.
`CodexWindowSampler` uses it for the current official weekly interval.
`CodexMixSampler` uses it for the available calendar year.

Keeping Codex schema interpretation in one parser prevents calendar dollars and weekly capacity from drifting into different counting rules.

## Pricing

`PriceCatalog` resolves current public prices once and produces day-specific `CostMix` values.
The UI asks the store for a period cost, and the store merges only cost rows belonging to that period.
Unknown models remain visible as tokens.
The affected dollar value remains available only when known prices cover at least 99.9% of the period sample; otherwise it is unavailable.

## Failure isolation

- Claude and Codex provider requests run independently.
- Codex quota and account-activity results are independent even though they share one app-server process.
- Local calendar scans and current-window scans keep separate persisted cursors.
- Network and parse failures preserve prior successful snapshots.
- Price refresh failure preserves the last-known-good catalog.
- Cached structures add new fields as optional values or move to a new storage key when counting semantics change.

## Persistence and performance

The app reads JSONL files in 1 MiB chunks on utility tasks.
It stores compact aggregates, offsets, bounded hashes, and bounded capacity samples in `UserDefaults`.
It does not retain raw transcript text.

`StorageKeys` is the single registry for persisted Token Bar state.
Launch migration imports only the reusable snapshot from QuotaBar Lite and removes superseded Token Bar cache generations from the current preference domain.
The original legacy application domain is left untouched.

Unchanged refreshes seek directly to saved byte offsets.
A truncated or removed source file invalidates the affected local ledger and triggers a deterministic rebuild instead of applying deltas to the wrong history.

An August 30, 2026 arm64 release build measured 1.8 MB on an M3 Pro MacBook Pro.
Five two-second idle samples after refresh measured 0.0% CPU and 52.0 MiB resident memory with the panel closed.
The first scan of a large history can take several seconds, while unchanged refreshes resume from saved offsets.
These measurements describe one machine and dataset rather than a cross-app benchmark.

## Maintenance rules

- Add new provider quota buckets generically by stable `limit_id`; do not hard-code a fixed bucket count.
- Add model prices through official provider parsing first and the fallback catalog second.
- Do not map an unknown model to a convenient known model unless the provider documents that exact alias.
- Do not convert official quota percentage into exact tokens without preserving the estimate boundary.
- Keep schema-specific compatibility code inside the relevant client or parser, not in SwiftUI views.
- Remove superseded estimators after persisted-state migration instead of running two formulas in parallel.
