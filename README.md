# FinderFix

FinderFix is a native Swift utility for macOS 14 and later. Control new-window placement, Finder settings, hover focus, and default apps for file extensions.

This replaces the expired FinderFix beta with a separate app identity. It has no expiration timer, updater, analytics, or account service.

[Download 1.0.0-dev1](https://github.com/TimeZone-LLC/FinderFix---OS/releases/tag/v1.0.0-dev1) · [Changelog](CHANGELOG.md) · [Build from source](#build)

![FinderFix Overview with Accessibility ready and startup controls](https://github.com/TimeZone-LLC/FinderFix---OS/releases/download/v1.0.0-dev1/overview.png)

Screenshots show the running app with example settings, not the first-launch defaults. Screenshot files are release assets, outside the source tree.

## Install

The `1.0.0-dev1` ZIP contains a universal app for Apple silicon and Intel Macs. You do not need Xcode to run it.

This is an unnotarized development prerelease, signed with an Apple Development certificate rather than Developer ID. Gatekeeper may block it. It is for testing, not a stable release.

1. Download and unzip `FinderFix-1.0.0-dev1-1-macos-universal.zip` from the release page.
2. Quit any running copy of FinderFix.
3. Move `FinderFix.app` into `/Applications`.
4. Open FinderFix from Applications.
5. In Overview, open Accessibility Settings and enable the installed FinderFix app.
6. Return to FinderFix and confirm that it reports **Accessibility Ready**.

If macOS blocks this test build, read [Apple’s guidance on opening unnotarized apps](https://support.apple.com/en-ie/102445). Use an app-specific exception only if you trust this build. Do not disable Gatekeeper globally.

Install before granting permissions or enabling login startup. Finder view controls can also request Automation permission to control Finder.

## How to use it

### Overview and menu controls

Window automation, hover focus, login startup, and automatic cleanup start off. The menu-bar item and the `⌥⌘F` Finder shortcut start on.

Enable only the features you want. **Enable Recommended Rules** enables Finder geometry, Finder view controls, and eligible Finder dialogs. It does not enable hover focus or cleanup.

Use **Apply Rules Now** to apply enabled Finder rules to existing Finder windows. Unlike automatic new-window placement, this action can move windows you already positioned.

Overview contains the login, menu-bar visibility, and keyboard shortcut switches. The menu-bar menu groups on/off settings into checklists. Numeric values and app selections stay in Settings.

Hiding the menu-bar item does not quit FinderFix. Open it again from Applications or Spotlight to show Settings without starting a second instance.

### Dialogs and Windows

Enable **Place new app windows on the main display**, then choose an aspect ratio and display coverage. The default is 16:10 at 80% coverage.

Coverage limits both dimensions within the display’s usable bounds. Main display means your configured primary display, not the display containing the active app.

FinderFix places eligible new windows once. It does not continually recenter them after you move them. Windows already present when monitoring starts remain in place.

Finder-specific controls let you choose dimensions, position, target display, view mode, and visible toolbars. If both placement modes are enabled, Finder-specific geometry takes priority for Finder.

Enable **Move eligible Finder dialogs to the main display** for standalone Finder prompts. Optionally bring those moved dialogs forward.

![Dialogs and Windows settings with new-window geometry and Finder dialog controls](https://github.com/TimeZone-LLC/FinderFix---OS/releases/download/v1.0.0-dev1/dialogs-and-windows.png)

This is not a system-wide prompt mover. Attached sheets stay attached. Authentication, privacy, login, lock-screen, and other protected interfaces are excluded.

Apps must expose movable and resizable standard windows through Accessibility. Full-screen and minimized windows are excluded. Bringing dialogs forward is best effort.

### Window Focus

Enable **Focus a window after hovering over it** to bring a supported window and its app forward without clicking.

The default delay is 250 ms, with **Wait until the pointer stops moving** enabled. Hold Control to pause focus changes temporarily.

You can change the delay, choose Option or no pause modifier, and exclude individual apps. Hover focus is off on first launch.

![Window Focus settings with dwell delay, pointer-stop option, and app exclusions](https://github.com/TimeZone-LLC/FinderFix---OS/releases/download/v1.0.0-dev1/window-focus.png)

This is an independent Swift implementation inspired by AutoRaise. It uses public Accessibility APIs without cursor warping, cursor scaling, or private APIs.

### File Types

1. Enter final extensions such as `png, jpg`, separated by commas, spaces, or newlines.
2. Click **Resolve Extensions**.
3. Choose the intended content type when an extension is ambiguous.
4. Select a compatible app, or use **Choose Other…**.
5. Review the affected content types and extensions.
6. Click **Apply Changes** and confirm.

![File Types resolving png and jpg before choosing a target application](https://github.com/TimeZone-LLC/FinderFix---OS/releases/download/v1.0.0-dev1/file-types.png)

macOS stores defaults by content type, so one change can affect additional extensions. FinderFix previews those effects before applying a change.

**Restore Previous App** restores the handler captured before FinderFix changed it. It preserves newer choices made outside FinderFix.

There is no supported reset to an unspecified automatic handler. Without a captured previous app, FinderFix cannot clear that default. **Forget from FinderFix** removes history only.

### Maintenance

Choose **Selected Folders** or **Home + Applications** for `.DS_Store` cleanup. The broader scope covers your home folder and `/Applications`, not the entire filesystem.

For one-time cleanup, choose a folder, review the scan count, and confirm. For ongoing cleanup, enable **Move .DS_Store files to Trash automatically** after choosing a scope.

![Maintenance settings with cleanup scope and one-time cleanup controls](https://github.com/TimeZone-LLC/FinderFix---OS/releases/download/v1.0.0-dev1/maintenance.png)

Cleanup moves metadata to Trash rather than permanently deleting it. Removing `.DS_Store` files can reset folder views and icon positions. Finder can create these files again.

FinderFix skips app packages, symbolic links, inaccessible paths, and Trash directories. Automatic cleanup is off by default.

**Reset Preferences** resets FinderFix settings only. Restore file associations separately from File Types history.

## Troubleshooting

- Permission not detected: verify that Accessibility lists the copy in `/Applications`, then use **Check Permission** or reopen FinderFix.
- Window unchanged: check its feature toggle and Accessibility permission. The app may not expose supported window controls.
- Hover does nothing: enable Window Focus, release the pause modifier, and check app exclusions.
- Menu icon missing: open FinderFix from Applications or Spotlight, then enable its visibility switch in Overview.
- Login startup fails: install in `/Applications` and retry. Do not register the copy inside the build folder.

## Build

Source builds require Xcode 16 or a compatible Swift 6 toolchain on macOS 14 or later.

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

List local signing identities with `security find-identity -v -p codesigning`. Set `FINDERFIX_SIGNING_IDENTITY=-` only when an ad-hoc build is intentional. These builds can require new Accessibility approval after each rebuild.

Pass `debug` to produce a debug build. The default is `release`. Install before granting Accessibility or enabling **Open FinderFix at login**, because macOS does not register transient build locations reliably.

For the lower-level Make targets:

```sh
make test
make app
open .build/app/FinderFix.app
```

`make app` creates an ad-hoc-signed build for the current Mac. `make app-universal` creates an ad-hoc arm64/x86_64 development build. Ad-hoc builds are for local testing only. Rebuilding them can cause macOS privacy grants to change.

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

Settings and file-association history stay in the local user account. FinderFix has no analytics, account, network updater, or telemetry service. Accessibility handling classifies window structure only. It does not read or log dialog text and never presses dialog buttons.

## Acknowledgements

Focus Follows Pointer is an independent native Swift implementation inspired by the behavior documented by the [lhaeger AutoRaise launcher](https://github.com/lhaeger/AutoRaise) and the maintained [sbmpost AutoRaise project](https://github.com/sbmpost/AutoRaise). FinderFix does not incorporate AutoRaise source code or assets.

## License

See [LICENSE](LICENSE).
