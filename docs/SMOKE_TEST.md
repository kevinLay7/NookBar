# Native smoke checks

Use the actual signed app on macOS 27, not a binary launched through the terminal:
the two can have different Accessibility authorization.

- Self-test: NookBar's own icon disappears, returns after release, and the report passes.
- Discovery: app picker lists actual third-party menu bar apps, excludes NookBar/system services.
- Selection: check an app, hide it, verify its actual icon disappears and other apps remain.
- Reveal: Show All returns the selected icon; repeat several times.
- Persistence: quit/relaunch preserves selection and starts with apps visible.
- Quit: quit while hiding and verify every selected icon returns.
- App lifecycle: launch/quit another app while hiding; the bar returns to visible.
- Sleep/lock: release hiding before sleep/lock; verify visibility after wake/unlock.
- Permission: revoke access while hiding; all apps return, and hiding is unavailable.
- Failure: missing framework, callback failure, timeout, or cancellation restores visibility.
- Displays/Spaces: validate physical icons on each display, including switching Spaces.
- Unexpected exit: terminate the app process while hiding; verify system releases its assertion.

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
