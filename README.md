# NookBar

A free, open-source menu bar manager for macOS. Built to tuck away clutter and
bring it back when you need it. No paid tiers, subscriptions, accounts, or analytics.

**Status: development preview.** Choose third-party menu bar apps and hide or show
their icons, and open a strip of hidden icons beneath the tray button. macOS 27 uses app-wide visibility, so multiple
icons from the same app share one selection.

## Use

1. Enable NookBar in the system Accessibility permission pane when prompted.
2. Right-click the tray icon and choose **Choose Apps…**.
3. Check apps individually or click **Select All**, then click **Hide Selected**.
4. Left-click NookBar to open the hidden icon strip. Allow Screen Recording when prompted.
5. Click an icon in the strip to open its original menu bar item. It is temporarily
   revealed, then hidden again when its menu closes.
6. Click NookBar again, click outside, or press Escape to close the strip. Right-click
   NookBar for settings; **Show All Apps** restores all selected icons.

Selections are saved; hiding starts only when you request it. On macOS 27, the
native NookBar icon can disappear during hiding. A clickable **N** control replaces
it in a vacant status-item slot. If no suitable slot is found, NookBar restores all
apps. Clicking blank menu bar space also requests the strip; this interaction
still needs physical validation. Changing selections or refreshing the list first shows
all apps. Quit, sleep, Space changes, permission loss, or changes to running apps release hiding.
Some system extras, such as Focus, can also disappear during hiding; Show All
restores them. Clock and Control Center are not selectable in this preview.

The strip uses ScreenCaptureKit to sample the menu bar region while icons are visible.
Captured icon images are retained only in memory. Screen Recording is optional for
hiding/showing, and required for the actual icon strip. Opening a hidden item uses
its Accessibility press action; unsupported items restore the bar instead of
launching the app as a substitute. The original menu opens at its native menu bar
location. A first capture briefly reveals selected icons; cached images are refreshed
when the strip is rebuilt.

## Build

Requires macOS 27 and Xcode 27 or later. There are no external dependencies.

```sh
./scripts/build.sh
open build/NookBar.app
```

Open `Package.swift` in Xcode to edit the app. Run diagnostics without launching
the menu bar UI:

```sh
build/NookBar.app/Contents/MacOS/NookBar --diagnose
```

Run the build, bundle-signature and diagnostics smoke checks with `./scripts/check.sh`.

The app requests Accessibility access on launch if it is missing. Enable NookBar
in the system permission pane. To retry, choose **Request Accessibility Access…**
from the tray menu; this opens System Settings. The menu checks the current grant
each time it opens. Command-line diagnostics do not request permission.

For local rebuilds, set `NOOKBAR_SIGNING_IDENTITY` to an existing development
signing identity, or put its hash in `.signing-identity` (ignored by Git). A stable
development identity lets macOS recognize the same app across builds. The default
is ad-hoc signing, which can require granting Accessibility access again after
each rebuild. Notarized public downloads are a later release milestone.

## Validation

`./scripts/check.sh` checks the build, signature, plist, and read-only diagnostics.
The native hide/restore check must run from the app bundle with its own permission:

```sh
open -n build/NookBar.app --args --self-test --report "$PWD/.build/self-test.json"
```

Quit other running NookBar copies before testing. This check temporarily hides
NookBar's own icon, releases the assertion, and verifies that its original
Accessibility occurrences return. It also checks other third-party apps remain
present. It writes a JSON report and exits. System extras may briefly hide too.
Accessibility observations do not replace visual checks on each display.

See `docs/SMOKE_TEST.md` for lifecycle and UI coverage. Keyboard shortcuts and launch at login are not implemented yet.

macOS 27 no longer exposes the per-icon windows used by older tools. The proposed
backend uses a private system framework, whose behavior can change. Multiple
icons belonging to one app may share visibility, and system items have limitations.
Read [the investigation](docs/ice-investigation.txt) for observed facts and remaining checks.

## License and research

GPL-3.0-or-later. See `LICENSE` and `THIRD_PARTY_NOTICES.md` for adapted bridge code
and research attribution. There are no third-party runtime dependencies.
