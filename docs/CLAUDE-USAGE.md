# Claude usage accuracy

Token Bar combines server-side quota for each Claude account with local Claude Code history.
Each source answers a different question.

## Current quota windows

Anthropic's Claude Code OAuth usage endpoint provides the current 5-hour and 7-day percentages.
It can also provide reset times, model-specific weekly windows, and an enabled usage-credit allowance.
The allowance has no reset time, so Token Bar uses the start of the next UTC month, which claude.ai shows for a monthly spend limit, unless a `spend` limit row names one.

Token Bar reads the existing Claude Code OAuth credential from macOS Keychain through `/usr/bin/security`.
It does not ask the user to paste or store another token.
An extra account in a `~/.claude-*` folder uses that folder's own Keychain entry, as Claude Code does for `CLAUDE_CONFIG_DIR`.

The endpoint can return HTTP 429 after repeated requests.
Token Bar keeps the last successful quota value, marks it stale, and records a cooldown.
Repeated failures increase the fallback cooldown from 15 minutes to 30 minutes and then 60 minutes.
Opening the menu does not bypass that cooldown.

## Credential recovery

After HTTP 401, Token Bar rereads the account's credential in case Claude Code already renewed it.
If the token is unchanged, it runs the installed `claude --safe-mode` in a background terminal, which renews OAuth without sending a prompt, and retries once.
It stops the CLI after renewal or 15 seconds and tries at most once every five minutes per account.
HTTP 403 and 429 never start the CLI.
Token Bar looks for `claude` on `PATH` and in `~/.local/bin`, `/opt/homebrew/bin`, and `/usr/local/bin`, so Finder launches find common installations.

## Starting 5-hour windows

A 5-hour window starts with its first request, so an idle window reports no current reset time.
When a refresh finds an idle window and Weekly usage below 100%, Token Bar sends one minimal prompt through the installed CLI:

```sh
claude -p hi --model haiku --effort low --settings '{"alwaysThinkingEnabled":false}' --safe-mode --strict-mcp-config --system-prompt 'Reply with one word.' --no-session-persistence --max-turns 1 --tools ''
```

The flags skip user customizations, tools, thinking, and transcripts, so the prompt stays small and never enters local history.
Each start still counts against the account's usage limits.
Anthropic's [credential-use policy](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) reserves subscription OAuth for ordinary Claude Code use, so Token Bar runs the unmodified CLI instead of calling the API with stored credentials.
Each account tries at most once every 15 minutes, and a refresh one minute after each 5-hour reset starts the next window while the Mac is awake.

## Local token history

Claude Code writes assistant usage records under:

```text
~/.claude/projects/**/*.jsonl
~/.claude-*/projects/**/*.jsonl
```

Token Bar reads those files in 1 MB chunks on utility tasks.
Activity cards sum every Claude folder's history, and each extra account's own `projects` folder also supplies its weekly estimate.
The first scan backfills the available calendar year.
Later scans read bytes appended after each saved cursor.

The app stores daily model aggregates, file cursors, and deduplication state in JSON files under Application Support.
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
Later streamed snapshots of a message add only their positive token deltas, and `usage.iterations` is summed when present.
When both identifiers are absent, the current-window scanner uses a deterministic local record identity and the calendar scanner keeps the record because there is no safe cross-file identity to assert.

The calendar and 7-day scanners share the same compound identity rule and require a scan with no unreadable positive-usage records.
Treat Claude token and dollar values as local estimates.

Anthropic's personal usage response does not expose an account lifetime token counter comparable to the Codex app-server value used by Token Bar.
Claude usage from another computer can raise the official weekly percentage without adding tokens to this Mac's local ledger.
The resulting weekly token capacity and dollar value can therefore be low for multi-device users.

## Price boundary

Claude token records separate input, cache creation, cache reads, and output.
Newer records can split cache creation into 5-minute and 1-hour categories.
Token Bar prices each available category at the public Claude API rate first seen for that model and day, including fast-mode rates for requests marked `speed: "fast"`.

The resulting dollars describe API-equivalent value.
They do not describe the user's Claude subscription charge.
