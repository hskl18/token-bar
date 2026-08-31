# Distribution

The current `scripts/build-app.sh` output is an arm64 app with an ad-hoc signature.
It is suitable for local development, not a trusted public download.

Apple requires an active [Apple Developer Program](https://developer.apple.com/programs/whats-included/) membership for Developer ID certificates.
Choose a permanent bundle identifier before the first public release and update the version in `Resources/Info.plist`.

## Release flow

1. Build arm64 and x86_64 release executables from the same source and deployment target.
2. Combine them into one Universal 2 executable.
3. Sign the app with Developer ID Application, Hardened Runtime, and a secure timestamp.
4. Submit a ZIP, DMG, or PKG with `notarytool`.
5. Staple the accepted ticket and verify Gatekeeper acceptance.
6. Repack the stapled app, generate a SHA-256 checksum, and attach both files to a GitHub Release.

Apple's [Universal binary guide](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary), [Developer ID guide](https://developer.apple.com/support/developer-id/), and [notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) define the platform requirements.

## Universal 2

Build both slices, combine them with `lipo -create`, and place the result at:

```text
build/Token Bar.app/Contents/MacOS/TokenBar
```

Verify the result:

```sh
lipo -archs "build/Token Bar.app/Contents/MacOS/TokenBar"
```

The output must contain `arm64` and `x86_64`.
Test both slices on representative hardware or run the Intel slice through Rosetta on Apple Silicon.

## Developer ID signing

Create and install a Developer ID Application certificate, then sign the final bundle:

```sh
APP="build/Token Bar.app"
IDENTITY="Developer ID Application: Your Name (TEAMID)"

codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP"
```

The details must show your Developer ID authority and Team ID instead of `Signature=adhoc`.

## Notarization

Store credentials in Keychain rather than a script:

```sh
xcrun notarytool store-credentials "tokenbar-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Create the submission archive and wait for Apple's result:

```sh
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent \
  "build/Token Bar.app" "dist/Token-Bar-notarization.zip"

xcrun notarytool submit "dist/Token-Bar-notarization.zip" \
  --keychain-profile "tokenbar-notary" --wait
```

Continue only after the status is `Accepted`.
Use `xcrun notarytool log` with the submission ID if Apple rejects the archive.

Staple and verify the ticket:

```sh
xcrun stapler staple "build/Token Bar.app"
xcrun stapler validate "build/Token Bar.app"
spctl --assess --type execute --verbose=4 "build/Token Bar.app"
```

## GitHub Release

Recreate the archive after stapling and publish its checksum:

```sh
ditto -c -k --sequesterRsrc --keepParent \
  "build/Token Bar.app" "dist/Token-Bar-macos-universal.zip"

shasum -a 256 "dist/Token-Bar-macos-universal.zip" > "dist/SHA256SUMS"
shasum -a 256 -c "dist/SHA256SUMS"
```

Create a version tag such as `v0.1.0` and attach the ZIP plus `SHA256SUMS` to the matching [GitHub Release](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
Release notes should state the supported macOS versions, architectures, estimate boundary, and major changes.

Use GitHub Actions after the local release path works end to end.
Store the certificate, certificate password, App Store Connect API key, issuer ID, key ID, and Team ID in GitHub Secrets.
Import signing material into a temporary Keychain and remove it in an unconditional cleanup step.

## Release gate

- The bundle identifier and version match the Git tag.
- `lipo` reports arm64 and x86_64.
- `codesign --verify --deep --strict` succeeds.
- `notarytool` reports `Accepted`.
- `stapler validate` and `spctl --assess` succeed.
- The release contains the stapled archive and a verified checksum.
- A browser-downloaded artifact launches with quarantine enabled on a clean supported Mac.
- No credentials, transcripts, caches, or local agent files appear in the source or archive.
