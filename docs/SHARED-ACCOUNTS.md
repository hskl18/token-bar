# Shared accounts

Tested on October 26, 2026 with Claude Code 2.1.311 and Codex CLI 0.164.0 on macOS.
With several Claude or Codex logins, these scripts give every login one shared history and start each session on the login with the most quota left.
Token Bar keeps counting each login's usage separately.

The scripts live in [`scripts/accounts/`](../scripts/accounts/):

| Script | Job |
| --- | --- |
| `cl` | Starts Claude Code, or Codex when called as `cdx`, on the login with the most room |
| `claude-share-projects` | One-time merge of every `~/.claude-*` login's history into `~/.claude` |
| `codex-share-home` | One-time merge of one `~/.codex-*` login's history into `~/.codex` |

## Requirements

- macOS with Python 3.11 or newer as `python3`, such as Homebrew's, and `jq` for the Claude hook.
- Claude Code or Codex CLI on `PATH`.
- Each extra login in its own top-level folder, signed in once:

```sh
CLAUDE_CONFIG_DIR=~/.claude-work claude
CODEX_HOME=~/.codex-work codex login
```

The scripts find the same folders Token Bar finds: `~/.claude-*` folders with `.claude.json` or `.credentials.json`, and `~/.codex-*` folders with `auth.json` or `config.toml`.

## Install

```sh
mkdir -p ~/.local/bin
install -m 755 scripts/accounts/cl scripts/accounts/claude-share-projects scripts/accounts/codex-share-home ~/.local/bin/
ln -sf cl ~/.local/bin/cdx
```

`~/.local/bin` must be on `PATH`; with zsh, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.

Copy the scripts rather than linking them, so a branch switch in this checkout cannot break them.
To pass the same Codex arguments on every `cdx` run, such as one model, edit `CODEX_ARGS` near the top of the installed `cl`.

## Share Claude history

Claude Code transcripts name no account, so after the merge Token Bar needs a record of which login started each session.
Add this hook, with no `matcher`, to `settings.json` in `~/.claude` and in every `~/.claude-*` login, or link those files to one shared `settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "jq -c --arg d \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\" --arg t \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '{sessionId: .session_id, configDir: $d, at: $t}' >> \"$HOME/.claude/account-sessions.jsonl\""
          }
        ]
      }
    ]
  }
}
```

Quit every Claude Code session, then preview and apply:

```sh
claude-share-projects
claude-share-projects --apply
```

The merge moves `projects`, `file-history`, `paste-cache`, and `session-env` from each extra login into `~/.claude` and links them back.
A transcript both logins hold keeps every line from both copies.
For other files that differ, the newer copy wins.
Duplicates and replaced copies move to `~/.claude-share-backup-<time>/`; nothing is deleted.
Credentials, `sessions`, and settings stay with each login.
`--apply` refuses while a Claude Code session runs or while a login lacks the hook, including a hook limited by a `matcher`, since resumed, cleared, and forked sessions also start under another login.

## Share Codex history

Quit every Codex session on the extra login, and quit the Codex desktop app, which can rewrite `config.toml` while it runs.
Then preview and apply:

```sh
codex-share-home ~/.codex-work
codex-share-home ~/.codex-work --apply
```

The folder can be left out when only one extra login exists.
The merge copies threads and session files only the extra login has into `~/.codex`.
It sets Codex's top-level `sqlite_home` setting to `~/.codex` in both logins' `config.toml`, so both open the same databases.
It links `sessions`, `archived_sessions`, `thread-writer-locks`, `history.jsonl`, `session_index.jsonl`, and `.tmp/rollout-maintenance.lock` to `~/.codex`.
Replaced files and the extra login's old databases move to `~/.codex/backups/<login>-share-<time>/`.
It refuses when a thread both logins hold has newer turns on the extra login.
`--apply` stops that login's idle app-server daemon; its package updater keeps running and never opens session data.

Each login keeps `auth.json`, plugins, caches, its daemon, `.tmp`, and its `memories` folder.
Codex 0.164 rejects a linked `memories` folder and a linked `.tmp`.
Each login's memory consolidation catches up from the shared memory database.

Running the script again is safe.
It restores a link that Codex replaced with a file, and it sets aside databases that a Codex process re-created in the extra login when they hold no thread `~/.codex` lacks.

## Start sessions

```sh
cl            # Claude Code
cdx           # Codex
cl --continue
cdx resume --last
```

Both launchers read each login's quota live, from Claude's usage endpoint or from `codex app-server`, which takes about a second.
They pick the login with the most room in its tightest window.
Credit-only logins, such as an Enterprise trial, come last.
When every login is at a limit, they pick the one that frees up first.
A login that cannot be read live uses the newer of its last live reading and Token Bar's.
`cdx` treats a Codex login as blocked when Codex itself would: ordinary usage disallowed without credits, a spend control, a reached limit, or a limit on the model the run uses.

Codex looks a session name up only among the running login's own files, so `cdx resume <name>` and `cdx fork <name>` replace a session name with its ID from the shared database.

## After updates

Claude Code and Codex updates can change what these scripts rely on: where Claude Code keeps each login's credentials, and Codex's `sqlite_home` and linked folders.
There is no need to rerun the merge scripts after every update.
Every `cl` and `cdx` launch checks the shared links, `sqlite_home`, and re-created Codex databases, and prints `shared history needs repair, run <script>` when one is off.
Rerunning that script restores a link an update replaced with a folder or file, keeping what it held in the backup, adds a missing `sqlite_home`, and sets aside a re-created Codex database.
A link that points somewhere else, or a `sqlite_home` naming another folder, has to be fixed by hand; neither script overwrites it.
A pick made from a saved reading instead of a live one ends with `saved reading`, which can mean an update changed how a login is read.
Each launch appends one JSON line to `~/.cache/cl/launch.log` with the pick, the logins read live, and any problems; the file starts over past 1 MB.

## How Token Bar counts shared history

Token Bar reads a linked folder once at its real path.
A Claude record belongs to the login whose `SessionStart` line came last before it; see [Claude usage](CLAUDE-USAGE.md).
A Codex token count belongs to the login whose current weekly reset it records, then to the session's creator; see [Pricing](PRICING.md).

## Limits

- Name rewriting covers session names, not Codex's fallback match on a session's first message; pass the session ID instead.
- Token Bar can assign turns resumed on another Codex login in an earlier week to the session's creator after it rebuilds its ledger.
- Claude sessions copied between logins before the merge count for the login with the newest copy.
- There is no undo command; the backups hold everything the merges moved or replaced.

Return to the [technical documentation](README.md).
