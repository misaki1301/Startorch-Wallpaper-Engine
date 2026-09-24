# Releasing StarTorch Wallpaper Engine

This document describes how the `.github/workflows/release.yml` workflow
builds, signs, notarizes, and packages the app, and what a maintainer needs
to set up once to enable notarized releases.

## How releases work

Pushing a tag matching `v*` (e.g. `v1.2.0`), or running the workflow
manually via **Actions → Build & Distribute → Run workflow**, triggers a
build that:

1. Builds a **universal binary** (`arm64` + `x86_64`) in Release
   configuration.
2. If Developer ID signing secrets are configured (see below), archives,
   signs with a Developer ID Application certificate, and **notarizes**
   the app with Apple, then staples the notarization ticket to the app
   and the DMG.
3. If those secrets are **not** configured, falls back to an ad-hoc signed,
   unsigned-for-Gatekeeper-purposes build so the workflow still succeeds —
   the release is clearly labeled "unsigned" in the GitHub Release notes
   and artifact name. This fallback build is compiled with
   `CODE_SIGNING_ALLOWED=NO`, so it runs without the App Sandbox and
   stores its data in `~/Library/Application Support` instead of the
   app's sandbox container — meaning favorites and settings will **not**
   carry over if you later switch to a notarized build (or vice versa).
4. Packages the app as both a `.zip` and a `.dmg` (with an `/Applications`
   symlink) and uploads them as workflow artifacts. On a tag push, it also
   publishes (or updates) a GitHub Release with both files attached.

Only a tag push (`refs/tags/v*`) creates/updates a GitHub Release;
`workflow_dispatch` runs just produce build artifacts for inspection.

## One-time setup: Developer ID signing + notarization

To produce notarized releases (recommended — required for a clean
Gatekeeper experience on macOS 15+, since right-click → Open no longer
bypasses the quarantine warning), a repository admin needs to create a
Developer ID Application certificate and an App Store Connect API key,
then add six repository secrets.

### 1. Create a Developer ID Application certificate

You need an active Apple Developer Program membership for team
`B97JTSGWZ2`.

1. In Xcode: **Settings → Accounts → (your Apple ID) → Manage Certificates
   → + → Developer ID Application**. Xcode creates the certificate and
   installs it (with its private key) in your login keychain.
   (Alternatively, create it at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
   using a CSR generated via Keychain Access, then download and
   double-click the resulting `.cer` to import it.)
2. Export the certificate **and its private key** as a `.p12` file:
   - Open **Keychain Access**, find "Developer ID Application: ... (B97JTSGWZ2)".
   - Right-click it → **Export...** → format **Personal Information
     Exchange (.p12)**.
   - Set a strong export password — this becomes `MACOS_CERT_PASSWORD`.
3. Base64-encode the `.p12` for storage as a GitHub secret:
   ```bash
   base64 -i DeveloperIDApplication.p12 | pbcopy
   ```
   This clipboard contents become `MACOS_CERT_P12_BASE64`.

### 2. Create an App Store Connect API key (for notarization)

Notarization uses a separate App Store Connect API key (not the signing
certificate).

1. Go to [App Store Connect → Users and Access → Integrations → App Store
   Connect API](https://appstoreconnect.apple.com/access/api).
2. Create a new key with at least the **Developer** role.
3. Note the **Key ID** and **Issuer ID** shown on that page —
   these become `NOTARY_API_KEY_ID` and `NOTARY_API_ISSUER_ID`.
4. Download the private key file (`AuthKey_<KeyID>.p8`) — **Apple only
   lets you download this once**, so store it safely.
5. Base64-encode it:
   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
   This becomes `NOTARY_API_KEY_P8_BASE64`.

### 3. Add the repository secrets

In **Settings → Secrets and variables → Actions → New repository
secret**, add:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | Base64 of the exported `.p12` certificate |
| `MACOS_CERT_PASSWORD` | The export password chosen in step 1.2 |
| `NOTARY_API_KEY_ID` | App Store Connect API key ID |
| `NOTARY_API_ISSUER_ID` | App Store Connect API issuer ID |
| `NOTARY_API_KEY_P8_BASE64` | Base64 of the downloaded `AuthKey_*.p8` |
| `KEYCHAIN_PASSWORD` | Any strong random string — only used to protect the temporary CI keychain for the duration of the job |

Once all six secrets are present, the next tag push produces a fully
signed and notarized release automatically. Until then, releases build
successfully but are clearly marked "unsigned".

## Cutting a release

1. Make sure `main` (or the release branch) is green on the `Build & Test`
   workflow.
2. Update the version if you track one in the project (optional — the
   workflow derives the DMG/zip version from the git tag).
3. Tag and push:
   ```bash
   git tag v1.2.0
   git push --tags
   ```
4. Watch the **Build & Distribute** workflow run in the Actions tab. On
   success it publishes a GitHub Release at
   `https://github.com/misaki1301/startorch-wallpaper-engine/releases`
   with the `.zip` and `.dmg` attached.

## Verifying a release locally

To confirm a downloaded build is genuinely notarized and universal:

```bash
# Universal binary check
lipo -archs "/Applications/StarTorch Wallpaper Engine.app/Contents/MacOS/StarTorch Wallpaper Engine"
# → should print: x86_64 arm64

# Gatekeeper / notarization check
spctl -a -vv "/Applications/StarTorch Wallpaper Engine.app"
# → should say "accepted" and "source=Notarized Developer ID"

xcrun stapler validate "/Applications/StarTorch Wallpaper Engine.app"
# → should say "The validate action worked!"
```

## Local testing of the packaging scripts

Both scripts used by the release workflow can be run locally against a
Release build without needing CI:

```bash
# Universal Release build (unsigned, for local testing only)
xcodebuild clean build \
  -scheme "ikuyo-live-wallpaper" \
  -project "StarTorch Wallpaper Engine.xcodeproj" \
  -configuration Release \
  -derivedDataPath /tmp/dd-release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO

APP="/tmp/dd-release/Build/Products/Release/StarTorch Wallpaper Engine.app"
lipo -archs "$APP/Contents/MacOS/StarTorch Wallpaper Engine"

# Build the DMG
scripts/make-dmg.sh "$APP" 0.0.0-local /tmp/dist
```

## Future work: Sparkle auto-updates

The app does not yet ship an auto-update mechanism. Adding
[Sparkle](https://sparkle-project.org) (an `appcast.xml` published
alongside releases, plus the `SUFeedURL`/EdDSA-signing setup) is a
reasonable follow-up once notarized releases are flowing, but is out of
scope for this phase.
