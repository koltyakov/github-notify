# GitHub Notify

A small menu bar app for unread GitHub notifications. The macOS app uses Swift and AppKit, runs natively on Apple Silicon, and has no third-party dependencies or browser-based UI.

The original Go app lives in [`legacy/`](legacy/) and supports Windows and Linux only. Both apps reuse the original artwork in [`assets/`](assets/).

## macOS

Requires macOS 13 or later. Builds target the current Mac's architecture by default. Apple Silicon builds require no Rosetta.

- Unread counts and a per-repository tooltip in the menu bar.
- Left-click for unread notifications grouped by repository; click a notification to open it on GitHub. Right-click or Control-click for settings, filters, and other controls.
- Favorite repositories using names, wildcard patterns, or regular expressions, plus a favorites-only filter.
- A **My repositories** filter for unread counts and marking only your own repositories as read.
- Mark the displayed repositories as read, without clearing notifications newer than the last check.
- Native settings window, token storage in Keychain, and macOS login items.
- Silent, clickable macOS banners for stars, unstars, forks, new issues and pull requests, and comments on both.
- Asynchronous network requests with pagination, GitHub polling hints, and rate-limit delays.

### Build and run

Install Apple's Command Line Tools with `xcode-select --install`. Swift 6 or later is required. Running the XCTest suite also requires full Xcode, selected with `xcode-select`.

```sh
make app
open "dist/GitHub Notify.app"
```

For everyday use, copy `dist/GitHub Notify.app` to `/Applications` before enabling launch at login. Use the menu bar's Settings item to enter a **classic personal access token** with the `notifications` and `repo` scopes. The Get token and Create token on GitHub buttons open GitHub's token creation page with both scopes selected.

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

Builds use Swift Package Manager plus macOS's `clang`, `sips`, `iconutil`, `codesign`, and `hdiutil`. Local signing setup also uses the built-in `security` and `openssl` tools. The app has no Dock icon and prevents duplicate instances. It sleeps between checks and checks again after the Mac wakes.

### Settings and migration

Preferences stay at `~/Library/Application Support/github-notify/settings.json`. The native app reads the Go app's update frequency, favorite expressions, and filter mode. Empty favorite entries no longer match every repository. Invalid expressions are rejected when saving.

The old encrypted token is not imported. Enter it once in Settings to store it in Keychain. Saving native settings removes the old token field from the JSON file. The native app never writes tokens to that file.

Certificate-signed builds now use a stable credential helper and a new login-Keychain item named `com.koltyakov.github-notify.credentials.v1.<reader-hash>`. If upgrading from the earlier direct-Keychain implementation, paste your GitHub token into Settings once and save it. The old Keychain item is left untouched and is not automatically read, so migration does not trigger its repeated password prompts.

Quit the old Go app before opening the native version. If you enabled launch at login in the old app, disable it there first, or remove its `github-notify` entry from `~/Library/LaunchAgents/`. Then enable launch at login in the native app. The app uses macOS's actual login-item status instead of automatically registering an old saved preference. macOS may ask you to approve the new item under System Settings > General > Login Items.

Enter favorites on separate lines or separate them with commas. Wildcard patterns such as `koltyakov/*` and `ssnitko/varro-*` match whole repository names, with `*` matching any text. Explicit regular expressions such as `^owner/`, `^owner/repo$`, and `^owner/.*` still work, using Foundation regular expressions instead of Go's RE2 syntax. GitHub's minimum polling interval overrides a faster saved interval.

### Repository alerts

Choose **Filter mode > My repositories** in the menu to restrict unread counts, the tooltip, and **Mark as read** to repositories owned by the token's personal GitHub account. All-notifications and favorites-only modes remain available. The app identifies the account from the token, so no username or favorite pattern is needed. Stars and forks are activity alerts, not unread GitHub threads, so they do not add to the menu count.

Left-click the menu-bar icon to see unread GitHub notifications, grouped by repository and limited by the same filter as the count. Issue and pull request entries open their corresponding GitHub pages. Long titles are shortened in the dropdown; hover to see the full title. Right-click or Control-click the icon to access **Filter mode**, **Mark as read**, and the existing controls. Opening the dropdown uses the last successful check without additional API requests.

Desktop alerts always cover only your own repositories, regardless of the selected menu filter. Settings has separate toggles for stars and unstars, forks, new issues, new pull requests, issue comments, and pull request comments. All are enabled by default. Allow GitHub Notify when macOS requests notification permission. If permission was denied, use **Open notification settings** in the app's Settings. Banners require the `.app` bundle, not the bare executable from `swift run`.

To send a test without accessing GitHub or changing saved baselines, run `"dist/GitHub Notify.app/Contents/MacOS/github-notify" --test-notification` after building the app. This works even if another instance is running and reports whether Notification Center confirms delivery.

Alerts cover repositories owned by the token's personal GitHub account, regardless of the menu's favorites filter. Organization-owned repositories are not included. Use a classic token with `notifications` and `repo` scopes for full repository-alert support, including private repositories. The `repo` scope grants broad repository access; this app only reads activity and marks notifications as read. If you created a token using the older notifications-only link, update its scopes on GitHub or create a new token and save it in Settings. Updating the app does not change existing token permissions.

The first successful check establishes a silent baseline. Later checks run at most once per minute automatically, or slower if configured or requested by GitHub. Star banners report net increases and decreases in each repository's star count, not individual stargazers. Fork banners report net increases in fork counts. Additions and removals between checks can cancel out.

Issue and pull request banners report newly created threads, including threads already closed by the time of the check. Comment banners cover conversations on issues and pull requests, plus inline pull request review comments. Edits to old comments do not trigger alerts. Clicking a banner opens the stargazers, forks, issue, pull request, or specific comment on GitHub. Focus modes and macOS notification settings can suppress banners.

Baselines are stored in `~/Library/Application Support/github-notify/activity.json` to avoid repeats after restarting. Turning an alert type off and back on establishes a fresh baseline for that type. Repository alerts run without a status row in the menu. Errors go to the macOS system log under the `com.koltyakov.github-notify` subsystem and `RepositoryActivity` category, without interrupting unread-notification polling.

### Signing and distribution

By default, builds without a configured signing identity use ad-hoc signing. Its identity changes with the executable, which can make Keychain ask for access again after each rebuild, even after **Always Allow**. For local development, configure a reusable app-specific signing identity once:

```sh
make setup-signing
make install
```

Setup creates a self-signed certificate trusted for code signing only, with its private key in a separate Keychain under `~/Library/Application Support/github-notify/signing/`. Its generated unlock password is stored in that private directory with owner-only permissions. The signing Keychain is appended to the search list without removing existing entries or changing the default Keychain. The login Keychain and GitHub-token access rules are not changed. Local builds automatically reuse this identity. Do not copy the signing directory into the repository or share it.

A stable certificate alone is not sufficient for the login Keychain. For locally signed apps, macOS also applies a per-binary partition restriction, which can prompt after every rebuild even when the certificate and designated requirement are unchanged.

Certificate-signed builds therefore access the token through a small helper whose binary is cached independently of the Swift/UI app. The helper authenticates its actual parent by bundle identifier and signing certificate before accessing Keychain; the app authenticates the helper before sending it a token. Tokens remain in the login Keychain, never in files or command-line arguments. The helper disables automatic password dialogs and reports denied or locked access instead. If the login Keychain is locked, unlock it in Keychain Access before saving the token. Use the installed copy consistently, and do not enable "allow all applications" on the token.

Changing the helper's code or compiler can change its Keychain identity; UI-only rebuilds do not. A changed helper uses a fresh item, requiring the token to be pasted again rather than requesting passwords for the old hash-restricted item. Ad-hoc builds cannot authenticate this helper securely and retain the older direct-Keychain behavior. Use `make setup-signing` for local development.

`make test-signing` checks signing selection and, when local signing is configured, verifies that two different test builds retain the same certificate-bound requirement. It never runs the app or reads the GitHub token.

After local signing is configured, `make test-credentials` exercises the real login Keychain using a disposable dummy item. It verifies that two different main-app builds can read through the unchanged helper without password dialogs, and that untrusted parents and helpers are rejected. The real token items are never queried or changed.

Self-signed and ad-hoc builds are **not notarized** and are not a substitute for Developer ID distribution. Gatekeeper may block a downloaded build. CI still uses ad-hoc signing unless an identity is configured. To explicitly build ad-hoc, use `CODESIGN_IDENTITY=- make app`. For distribution outside your own machine, override the local identity with your Developer ID identity and notarize it through Apple:

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
| `Sources/GitHubNotifyCredentials/` | Stable, authenticated login-Keychain helper |
| `Tests/GitHubNotifyCoreTests/` | API and preferences regression tests |
| `assets/` | Shared app icon, screenshots, and original tray artwork |
| `packaging/`, `scripts/` | macOS bundle metadata and build script |
| `legacy/` | Windows/Linux Go implementation and its build setup |

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
