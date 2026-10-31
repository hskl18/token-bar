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
Extra accounts carry their own `ProviderSnapshot`, keyed by Claude account and organization or by Codex configuration directory.
`TokenActivity` contains Claude local-day totals and Codex account totals by UTC day; extra Codex accounts keep their own with their folder's `CostLedger`.
`retiredCodexCostLedger` prices Codex usage ledgers no current login reads; a folder's ledger saved for another login is set aside there before its ledger starts over.
`CostLedger` contains day-specific local model and token-category prices.
For each Codex UTC day, observed tokens supply a local floor while the account bucket is absent or still smaller.
Claude's `WeeklyCapacityHistory` contains a bounded set of derived 7-day capacity observations.
`ImageGenerationUsage` contains saved-file-based estimates, separate from provider token activity.

These values remain separate because an official quota percentage is not a token counter and an API-equivalent dollar estimate is not a bill.

Codex CLI and Codex Desktop are alternate app-server runtimes for one provider.
Runtime discovery uses `CODEX_BIN`, the remembered working executable, `PATH`, common CLI locations, and Launch Services bundle lookup.
Token Bar tries the next candidate when a runtime is missing or incompatible, and never sums multiple Codex runtimes.
A sign-in error belongs to the account, so it ends the search instead of trying another runtime.

## Accounts

The primary accounts are `~/.claude` and `~/.codex`.
Extra accounts come from `~/.claude-*` and `~/.codex-*` folders that contain a known configuration file, plus `CLAUDE_CONFIG_DIR` and `CODEX_HOME` from the launch environment.
Discovery lists only the home folder's top level; it does not search deeper or read unrelated files.
Each Codex account runs its own app-server child with `CODEX_HOME` set, inherited credential variables removed, and analytics disabled.
Folders the server reports as the same login share one quota request and appear once, preferring a fresh reading.
Their local records share one incremental ledger, and each refresh scans that account's calendar and weekly window once.
Activity selection uses its own successful-read timestamp rather than the freshness of the quota row.
Claude folders signed in to the same login appear once, read with the first folder's credential, and their sessions share that login's weekly window scan.
Extra accounts add quota rows, a weekly estimate from their login's local sessions, and their usage to the activity cards.
Accounts can also share one history through linked folders; see [Shared accounts](SHARED-ACCOUNTS.md).

The presentation layer derives one of four states from displayable provider data: none, Claude-only, Codex-only, or both.
Any account of a provider counts, so a provider whose only signed-in login is an extra folder still shows its activity, header, and All.
A header and All are marked stale when any account whose percentage they include is stale.
Only the dual-provider state renders All, and each state has its own compact panel height.
Both providers show every returned quota window, and the panel grows for extra rows until it reaches 85% of the screen height, after which the quota area scrolls.
The UI lists 5-hour rows, then Weekly rows, then any others, keeping account order and the main Codex bucket first.
The parser retains the server's `limitName` for presentation.
A missing 5-hour window is never inferred from the plan name; Plus, Pro, and future plans follow the account response.
Provider headers and All weight each account's weekly percentage by its estimated weekly tokens; see [combined percentage](PRICING.md#combined-percentage).

The status item owns a native `NSMenu` containing the SwiftUI view.
AppKit handles menu tracking and dismissal, and the app refreshes stale data when the menu opens.
Opening the menu does not synchronously read Keychain; a stale Claude credential may be read by the background refresh.
FSEvents watches every account's session directories plus saved Codex images.
Relevant changes are coalesced for 20 seconds, and event-triggered refreshes run at most once per account every three minutes.
Only the changed account is refreshed; account requests retain the three-minute freshness limit and Claude rate-limit cooldown.
A 30-minute background refresh covers quota resets, remote devices, and missed file events; the refresh button remains immediate.
The root SwiftUI view leaves the outer background to the native menu to avoid stacked glass borders.
The quota card stays outside the scroll view so scrolling moves the rows without moving its concentric background.
The scroll viewport fills the card, with separate content and indicator margins and a rounded clip so indicators do not cover account values.

## Transcript parsing

`ClaudeMixSampler` owns the available calendar-year Claude ledger.
`ClaudeWindowSampler` owns the current official Claude weekly interval.
Both use the same Claude record parser and the same `message.id + requestId` identity.
The parser keeps per-message token maxima so later streamed snapshots add only their positive deltas.
A linked `projects` folder is read once at its real path, and `ClaudeSessionOwners` splits its records by account using `~/.claude/account-sessions.jsonl`.

`CodexTranscriptParser` owns Codex schema interpretation, token delta normalization, model context, stable identity, and fork/subagent copied-history suppression.
`CodexWindowSampler` uses it for the current official weekly interval.
`CodexMixSampler` uses it for the available calendar year.
Both Codex samplers scan `sessions` and `archived_sessions`, and pricing keys record each request's speed tier and long-context use.
`CodexThreadTable` adds threads whose rollout files are gone to both samplers' results, less the cumulative total each session's last scan read.
A linked `sessions` folder is read once at its real path, each token count goes to the login whose current weekly reset it records, and the thread table follows a top-level `sqlite_home`.

Sharing the parser keeps local schema interpretation consistent.
Account and local sources can still differ in scope and timing; see [pricing limits](PRICING.md#limits).

## Pricing

`PriceCatalog` resolves public prices, freezes the first rates resolved for each day, and produces day-specific `CostMix` values.
The UI asks the store for a period cost, and the store merges only cost rows belonging to that period.
Unknown models remain visible as tokens.
The affected dollar value remains available only when known prices cover at least 99.9% of the period sample; otherwise it is unavailable.

## Failure isolation

- Claude and Codex provider requests run independently.
- Codex quota and account-activity results are independent even though they share one app-server process.
- Local calendar scans and current-window scans keep separate persisted cursors.
- Network and parse failures preserve prior successful snapshots.
- Cancelling a refresh terminates its Codex app-server child and skips the remaining runtimes; spending a reset credit cannot be cancelled.
- Claude HTTP 401 can trigger one CLI renewal before reporting failure; see [credential recovery](CLAUDE-USAGE.md#credential-recovery).
- Fetch and local-scan failures turn the footer time yellow, with details in its tooltip.
- Price refresh failure preserves the last-known-good catalog.
- Cached structures add new fields as optional values or move to a new storage key when counting semantics change.

## Persistence and performance

The app reads JSONL files in 1 MiB chunks on utility tasks.
Transcript ledgers are atomic JSON files under Application Support, written once per completed scan.
Launch removes weekly window ledgers whose reset time has passed and keeps calendar ledgers, which can hold history whose source files are gone.
Snapshots, prices, and bounded capacity samples stay in `UserDefaults`.
It does not retain raw transcript text.
Activity cards and their tooltips reuse one in-memory summary per provider and calendar period.
Reconciled Codex account activity is also reused across periods until the snapshot changes.
Snapshot changes clear these summaries, and a new calendar interval replaces its period's entry.
Day-key parsing uses a process-local `NSCache` with an 800-entry target to reuse dates across period queries.

`StorageKeys` is the single registry for persisted Token Bar state.
Launch migration imports only the reusable snapshot from QuotaBar Lite and removes superseded Token Bar cache generations from the current preference domain.
The original legacy application domain is left untouched.

Unchanged refreshes seek directly to saved byte offsets.
The ImageGen sampler runs for Codex activity and fallback refreshes, reads PNG headers/end markers and caches records by generation ID without decoding pixels.
A removed source file drops its cursor while retaining counted usage.
A truncated file is reread from the start, and persisted identities prevent double counting.

An October 11, 2026 arm64 release build measured 2.3 MB on an M3 Pro MacBook Pro.
Five two-second idle samples after refresh, with two Claude and two Codex accounts, measured 0.0% to 1.2% CPU and about 29 MiB resident memory with the panel closed.
The first scan of a large history can take several seconds, while unchanged refreshes resume from saved offsets.
These measurements describe one machine and dataset rather than a cross-app benchmark.

## Maintenance rules

- Add new provider quota buckets generically by stable `limit_id`; do not hard-code a fixed bucket count.
- Add model prices through official provider parsing first and the fallback catalog second.
- Do not map an unknown model to a convenient known model unless the provider documents that exact alias.
- Do not convert official quota percentage into exact tokens without preserving the estimate boundary.
- Keep schema-specific compatibility code inside the relevant client or parser, not in SwiftUI views.
- Remove superseded estimators after persisted-state migration instead of running two formulas in parallel.
