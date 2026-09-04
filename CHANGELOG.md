# Changelog

## 1.0.0-dev1

### Added

- Shared release version and build number files for app metadata, About, and distribution archive names.
- Native Swift menu-bar application for Finder window placement and view rules.
- Eligible Finder-dialog placement on the primary display.
- One-shot placement for newly opened standard application windows on the main display, with configurable aspect ratio and display coverage.
- Bulk default-application management by filename extension with verified restore support.
- Crash-safe, write-ahead file-association history that preserves newer external choices.
- Native Focus Follows Pointer for standard windows, disabled by default, with a configurable 250 ms dwell, optional pointer-stop requirement, Control/Option/None pause modifier, app exclusions, and a menu-bar toggle. It uses public Accessibility APIs without cursor warping, cursor scaling, or private APIs.
- Modern Accessibility onboarding, launch-at-login management, and signed app packaging.
- Universal Developer ID packaging with notarization, stapling, and Gatekeeper verification.
- Original FinderFix application icon.
- One-command `build.sh` packaging into `OUT/FinderFix.app`.
- Optional automatic `.DS_Store` cleanup for selected folders or the Home and Applications folders, with cancellable one-time cleanup and Trash-only removal.
- Grouped menu-bar checklists for every Boolean setting, including the option to hide the menu-bar item.

### Fixed

- Existing windows no longer become placement candidates through focus events or delayed creation notifications after the initial window scan.
- Accessibility status now refreshes automatically after permission changes, even when the menu-bar app does not receive an activation event.
- Focus Follows Pointer no longer inspects FinderFix's own SwiftUI window from its Accessibility worker, preventing a settings-window deadlock while applying rules.
- Focus Follows Pointer pauses for Dock and Mission Control activity and ignores parked windows that are not visibly present on the pointer’s display.
- Focus Follows Pointer can transfer focus immediately after being enabled from FinderFix Settings; FinderFix now suspends it only while the pointer is over its own visible interface.
- Closing Settings no longer releases its window, so reopening an already-running FinderFix reliably restores the GUI, including after the menu-bar item is hidden.

### Changed

- Advanced the local preference store to schema v3 for global-window placement, Window Focus, and `.DS_Store` cleanup settings. Earlier development preferences are intentionally not migrated.
- `build.sh` reuses the installed Apple Development signing identity, refuses ambiguous implicit signing, and unregisters transient app copies so macOS privacy approval stays attached to the installed app.
- Combined Finder window and dialog controls under **Dialogs and Windows** and moved About information to the standard macOS About panel.
