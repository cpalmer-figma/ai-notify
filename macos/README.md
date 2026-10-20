# Native macOS menu bar app

Open `CoderNotify.xcodeproj` in Xcode, select the **CoderNotify** scheme and **My Mac**, then press **⌘R**. A bell appears in the menu bar; click it for the machine list and agent activity. This app uses Apple's native SwiftUI menu bar interface and requires macOS 13 or later.

A credit usage bar at the top of the popup shows the total used out of the 400-credit limit. It uses Coder's reported build costs; when costs are missing, active boxes are estimated at 30 credits each. Usage refreshes with workspace discovery, and failures keep the last known usage labeled as such.

The list includes every discovered Coder workspace, even ones without notification hooks:

- Green: running and reachable.
- Red: stopped, failed or deleting.
- Yellow: starting or unreachable.
- Gray: unknown state.

Machine state and notification connection state are shown separately. Click a machine row to open its workspace at `https://coder.figdev.systems/@<owner>/<name>`. Agent alerts can be dismissed, and a session's context menu can copy its tmux target. **Dashboard** opens the existing browser interface.

For agent alerts, run `bin/coder-notify setup <workspace> --install-deps` from the repository on your Mac. This installs the remote reporter and hooks automatically. Codex still asks you to review the installed hooks once in `/hooks`. See the repository's remote setup guide for details.

## Service lifecycle

The app connects only to `127.0.0.1:47290`, using the access token in `~/.coder-notify/menu-token`. It checks that the listener identifies itself as coder-notify before sending the token. It polls every five seconds; the Ruby service discovers machines every minute.

When no service is running, the app launches this checkout's `bin/coder-notify server` with an explicitly resolved Ruby executable. It prefers the version in `.ruby-version` installed through rbenv, mise or asdf, and adds standard Coder installation folders to the child process's PATH. It does not rely on Xcode loading your shell configuration. Ruby, Bundler dependencies and the logged-in Coder CLI must already be installed; run `bundle install` in the repository if necessary. It records service output in `~/.coder-notify/logs/menubar-service.log`.

Quitting the app stops a service it launched, which also closes that service's workspace tunnels. An independently started service is left running. Xcode's **Stop** button can force-kill the app without running normal cleanup; use the menu's **Quit** button to shut down both cleanly. If a service is left running, `bin/coder-notify status` will show it; a subsequent app run reuses it.

The checkout is located from the source file's build path. If you move the checkout, use the gear menu's **Choose project folder…**. The app honors `CODER_NOTIFY_HOME` and `CODER_NOTIFY_PORT` environment variables set in the Xcode scheme; the service inherits them. If Ruby is installed elsewhere, set `CODER_NOTIFY_RUBY` to its full executable path under **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**. `CODER_BIN` can likewise select a custom Coder executable.

A slashed bell indicates an error loading the data. The popover keeps the specific startup error visible, with **Retry service** and **View log** actions. No machine list before the first successful connection is distinct from a successfully discovered empty list. The child service runs with UTF-8 encoding and locale even when Xcode supplies a minimal environment.

## Build and test

```sh
xcodebuild -project macos/CoderNotify.xcodeproj -scheme CoderNotify \
  -configuration Debug -derivedDataPath macos/build build

xcodebuild -project macos/CoderNotify.xcodeproj -scheme CoderNotify \
  -destination 'platform=macOS' -derivedDataPath macos/build test
```

The project uses local signing with **Sign to Run Locally**, with no development team required. The app sandbox is disabled so this local development app can read its existing token and launch Ruby/Coder processes. There are no external native app dependencies. This does not establish whether your company's controls will allow this particular app to run.

On this Mac, launching the binary directly was blocked by Santa with **Unknown, Lockdown mode**, but running the project through Xcode's **Product → Run** successfully displayed the menu bar app. Use the Xcode development workflow. If that workflow is blocked on another machine, consult the internal developer guidance or Platform Security.

Tests run in a standalone test bundle and don't start the Ruby service. They check API authentication, rejection of a different local service, missing credentials, dashboard token handling, and machine status independent of notification setup.
