# Development and release builds on one Mac

| | Release | Development |
| --- | --- | --- |
| App | Cutline, from GitHub Releases in Applications | Cutline Dev, built into `dist/` |
| Bundle ID / preferences domain | `studio.cutline.editor` | `studio.cutline.editor.dev` |
| Data folder under Application Support | `Cutline/` | `Cutline Dev/` |
| OpenRouter key in the Keychain | `studio.cutline.openrouter` | `studio.cutline.dev.openrouter` |
| AI agent connector name | `cutline` | `cutline-dev` |
| Icon and header | Standard | DEV badge on the icon, DEV label beside the name |
| Version in the status bar and Settings | Cutline 0.5.1 | Cutline Dev 0.5.1 |
| Updates | Sparkle, Cutline → Check for Updates | Off; rebuild from `dev` |
| `.cutline` project files | Opens them by default | Can open them, never the default |

The two builds keep separate settings, layouts, scan caches, recovery and generated media. Development starts empty and never copies release data. Either can open the other's project files, and both export shorts to `~/Movies/Cutline/`.

## Everyday commands

```sh
# Build and open the development app (the default variant)
./scripts/build-app.sh
open "dist/Cutline Dev.app"

# Build a release-identity bundle explicitly, for packaging checks only
CUTLINE_BUILD_VARIANT=production ./scripts/build-app.sh
```

Runtime identity comes from the bundle identifier. Anything other than `studio.cutline.editor`, including an unbundled `swift run`, is a development build. Release packaging (`scripts/release.sh`) always selects the production variant. Unknown variants are rejected.

The production-identity command shares the released app's data and preferences, and it is ad-hoc signed unless you supply `CUTLINE_SIGNING_IDENTITY`. For normal use, install the signed release in Applications and let it update itself.

Rebuilding while Cutline Dev is open is safe: the new bundle replaces the old one without touching the running copy. Quit and reopen it to run the new build.

## Xcode

`Cutline.xcodeproj` runs a third identity, **Cutline Test Build** (`studio.cutline.editor.tests`), used by the unit and UI tests. It behaves as a development build and shares the `Cutline Dev/` data folder, but its bundle comes from Xcode's DerivedData. Use it for debugging and tests; use `dist/Cutline Dev.app` for day-to-day testing of the app.

## Icons

`swift scripts/make-icon.swift` redraws `Config/AppIcon.icns`. `--development` adds the DEV badge and `--output <file.icns>` writes elsewhere; `scripts/build-app.sh` uses both for development builds, so the committed icon stays the release icon.
