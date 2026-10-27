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

## Verification limits

Actual redemption was not exercised, and the confirmation interaction was not tested through the UI.
A strict signature check can fail after launch because Finder metadata reappears; see [Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html).
