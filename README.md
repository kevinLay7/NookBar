# NookBar

A free, open-source menu bar manager for macOS. Built to tuck away clutter and
bring it back when you need it. No paid tiers, subscriptions, accounts, or analytics.

**Status: development preview.** Choose third-party menu bar apps and hide or show
their icons, and open a strip of hidden icons beneath the tray button. macOS 27 uses app-wide visibility, so multiple
icons from the same app share one selection.

## Use

1. Enable NookBar in the system Accessibility permission pane when prompted.
2. Right-click the tray icon and choose **Choose Apps…**.
3. Assign apps to **Visible**, **Hidden**, or **Always Hidden**, then click **Hide Selected**.
4. Left-click NookBar to open the hidden icon strip. Allow Screen Recording when prompted.
5. Click an icon in the strip to open its original menu bar item. It is temporarily
   revealed, then hidden again when its menu closes.
6. Click NookBar again, click outside, or press Escape to close the strip. Right-click
   NookBar for settings; **Show All Apps** restores all selected icons.

Option-click NookBar to open the always-hidden section. You can also use
**Always-Hidden Icons…** in its menu or the app picker. The normal strip excludes
always-hidden apps. In native menu bar mode, showing Always Hidden reveals both
sections; hiding that section leaves the normal hidden section revealed. **Select
All** preserves apps already assigned to Always Hidden; **Clear Selection** makes
both sections visible.

Choose **Arrange Menu Bar Icons…** from NookBar’s context menu to reorder third-party
icons. All apps are revealed while this window is open. Select an icon and use
**Move Left** or **Move Right**, or drag its row. Movement buttons and physical
row dragging have been verified with Stats’ CPU/RAM icons. Closing the window restores the requested hidden state.
The display picker selects which menu bar to arrange; only the built-in display
has been tested. System icons and dragging between visibility sections are not
supported yet. Ordering uses macOS Command-drag and checks the resulting position.

Selections are saved. **Settings…** includes hide on launch, launch at login,
click/hover/scroll activation, bar position, and smart, timed, or focused-app
rehiding. Turn off **Show hidden icons in a separate bar** to reveal icons in the native menu
bar instead. The default is to hide your saved selection on launch.

Choose **Menu Bar Appearance…** in NookBar’s menu, or open the **Appearance** tab
in Settings, to add a full or split shape, rounded or square ends, shadow, border,
and solid or gradient tint. Dynamic appearance saves separate light/dark styles;
hold **Preview** to try either style without changing the system theme. Changes
save automatically, and **Reset** restores the original menu bar appearance.
Shapes require Screen Recording to sample the wallpaper’s menu bar strip. These
images stay in memory. Appearance pauses while the menu bar hides automatically.
Full/split rendering has been checked on the built-in notched display; other
displays, Spaces, fullscreen, and automatic theme changes still need checks.

The **Shortcuts** tab records shortcuts for showing hidden icons, showing
always-hidden icons, searching, and toggling the separate bar.
Click a shortcut button, then press a combination containing Command, Control,
or Option. Escape cancels recording; Delete clears a shortcut. No global shortcut
is assigned by default. **Search Menu Bar Icons…** searches captured third-party
icons by app name, icon description, or bundle identifier. Use Up/Down and Return
to choose a result.

On macOS 27, the native NookBar icon can disappear during hiding. A clickable **N** control replaces
it in a vacant status-item slot. If no suitable slot is found, NookBar restores all
apps. Clicking blank menu bar space also requests the strip; this interaction
still needs physical validation. Changing selections or refreshing the list first shows
all apps. Quitting or losing permission releases hiding. Sleep/lock releases hiding;
wake/unlock and Space changes resume a requested hidden state. Changes to running
apps reconcile the saved selection. These lifecycle paths still need physical checks.
Some system extras, such as Focus, can also disappear during hiding; Show All
restores them. Clock and Control Center are not selectable in this preview.

The strip uses ScreenCaptureKit to sample the menu bar region while icons are visible.
Captured icon images are retained only in memory. Screen Recording is optional for
hiding/showing, and required for the actual icon strip. Opening a hidden item uses
its Accessibility press action; unsupported items restore the bar instead of
launching the app as a substitute. The original menu opens at its native menu bar
location. Activation checks its original live Accessibility identity, owning
process lifetime, and captured description instead of guessing its ordinal within
the app. Missing or renamed items restore the bar and ask you to refresh. macOS
can reuse identities for same-label replacements, so complete replacement
isolation remains unproven. Captures are rejected if icon positions change while
the screenshot is being taken. A first capture briefly reveals selected icons; cached images are refreshed
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

`./scripts/check.sh` checks the build, signature, plist, read-only diagnostics,
and behavior regressions for rehide decisions, preferences, shortcuts, search,
and arrangement geometry/drop planning. Native movement requires runtime checks.
The native hide/restore check must run from the app bundle with its own permission:

```sh
open -n build/NookBar.app --args --self-test --report "$PWD/.build/self-test.json"
```

Quit other running NookBar copies before testing. This check temporarily hides
NookBar's own icon, releases the assertion, and verifies that its original
Accessibility occurrences return. It also checks other third-party apps remain
present. It writes a JSON report and exits. System extras may briefly hide too.
Accessibility observations do not replace visual checks on each display.

See [the smoke checklist](docs/SMOKE_TEST.md) for lifecycle and UI coverage and
[the Ice parity ledger](docs/ICE_PARITY.md) for the full remaining scope. Native
shortcut registration and launch-at-login controls are implemented; cross-app
shortcut execution and actual login have not yet been verified.

macOS 27 no longer exposes the per-icon windows used by older tools. The proposed
backend uses a private system framework, whose behavior can change. Multiple
icons belonging to one app may share visibility, and system items have limitations.
Read [the investigation](docs/ice-investigation.txt) for observed facts and remaining checks.
Independent item control is still under investigation; see
[the per-icon research](docs/PER_ICON_RESEARCH.md). Developers can reproduce the
reversible divider and native movement experiments by launching the signed app
with `--separator-lab`. The diagnostic tests both fixed and intrinsic widths,
and Swap L and R moves only its own temporary items through native Command-drag.
Quit other NookBar copies first. This diagnostic never changes saved section
assignments, and is not used by normal launches.

## License and research

GPL-3.0-or-later. See `LICENSE` and `THIRD_PARTY_NOTICES.md` for adapted bridge code
and research attribution. There are no third-party runtime dependencies.
