# Token Bar

A native macOS menu bar monitor for Claude Code and OpenAI Codex.

**macOS 14+ · Swift 5.10 · MIT**

<p align="center">
  <img src="docs/screenshots/token-bar-dashboard.png" alt="Token Bar with two Claude and two Codex accounts, using synthetic data" width="280">
</p>

## At a glance

- 🟠 Claude quota windows and local token estimates
- 🔵 Codex quota windows and account activity
- 🟠🔵 Extra Claude and Codex accounts in their own quota rows
- ⚪ Capacity-weighted combined usage
- 🟠 Last-known values when a provider becomes stale
- 🔒 Local aggregation without raw transcript uploads
- 🧊 Liquid Glass on macOS 26 with a Material fallback

The dollar values show API-equivalent estimates, not subscription charges.
The screenshot uses local synthetic preview data.

## Build from source

Install Xcode 26 or newer, then run:

```sh
./scripts/build-app.sh
open "build/Token Bar.app"
```

The build creates a Finder-openable app bundle.
Opening it shows the usage panel, including when the app is already running.
To keep a copy on the Desktop, copy `build/Token Bar.app` there in Finder and double-click it.

Sign in to Claude Code, Codex CLI, or Codex Desktop before refreshing Token Bar.
Extra accounts in `~/.claude-*` and `~/.codex-*` folders appear automatically; see [Architecture](docs/ARCHITECTURE.md#accounts).
To share one history across those accounts and start each session on the one whose quota should be used first, see [Shared accounts](docs/SHARED-ACCOUNTS.md).
Token Bar uses the installed Claude CLI to renew expired sign-ins and to start idle 5-hour windows; see [Claude usage](docs/CLAUDE-USAGE.md).
Building and running the app does not require administrator access.
macOS may request access to the user's login Keychain for Claude usage data.

## How it works

Token Bar keeps provider quotas, local activity, and pricing as separate values.
One provider can fail without taking down the other or erasing its last successful reading.

🟠 Claude · 🔵 Codex · ⚪ available and All · 🟡 gauge center · 🟠 stale

Read the technical notes in [`docs/`](docs/README.md):

- [Accuracy and pricing](docs/PRICING.md)
- [Claude data boundaries](docs/CLAUDE-USAGE.md)
- [Architecture and performance](docs/ARCHITECTURE.md)
- [Local development](docs/DEVELOPMENT.md)
- [Design system](docs/DESIGN.md)
- [Subscription preview gallery](docs/SUBSCRIPTION-PREVIEWS.md)
- [Signed distribution](docs/DISTRIBUTION.md)

## Contributing

Issues and pull requests are welcome; for a number that looks wrong, include the displayed value, the expected value, and a source.
Leave out credentials, tokens, and private transcript content.

## License

[MIT](LICENSE)

Token Bar is not affiliated with Anthropic, OpenAI, Bandai Namco, or Sunrise.
