# Weekly reset credits

Researched on October 22, 2026 against Codex CLI 0.163.0 and Claude Code 2.1.309.
These are consumable opportunities to clear usage limits, separate from the next scheduled reset time.

## Codex

The [official app-server protocol](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt) returns `rateLimitResetCredits.availableCount` from `account/rateLimits/read`.
The count belongs to the account selected by that child process's `CODEX_HOME`.
It is authoritative even when the detail list is missing, empty, or shorter than the count.
The installed CLI's generated schema confirms that `excludeResetCreditDetails: true` skips the extra detail lookup while retaining the count, so background polls keep that flag.
A missing summary is unknown, rather than zero.

Both local Codex configurations returned `availableCount: 2` during the read-only research.
No reset was consumed.

## Claude

Claude's [limit-reset documentation](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset) confirms that grants can refill either a session limit or weekly limits, and may expire.
The installed Claude CLI reads grants from `cedar_ember` in `GET /api/oauth/usage?cedar_ember=1`.
Its request identifies the CLI platform and installed CLI version.
This is an observed CLI protocol, rather than a documented public Anthropic API contract.

Token Bar requests that block with its existing quota read and sums `resets_left` only for unpaused grants that have started, have not expired, and clear the main `seven_day` window.
Grants that only give back a model's weekly usage do not promise to reset the full weekly percentage to zero and are excluded.
An explicit `ineligible_reason: no_grant` means zero.
Missing or malformed data, unsupported surfaces, and other eligibility reasons remain unknown.
The primary Claude account returned `no_grant` during research.

If a server rejects the query with HTTP 400, 404, or 422, Token Bar retries the ordinary usage URL once.
HTTP 429 never triggers that fallback and retains the existing cooldown.

## Display

The main Weekly row places `Reset N` beside the scheduled reset countdown, aligned with the percentage above it.
Zero, unknown, and stale counts are hidden.
The button opens an account-specific confirmation before using one reset.
Session windows, model-specific weekly windows, activity estimates, and combined percentages keep their existing presentation and calculations.

## Redemption

Confirmation names the account and configuration directory.
Cancel sends no redemption request.
Only one reset can run at a time, and refreshes pause during confirmation and redemption.
The client checks that the account in the selected directory still matches the account that was confirmed.

Codex uses the documented `account/rateLimitResetCredit/consume` method with a fresh idempotency key.
It uses one runtime and does not retry an uncertain spend through another runtime.
Claude rereads the grants, selects an active full weekly reset, and uses the installed CLI's `reset_rate_limits` request shape with its grant and request identifiers.
Neither provider's spend request is automatically retried.

Before sending a spend, Token Bar invalidates the saved reset-count freshness so a quit cannot restore a usable old button.
Success and failure both schedule a refresh of the selected account, respecting existing rate-limit cooldowns.
Reset credits were not consumed to verify this implementation.

## Local verification

All 21 existing tests passed after the final source changes.
The release build completed and the Desktop bundle matches the build output in a recursive comparison.
Strict signature verification passes after clearing the bundle's FinderInfo metadata, but that metadata reappears after launch in this environment, so the post-launch strict result is not stable.
This metadata restriction is described in [Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html).
The restarted app's saved snapshot confirmed fresh, identity-bound counts of 2 for Codex and Codex-cli and 0 for Claude and Claude-z.
Claude-x did not return a confirmed count and remains hidden.
The native UI tool timed out, so visual placement and the confirmation interaction were not manually verified.
Actual redemption was not exercised.

### Responsiveness follow-up, October 23

The user reported severe scrolling and clicking lag after this build.
The earlier build and data checks did not establish interactive performance.
Quota rows now receive cached values and actions without subscribing individually to the whole store.
The installed CLI version is resolved once in a shared utility task, and reset confirmation closes the menu before entering the alert's modal loop.
All 21 existing tests and the release build passed after these changes.
Passive samples before and after the changes captured idle event loops, not the reported scrolling failure.
The native UI tool timed out again, so the cause and resolution of the scrolling lag remain unconfirmed.
The user subsequently requested code inspection and background sampling only.
The follow-up moves the quota card outside the scroll view and reuses activity totals across cards and tooltips for each snapshot and calendar period.
Reset metadata now arrives through the normal quota refresh without forcing an extra startup refresh.
The 21 existing tests still pass; no UI interaction or reset redemption was performed for this follow-up.
A startup sample captured activity date parsing on the main thread during the initial card render.
Parsed day dates now use a shared `NSCache`, separated by formatter time zone, while the UTC-noon and local-day assignment rules remain unchanged.
Two separate 20-second startup samples recorded 107 and 11 main-thread `DateFormatter.dateFromString` samples before and after the day cache, respectively.
The earlier sample already includes the summary cache and fixed quota background; this comparison does not measure scrolling frame rate or input latency.
