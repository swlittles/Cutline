# Releases and updates

`dev` is the local development branch. `main` supplies release/download builds after its full macOS CI passes. Default local packaging produces `dist/Cutline Dev.app`; a release creates `release-build/Cutline.app` and leaves the local Dev app alone.

## Publish a change

1. Work on `dev` and run the appropriate tests. Merge reviewed changes into `main`.
2. For a new release, increment `VERSION` and the monotonically increasing `BUILD_NUMBER`, and update `docs/RELEASE_NOTES.md`.
3. Push `main`. After `macOS tests` succeeds, `Publish macOS release` checks that the exact commit is still current, builds both architectures, packages the app, signs the update feed, and publishes the GitHub Release.
4. Check the release workflow and download artifacts. An existing public version is never overwritten. Documentation-only changes with unchanged version numbers do not republish.

Manual workflow dispatch also requires successful CI for the current main commit. `RELEASE_MODE` is a repository variable: `signed` (the default if absent) requires Apple credentials; `preview` explicitly produces an ad-hoc, non-notarized GitHub prerelease. Missing credentials never silently downgrade a signed release into a preview. Once the feed has a signed release, preview publication cannot replace it.

GitHub publishing uses the workflow's scoped `GITHUB_TOKEN`. Local publishing uses the existing `gh` login. App users need no GitHub credentials. Never embed a publisher's token in a distributed app.

## Sparkle

Sparkle 2.9.6 is pinned in SwiftPM and embedded with its helper applications. Cutline Dev and test bundles never instantiate its updater. Release builds offer Check for Updates and an optional automatic-check preference; installation requires user action.

The build generates the feed URL from `CUTLINE_RELEASE_REPOSITORY`, then `GITHUB_REPOSITORY`, then the GitHub origin remote. Configure `owner/repository` explicitly when building from a source archive. The separate `updates` branch holds a cryptographically signed feed and release metadata. Every item points to an immutable versioned ZIP on GitHub Releases. This supports the initial preview releases and later notarized stable releases without changing the installed app's feed URL. The feed advances only after publication, with monotonically increasing build numbers and a non-force branch update. Release tags are not moved. Signed feeds and archive verification before extraction are mandatory.

The dedicated public Ed25519 key is in `Config/SparklePublicKey.txt`; the private seed is stored in the local login Keychain under Sparkle account `studio.cutline.updates` and the Actions secret `SPARKLE_ED_PRIVATE_KEY`. Back up that Keychain entry securely. Do not rotate the key during ordinary releases. Key matching and signatures are checked before publication. Follow [Sparkle's setup](https://sparkle-project.org/documentation/) and [publishing guidance](https://sparkle-project.org/documentation/publishing/) when changing this pipeline.

## Apple signing credentials

Set the `APPLE_TEAM_ID` Actions variable to the certificate owner’s team. No developer identity is supplied by the source. Required Actions secrets:

- `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`
- Either `NOTARY_APPLE_ID` and `NOTARY_APP_PASSWORD`, or `NOTARY_API_KEY_P8`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID`
- `SPARKLE_ED_PRIVATE_KEY`

Notarization runs in GitHub Actions; a local notarization profile is optional. `NOTARY_APP_PASSWORD` is an Apple-generated app-specific password, and `NOTARY_APPLE_ID` is the email for the Apple Account that generated it. Never use the account's normal sign-in password. Configure secrets using `gh secret set` with stdin or GitHub's settings UI, then run `gh variable set RELEASE_MODE --body signed`. Increase BUILD_NUMBER when transitioning from preview to stable, even if VERSION stays the same.

Signed releases validate Developer ID/team, hardened runtime, secure timestamps, Apple notarization, stapling, and Gatekeeper before publication. The app and DMG are notarized; the ZIP contains the stapled app. Credentials are imported only on an ephemeral release runner and cleaned up afterward. PR tests receive no signing secrets.

## Local packaging

```sh
./scripts/build-app.sh                         # Cutline Dev, host architecture
./scripts/release.sh preview                   # Universal preview DMG + ZIP
./scripts/update-feed.sh v0.3.0-preview.4        # Sign using local Cutline Keychain key
```

For a signed local build, provide `APPLE_TEAM_ID`, `CUTLINE_SIGNING_IDENTITY` and `NOTARY_PROFILE`, then run `./scripts/release.sh signed`. Use a notarytool Keychain profile to keep credentials out of shell history. Published assets include DMG, ZIP, SHA256SUMS.txt, appcast.xml, and release.json.

FFmpeg and whisper.cpp remain separately installed dependencies; model weights are downloaded by the user. The app works for native editing/export without them. See [installation instructions](INSTALL.md). Cross-compilation does not establish physical Intel or oldest-supported-macOS acceptance.

## Verification

Unit tests cover updater lifecycle/readiness/preference forwarding and Dev storage/credential separation. A native UI test checks the disabled Dev update menu and settings. Packaging checks both Mach-O architectures, embedded framework signatures, ZIP/DMG integrity, feed version/URL/hash, and Ed25519 signatures. A genuine two-version install/relaunch and a fresh-machine Gatekeeper acceptance pass are required to claim complete updater/distribution acceptance.
