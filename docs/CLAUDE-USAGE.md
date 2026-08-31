# Claude usage accuracy

Token Bar combines one server-side source with local Claude Code history.
Each source answers a different question.

## Current quota windows

Anthropic's Claude Code OAuth usage endpoint provides the current 5-hour and 7-day percentages.
It can also provide reset times.

Token Bar reads the existing Claude Code OAuth credential from macOS Keychain through `/usr/bin/security`.
It does not ask the user to paste or store another token.

The endpoint can return HTTP 429 after repeated requests.
Token Bar keeps the last successful quota value, marks it stale, and records a cooldown.
Repeated failures increase the fallback cooldown from 15 minutes to 30 minutes and then 60 minutes.
Opening the menu does not bypass that cooldown.

## Local token history

Claude Code writes assistant usage records under:

```text
~/.claude/projects/**/*.jsonl
```

Token Bar reads those files in 1 MB chunks on utility tasks.
The first scan backfills the available calendar year.
Later scans read bytes appended after each saved cursor.

The app stores daily model aggregates, file cursors, and bounded deduplication hashes in `UserDefaults`.
It does not copy raw transcript lines.

## Retention boundary

Claude Code can remove old session files according to its cleanup configuration.
The remaining files may cover only part of the calendar year.

Token Bar shows Today, This Week, and This Month from the available local history.
It hides Claude This Year and All This Year because an incomplete local range cannot represent account-wide annual usage.

Claude Desktop session metadata does not provide a dependable token time series.
Token Bar does not use Claude Desktop as a second history source.

Anthropic's [Claude Code Analytics API](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api) can provide retained daily history for organizations with an Admin API key.
Personal Pro and Max accounts should not be assumed to have that access.

Anthropic's [OpenTelemetry integration](https://code.claude.com/docs/en/monitoring-usage) can preserve future metrics after configuration.
It cannot recover sessions that Claude Code already removed.

## Deduplication boundary

Claude can write the same billed request into more than one transcript or session view.
Token Bar deduplicates positive-usage records with the compound identity `message.id + requestId`, matching request scope instead of treating a reusable message identifier as globally unique.
When both identifiers are absent, the current-window scanner uses a deterministic local record identity and the calendar scanner keeps the record because there is no safe cross-file identity to assert.

The calendar and 7-day scanners share the same compound identity rule and require a scan with no unreadable positive-usage records.
Treat Claude token and dollar values as local estimates.

Anthropic's personal usage response does not expose an account lifetime token counter comparable to the Codex app-server value used by Token Bar.
Claude usage from another computer can raise the official weekly percentage without adding tokens to this Mac's local ledger.
The resulting weekly token capacity and dollar value can therefore be low for multi-device users.

## Price boundary

Claude token records separate input, cache creation, cache reads, and output.
Newer records can split cache creation into 5-minute and 1-hour categories.
Token Bar prices each available category against the current public Claude API table.

The resulting dollars describe API-equivalent value.
They do not describe the user's Claude subscription charge.
