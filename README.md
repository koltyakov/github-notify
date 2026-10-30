# GitHub Notify

A small menu bar app for unread GitHub notifications. The macOS app uses Swift and AppKit, runs natively on Apple Silicon, and has no third-party dependencies or browser-based UI.

The original Go app lives in [`legacy/`](legacy/) and supports Windows and Linux only. Both apps reuse the original artwork in [`assets/`](assets/).

## macOS

Requires macOS 13 or later. Builds target the current Mac's architecture by default. Apple Silicon builds require no Rosetta.

- Unread counts and a per-repository tooltip in the menu bar.
- Favorite repositories using names or regular expressions, plus a favorites-only filter.
- Mark the displayed repositories as read, without clearing notifications newer than the last check.
- Native settings window, token storage in Keychain, and macOS login items.
- Silent, clickable macOS banners for new stars and issues on repositories owned by your GitHub account.
- Asynchronous network requests with pagination, GitHub polling hints, and rate-limit delays.

### Build and run

Install Apple's Command Line Tools with `xcode-select --install`. Swift 6 or later is required. Running the XCTest suite also requires full Xcode, selected with `xcode-select`.

```sh
make app
open "dist/GitHub Notify.app"
```

For everyday use, copy `dist/GitHub Notify.app` to `/Applications` before enabling launch at login. Use the menu bar's Settings item to enter a **classic personal access token** with the `notifications` scope. The Get token item opens GitHub's token creation page.

Or build and install directly:

```sh
make install                                 # Build and install/update in /Applications
make install INSTALL_DIR="$HOME/Applications" # Per-user installation
```

On macOS, installation builds for the current Mac's architecture, preserves preferences and Keychain data, and restarts the destination app if it was running. It stages the replacement before stopping the old app and keeps a backup until replacement succeeds. On Windows and Linux, the same root command delegates to the legacy Go app's native `go install` target. Installation does not enable launch at login or start the app on its first install.

```sh
make build                  # Optimized executable for the current Mac
make test                   # XCTest suite, requires Xcode
make dmg                    # App, DMG, and SHA-256 checksum in dist/
make arch=universal app     # Native arm64 and x86_64 bundle
make arch=x86_64 app        # Intel-only bundle
make version=1.2.3 dmg      # Set bundle and installer version
```

`make run` builds and opens the app. `swift build` builds a debug executable, which uses SF Symbols if the bundled artwork is unavailable. Launch at login requires the `.app` bundle.

Local builds use `git describe --tags --always --dirty` as their version, including the nearest tag, commits since the tag, and any uncommitted changes. Without tags, Git supplies the commit hash; without Git metadata, the version is `dev`. About shows the full version. macOS bundle version fields use the tag's numeric `major.minor.patch`, or `0.0.0` when no numeric version is available. Override it with `make version=1.2.3 app`, or `VERSION=1.2.3 /bin/bash scripts/bundle.sh` when running the script directly.

Builds use only Swift Package Manager and macOS's `sips`, `iconutil`, `codesign`, and `hdiutil`. The app has no Dock icon and prevents duplicate instances. It sleeps between checks and checks again after the Mac wakes.

### Settings and migration

Preferences stay at `~/Library/Application Support/github-notify/settings.json`. The native app reads the Go app's update frequency, favorite expressions, and filter mode. Empty favorite entries no longer match every repository. Invalid expressions are rejected when saving.

The old encrypted token is not imported. Enter it once in Settings to store it in Keychain. Saving native settings removes the old token field from the JSON file. The native app never writes tokens to that file.

Quit the old Go app before opening the native version. If you enabled launch at login in the old app, disable it there first, or remove its `github-notify` entry from `~/Library/LaunchAgents/`. Then enable launch at login in the native app. The app uses macOS's actual login-item status instead of automatically registering an old saved preference. macOS may ask you to approve the new item under System Settings > General > Login Items.

Favorite patterns use Foundation regular expressions instead of Go's RE2 syntax. Common patterns such as `^owner/` and `^owner/repo$` work unchanged. GitHub's minimum polling interval overrides a faster saved interval.

### Repository alerts

New star and issue banners are enabled by default and can be turned off separately in Settings. Allow GitHub Notify when macOS requests notification permission. If permission was denied, use **Open notification settings** in the app's Settings. Banners require the `.app` bundle, not the bare executable from `swift run`.

Alerts cover repositories owned by the token's personal GitHub account, regardless of the menu's favorites filter. Organization-owned repositories are not included. A classic token with `notifications` scope covers unread notifications and public repository activity. Add `repo` scope to include private repository activity.

The first successful check establishes a silent baseline. Later checks run at most once per minute automatically, or slower if configured or requested by GitHub. Star banners report net increases in each repository's star count, not individual stargazers. Stars added and removed between checks can cancel out. Issue banners report newly created issues, including issues already closed by the time of the check, but not pull requests or comments. Clicking a banner opens the repository's stargazers or the issue on GitHub. Focus modes and macOS notification settings can suppress banners.

Baselines are stored in `~/Library/Application Support/github-notify/activity.json` to avoid repeats after restarting. Turning an alert type off and back on establishes a fresh baseline for that type. Repository-alert errors appear separately in the menu and do not interrupt unread-notification polling.

### Signing and distribution

Local builds and the default release workflow use ad-hoc signing. They are **not notarized**; Gatekeeper may block a downloaded build. For distribution outside your own machine, sign with your Developer ID identity and notarize it through Apple:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make version=1.2.3 dmg
```

Signing certificates and notarization credentials are not included. Use a consistent signing identity across updates so Keychain and login items can recognize the app. The release workflow publishes the ARM64 DMG and legacy Windows/Linux archives on version tags.

## Windows and Linux

See [`legacy/README.md`](legacy/README.md) for the Go app's prerequisites and build commands. Swift and Xcode are not needed for those targets.

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/GitHubNotify/` | AppKit menu, settings, Keychain, login items |
| `Sources/GitHubNotifyCore/` | GitHub API, preferences, notification summaries |
| `Tests/GitHubNotifyCoreTests/` | API and preferences regression tests |
| `assets/` | Shared app icon, screenshots, and original tray artwork |
| `packaging/`, `scripts/` | macOS bundle metadata and build script |
| `legacy/` | Windows/Linux Go implementation and its build setup |
