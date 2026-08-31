# Development

## Requirements

- macOS 14 or newer.
- Xcode 26 or newer to compile the macOS 26 Liquid Glass path.
- Claude Code for Claude data.
- Codex CLI or Codex Desktop for Codex data.

Claude and Codex can run independently.
Codex CLI and Codex Desktop are alternate runtimes for one Codex account, so Token Bar never adds their totals together.

## Local build

```sh
./scripts/build-app.sh
open "build/Token Bar.app"
```

The script builds the current Mac architecture and applies an ad-hoc signature.
The build and launch steps do not require administrator access.

Token Bar reads the existing Claude Code credential from the user's login Keychain.
macOS may request the user's login Keychain password or permission.
That prompt grants credential access and does not grant Token Bar administrator privileges.

## Checks

```sh
swift test
./scripts/build-app.sh
codesign --verify --deep --strict "build/Token Bar.app"
plutil -lint "build/Token Bar.app/Contents/Info.plist"
```

These commands verify the source, package, signature structure, and property list.
They do not replace testing on each supported macOS version and architecture.

## Public source release

A source-only public repository does not need Universal 2, Developer ID signing, or Apple notarization.
Users can clone the repository and build the app locally.

Do not present the current ad-hoc, host-architecture build as a trusted downloadable release.
Follow the [distribution guide](DISTRIBUTION.md) before attaching a prebuilt app to GitHub Releases.
