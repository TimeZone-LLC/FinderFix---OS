# FinderFix

FinderFix is a modern macOS menu-bar utility for predictable Finder windows, visible Finder dialogs, focus-follows-pointer behavior, and bulk default-app management.

This project is a clean replacement for the expired FinderFix beta. It has a new bundle identity and does not import the beta’s preferences, updater, signature, or expiration logic.

The first launch is conservative: Finder-changing rules start disabled. Use **Enable Recommended Rules** in Overview, or enable only the rules you want.

## Features

- Resize and position new Finder windows on the primary, current, or pointer display.
- Optionally center each newly opened standard app window on the main display once, at a configurable aspect ratio and screen coverage. FinderFix leaves it alone after you move it.
- Apply Finder view, sidebar, toolbar, path-bar, status-bar, and sidebar-width preferences.
- Center eligible standalone Finder dialogs on the primary display and raise them when macOS permits it.
- Set one application as the default for a typed list of file extensions.
- Preview UTI ambiguity and collateral extensions before changing file associations.
- Restore handlers captured before FinderFix changed them, or forget a FinderFix record without changing macOS.
- Optionally focus standard application windows after the pointer dwells over them. This feature is off by default and provides a configurable dwell time (250 ms by default), an optional require-pointer-stop rule, a Control/Option/None pause modifier, per-app exclusions, and a menu-bar toggle.
- Start at login with `SMAppService` and open Finder with `⌥⌘F`.
- Toggle Boolean settings directly from grouped, checked menu-bar items. The menu-bar item itself can be hidden; opening FinderFix again brings back Settings so it can be restored.
- Move `.DS_Store` files to the Trash once or automatically, either in selected folders or across the Home and Applications folders. Automatic cleanup is off by default, and the broader scope requires confirmation.

FinderFix never moves authentication, privacy, login, lock-screen, or system-wide security interfaces. Attached sheets remain attached. Dialog focus is best effort because macOS keeps final control.

Focus Follows Pointer uses public macOS Accessibility APIs and targets standard application windows only. It does not warp or scale the cursor and does not use private APIs.

macOS has no supported public API for returning a content type to an unspecified automatic handler. FinderFix therefore “clears” its own change by restoring the previous app it captured. If macOS reported no previous app, FinderFix leaves the current association unchanged and can only forget its local record.

## Requirements

- macOS 14 or later
- Xcode 16 or a compatible Swift 6 toolchain
- Accessibility permission for window and dialog automation
- Automation permission when applying Finder chrome through Apple Events

FinderFix is intended for direct distribution. App Sandbox is not enabled because Accessibility window automation is incompatible with the sandboxed product model.

## Build

For a current-architecture, release-configuration development build in the repository’s `OUT` folder:

```sh
./build.sh
```

The script reuses the Apple Development identity from an installed `/Applications/FinderFix.app`. If there is no installed copy, it uses the identity automatically only when exactly one is available. If several identities are available, set the intended identity explicitly. This keeps Accessibility approval stable across rebuilds. Copy the app to `/Applications` and grant permission only to that installed copy:

```sh
FINDERFIX_SIGNING_IDENTITY="Apple Development: Example (TEAMID)" ./build.sh
ditto OUT/FinderFix.app /Applications/FinderFix.app
open /Applications/FinderFix.app
```

List local signing identities with `security find-identity -v -p codesigning`. Set `FINDERFIX_SIGNING_IDENTITY=-` only when an ad-hoc build is intentional; Accessibility must be approved again after every ad-hoc rebuild. Pass `debug` to produce a debug build instead; the default is `release`. Install the app before granting Accessibility or enabling **Open FinderFix at login** because macOS does not register transient build locations reliably.

For the lower-level Make targets:

```sh
make test
make app
open .build/app/FinderFix.app
```

`make app` creates an ad-hoc-signed build for the current Mac. `make app-universal` creates an ad-hoc arm64/x86_64 development build. Ad-hoc builds are for local testing only; rebuilding them can cause macOS privacy grants to change.

For a universal Developer ID build, notarization, stapling, Gatekeeper verification, and a distributable ZIP:

```sh
FINDERFIX_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
FINDERFIX_NOTARY_PROFILE="finderfix-notary" \
make release
```

Create the notary profile once with `xcrun notarytool store-credentials`. Release builds require a clean Git worktree so the binary and corresponding-source ZIP in `.build/distribution/` describe the same revision. Publish the matching source ZIP alongside the binary ZIP, or provide equivalent access to that exact source. The packaged app is written to `.build/app/FinderFix.app`.

## Versioning

`VERSION` holds the release label, currently `1.0.0-dev1`. Use `MAJOR.MINOR.PATCH`, optionally followed by `-devN`, `-alphaN`, `-betaN`, or `-rcN`.

Increase the major number for incompatible changes, the minor number for features, and the patch number for fixes. Increase the suffix number for each prerelease.

`BUILD_NUMBER` holds a positive integer, currently `1`. Increase it for each distributed build, including prereleases. Never reset it when the release version changes.

Edit these files before building and add release notes under the matching heading in `CHANGELOG.md`. Builds reject invalid version values.

Packaging writes the numeric release into `CFBundleShortVersionString` and the build number into `CFBundleVersion`. About and distribution archive names include the full prerelease label.

## Privacy

Settings and file-association history stay in the local user account. FinderFix has no analytics, account, network updater, or telemetry service. Accessibility handling classifies window structure only; it does not read or log dialog text and never presses dialog buttons.

## Acknowledgements

Focus Follows Pointer is an independent native Swift implementation inspired by the behavior documented by the [lhaeger AutoRaise launcher](https://github.com/lhaeger/AutoRaise) and the maintained [sbmpost AutoRaise project](https://github.com/sbmpost/AutoRaise). FinderFix does not incorporate AutoRaise source code or assets.

## License

See [LICENSE](LICENSE).
