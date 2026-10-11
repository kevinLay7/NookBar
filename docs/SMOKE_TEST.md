# Native smoke checks

Use the actual signed app on macOS 27, not a binary launched through the terminal:
the two can have different Accessibility authorization.

- Self-test: NookBar's own icon disappears, returns after release, and the report passes.
- Discovery: app picker lists actual third-party menu bar apps, excludes NookBar/system services.
- Selection: check an app, hide it, verify its actual icon disappears and other apps remain.
- Reveal: Show All returns the selected icon; repeat several times.
- Persistence: quit/relaunch preserves selection and respects hide-on-launch.
- Quit: quit while hiding and verify every selected icon returns.
- App lifecycle: launch/quit another app while hiding; selected apps stay hidden and new selectable apps are discovered.
- Sleep/lock: release hiding before sleep/lock; verify the requested hidden state resumes after wake/unlock.
- Permission: revoke access while hiding; all apps return, and hiding is unavailable.
- Failure: missing framework, callback failure, timeout, or cancellation restores visibility.
- Displays/Spaces: validate physical icons on each display, including switching Spaces.
- Unexpected exit: terminate the app process while hiding; verify system releases its assertion.
- Settings: change activation, location, and rehide settings; relaunch and verify persistence.
- Shortcuts: record, clear, and test from another app; verify conflict messages and no activation while recording.
- Search: filter by app and icon name; use arrows, Return, and Escape; verify no-match state and separate items from one app.
- Native reveal: disable the hidden bar, reveal selected icons, then verify each rehide strategy while an original menu is open.
- Arrangement: reveal all icons, move a third-party icon in both directions, refresh and relaunch; confirm the native order, then close and verify the original hidden selection. Test physical row dragging, cancellation during movement, disappearing items, display disconnects, and Spaces. Restore the original native order afterward.
- Login: enable launch at login, verify the reported registration state, and test an actual login.
- Sections: move an app to Always Hidden; verify the normal strip excludes it and the separate strip includes it; relaunch and check persistence. Restore the original test selection afterward.

Record observed results separately from implemented cleanup paths. Never count a
successful activation callback alone as proof that physical icons hid or returned.

## Observed on 2026-10-11

macOS 27.0.1 (26A434), Apple Development signed app, refreshed Accessibility entry:

- Actual app-bundle self-test passed: own icon hidden and restored, other third-party
  occurrence counts preserved, two additional toggle cycles passed, immediate
  cancellation restored visibility.
- Native picker discovered nine third-party apps and omitted NookBar/system services.
- Picker Hide Selected reported success; an independent AX snapshot confirmed
  Amphetamine was absent while the other listed third-party apps remained present.
- Build, signature verification, and plist checks passed before this runtime run.

AX occurrence counts include duplicate menu bar trees and are not unique icon counts.
Physical per-display visibility, quit while hiding, sleep/lock, permission revocation,
app lifecycle changes, and unexpected exit remain unvalidated.

## Hidden strip and missing-control investigation

- A longer test found the native NookBar icon disappears after hiding another app,
  even with NookBar explicitly allowed. Earlier short checks missed this.
- Added an N control in the vacant status slot. Both control and strip panels stay
  visible across app deactivation. Screenshot helpers are included in the running-app
  snapshot immediately before hiding, preventing a false app-change restoration.
- CUA screenshot and button action verified N renders and opens a strip with the six
  selected icons: Jump Desktop Connect, Wispr Flow, Tailscale, ChatGPT, BetterDisplay,
  and Amphetamine. The original six selections were restored after investigation.
- Clicking the captured Amphetamine icon opened its real menu. An independent AX
  read confirmed the menu had a 310 by 505 point frame; no session command was run.
- Blank-space physical clicks, right-click settings, menu-close re-hiding, full-screen,
  automatic menu bar hiding, and each display remain unvalidated. Do not call this
  release-ready or treat NSPanel.isVisible as physical per-display proof.
- `--test-control` makes the fallback panel key for targeted CUA inspection. Normal
  launches leave keyboard focus with the user until they open the strip.

## Settings and search batch, 2026-10-11

- Signed build, bundle signature, plist, diagnostics, and behavior regressions pass.
  Behavior checks cover smart/timed rehide decisions, disabled/focused-app modes,
  bounded preference values, shortcut persistence and modifiers, and search matching.
- The installed signed app's fresh self-test passed discovery, icon capture,
  hiding/restoration, preservation of other apps, repeated toggles, and immediate
  cancellation. NookBar's native icon remained available when the test hid TaskWise.
  This is AX evidence for that run, not a guarantee across all selections or displays.
- CUA inspected the native General and Shortcuts tabs. Shortcut recording saved
  Option–Command–N and Option–Command–F; native registration reported no conflict.
  Scoped automation key input is not evidence of system-wide shortcut execution.
- Search displayed eleven captured third-party icons. Filtering by app name found
  Amphetamine behind its symbol-only icon, and Stats produced three separate results.
  A screenshot verified keyboard selection and top-aligned filtered rows after fixes.
- Independent AX snapshots confirmed the six current selected apps were absent
  while NookBar, TaskWise, Amphetamine, and Stats remained present at that instant.
- Attempts to activate Jump Desktop and BetterDisplay through CUA lost access as
  the strip closed. Later snapshots showed hiding active, but no enduring original
  menu was captured. Menu activation and close/re-hiding remain unverified for this batch.
- Hover/scroll, native reveal, launch at login, sleep/lock/Spaces, each display, and
  cross-app shortcuts remain pending physical validation. See `ICE_PARITY.md` for
  unimplemented features; this batch does not establish full Ice parity.

## Three-section batch, 2026-10-11

- CUA moved Chrome from Hidden to Always Hidden. UserDefaults saved it in only the
  always-hidden list; the normal strip showed the other five selected apps.
- The separate Always Hidden strip showed Chrome's captured Gemini icon alone,
  verified through both AX and a screenshot. An installed-app relaunch preserved
  its section assignment.
- With the separate bar disabled through Settings, the app picker's Hidden Icons
  action revealed the normal five apps while Chrome remained absent from an
  independent AX snapshot. Always-Hidden Icons revealed Chrome as well. Toggling
  Always Hidden off hid only Chrome; toggling the normal section off hid all six.
- Restored Chrome to Hidden and enabled the separate bar again. Original selected
  app memberships were preserved; no new shortcuts or login registration were set.
- Four shortcut recorders are visible: hidden, search, always-hidden, and bar mode.
  Actual cross-app execution remains pending human input, as in the previous batch.
- Regression checks cover legacy selection migration, disjoint membership,
  persistence, system/control exclusions, and Select All/Clear Selection behavior.
  Physical Option-click, automatic rehide, independent icons from one app, and
  multi-display behavior remain unverified.

## Per-icon backend research, 2026-10-11

- The signed app's developer-only divider diagnostic expanded a temporary
  empty/disabled status item to a requested 10,000 points. A settled menu-region
  image showed the other icons remained visible; the prototype did not collapse
  icons to its left.
- Contracted and removed all diagnostic items through CUA. A fresh independent
  snapshot showed one NookBar item and all third-party app occurrences restored.
- Build, signature, plist, diagnostics, and behavior checks pass. This batch
  adds a reproducible diagnostic, not completed per-icon layout or hiding.
- See `PER_ICON_RESEARCH.md` for bounded conclusions and remaining native API work.

## Native gesture and utility interface batch, 2026-10-11

- In the signed installed app's separator lab, Swap L and R moved its owned L
  icon left of R and then right of R. Independent AX reads and settled captured
  menu regions agreed on both orders. The moved order also survived relaunch.
- Runnable check: launch `--separator-lab`, Read Current State after items settle,
  swap twice, and inspect each settled capture. Quit/relaunch and compare the
  order, then close the lab and confirm its temporary items are removed. Only
  diagnostic items are eligible for this control.
- Expanding a transparent 10,000-point image in variable-length mode also failed
  to hide other icons. Contracting removed the image and restored the divider.
- The private utility ping was denied. A correlated MenuBarAgent log identified
  its missing Apple-private entitlement. This route cannot support the ordinary
  unentitled app; see PER_ICON_RESEARCH.md for evidence and scope.
- Cancellation and termination have immediate gesture release in code; real
  interruption coverage, foreign/system items, each display, and independent
  hiding remain pending. This batch does not establish full Ice parity.

## Public arrangement batch, 2026-10-11

- The signed installed app’s Arrange Icons window lists live menu bar items with
  captured icon images and a display picker. It restores all apps while open.
- CUA selected Stats CPU and used Move Right to place it after RAM. A fresh,
  independent AX read confirmed the changed native positions. Relaunching NookBar
  preserved this order while the Stats process remained running.
- Move Left returned CPU before RAM, restoring the original Disk, CPU, RAM order.
  This run used live AX identity and a system-wide hit test to confirm both endpoints
  before posting the native Command-drag gesture. The UI reported success and a
  separate AX read confirmed the order.
- Closing arrangement, then dismissing the hidden strip, left the original six
  selected apps absent from the menu bar AX tree. UserDefaults memberships remained
  unchanged; NookBar, Stats, TaskWise, and Amphetamine were present.
- Build/signature/plist/diagnostics and arrangement geometry/drop planning checks
  passed. Native drag delegate selectors are available; that does not prove physical
  row dragging. Scoped CUA drags did not establish a row-drop event. A human test
  remains pending, as do interruption, system items, app restarts, and other displays.
- The separator diagnostic now shares the movement engine. Its prior owned-item
  evidence predates this refactor; repeat that GUI check before counting it as
  validation of the shared route. Independent per-icon hiding remains unresolved.

## Item identity and physical drag follow-up, 2026-10-11

- The user reported that dragging Stats CPU above RAM changes the native menu bar
  to match. This is physical evidence for that pair; system items, cross-section
  dragging, interruption, and other displays remain pending.
- Captured icons now retain their live AX entries, and activation resolves the
  original item rather than its ordinal in the owning app. Matching also requires
  the same process launch date and description. A missing or renamed item restores
  visibility and clears the cached strip.
- Capture now checks that every item retains its identity and frame after the
  screenshot completes, rejecting a strip assembled while its layout changed.
- The signed runtime identity diagnostic verified own and foreign hide/reveal
  matching, rejected a removed temporary item while preserving the remaining
  NookBar item, and discovered a limitation: a same-label replacement can reuse
  its old AX identity. The report records this separately as
  `sameLabelReplacementRejected: false` and `identityIsolationProven: false`.
  A passing baseline self-test must not be read as complete identity isolation.
- Read-only subscription probes returned `kAXErrorNotificationUnsupported`
  (-25207) for destroyed, layout-changed, and created notifications on the NookBar
  and Stats menu items. No notification-based invalidation is claimed.

- The final signed report also passed renamed-item rejection, icon capture with
  frame validation, foreign TaskWise hide/reveal identity checks, repeated toggles,
  and cancellation restoration. The installed app was automatically relaunched
  normally after the diagnostic; an independent snapshot showed the six original
  selected apps hidden and the other third-party apps present.
- CUA opened the hidden strip and then Search. All eleven third-party icons were
  listed, including separate Stats Disk/CPU/RAM items. This validates display and
  capture for that run; original-menu activation after this change still needs a
  separate check. User interaction interrupted the attempted search selection.

## Appearance follow-up, 2026-10-11

- Built and signed the updated app; diagnostics and appearance persistence,
  invalid-value normalization, split/fallback geometry, and independent end-cap
  path checks passed. These are logic checks, not display coverage.
- CUA selected Full and Split shapes on the built-in notched display. Independent
  ScreenCaptureKit menu-region captures showed rounded regions, gradient tint,
  border, shadow, and a wallpaper gap between application menus and status icons.
  Native icons remained visible. A separate capture of the source wallpaper strip
  contained no menu icons.
- CUA held Light Preview for three seconds with a black solid tint while the current
  dark profile had no tint. Independent menu-region pixel samples changed during
  the hold (roughly RGB .227/.248/.306 to .182/.204/.251) and returned afterward.
- Relaunch preserved dynamic profiles, solid light tint, split shape, and cap
  selection. The updated gradient editor displayed three readable percentage
  fields without wrapped labels; adding, editing 50% to 65%, and removing a stop
  updated the native controls. Removing below two stops was disabled.
- Reset returned Tint/Shape to None and Shadow/Border to off, with the status
  “Appearance follows macOS.” The installed app was then relaunched normally. An independent AX snapshot
  showed the six original selected apps absent, with NookBar, Stats, TaskWise,
  and Amphetamine present; saved section membership was unchanged.
- Pending: physical icon interaction with the appearance overlay enabled; other
  displays; all four cap combinations; automatic system theme transitions;
  animated wallpapers; Spaces/fullscreen; sleep/lock; permission revocation;
  auto-hide pause/resume; and fallback-control geometry when selected apps hide.
