# Menu bar appearance

## References and decisions

Primary behavior reference: Ice 0.11.13-dev.2, commit
`da2dd23cdd70d287445cbe3dbb5628a4c3ad8c7e`. Its appearance settings, configuration,
and MenuBarOverlayPanel establish the shape, independent end caps, notch inset,
shadow, border, tint, and dynamic light/dark profile requirements. Static source
is evidence of intended behavior, not proof that installed Ice works on macOS 27.

NookBar’s existing native Settings window supplies the navigation and platform
controls. Refero research into Desktop.fm supported compact system typography,
neutral surfaces, and readable control spacing; Raycast supplied only restrained
monochrome layering. Native macOS controls remain the visual authority. No
third-party artwork or UI assets are included.

## Rendering contract

A transparent, nonactivating, mouse-ignoring panel follows each visible native
menu bar. Its height includes five points beneath the bar for a shadow. The real
menu items remain in the system menu bar; the renderer does not reproduce their
images or replace their actions.

Full shapes surround the complete bar. Split shapes obtain the current
application-menu extent through Accessibility and the status-item extent through
the native bridge. If extents are missing or overlap, the renderer falls back to
one full shape with the outer caps. Geometry is recalculated on app activation
and a two-second timer.

For shaped bars, ScreenCaptureKit captures only the wallpaper window’s strip
behind the menu bar. It draws outside the shape, preserving the native bar inside.
The wallpaper strip stays in memory and refreshes at most every five seconds.
Tint uses Ice’s 20 percent opacity; shape borders are clipped inside the path.
No-shape borders draw along the bottom edge. Each shape edge can be square or round.

Settings persist in the app’s UserDefaults. Static and dynamic profiles are
independent. Holding Preview temporarily selects a light/dark profile; release,
window close, or suspension clears it. Reset removes the appearance effects.
Invalid stored values are normalized; malformed configuration loads inert defaults.

The renderer removes overlays on stop, sleep/lock, or invalidated display/Space/
theme state. Full/Split shapes require Screen Recording. Missing permissions or
wallpaper sources leave the original bar visible with an actionable status.
Appearance pauses when the system menu bar hides automatically.

## Evidence and limits

On macOS 27.0.1, the built-in notched display reports a 2056 by 39 point native
menu bar and a separate wallpaper-agent window. Runtime captures demonstrated
full and split geometry, gradient tint, border, and shadow. A source-strip capture
contained wallpaper alone. Timed native UI preview plus independent pixel sampling
proved the temporary light tint appeared and disappeared on release. Native UI
checks covered gradient stop creation/edit/removal, minimum stop count, persistence
across relaunch, and Reset.

These captures are local QA artifacts and are not committed. See SMOKE_TEST.md
for observed cases. Other displays, fullscreen/Spaces, real system theme changes,
animated wallpapers, auto-hide resume, permission revocation, lifecycle transitions,
and appearance combined with the fallback control remain unverified. Appearance
is implemented but full Ice parity is still an active goal.
