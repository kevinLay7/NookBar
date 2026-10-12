# Application-menu ownership investigation

Environment: macOS 27.0.1 (26A434), October 11, 2026.

Ice's application-menu feature activates its process with a regular activation
policy and hides its main-menu items. NookBar still needs automatic space-aware
menu replacement and restoration. This investigation did not produce a working
replacement, so its experimental controls were removed from the installed app.

## Controlled experiment

An experimental Advanced button requested regular activation, assigned an
AppKit main menu, and activated NookBar. It saved the old menu/policy and tracked
the previously focused external application. A delayed check required both
NookBar activation and actual menu bar ownership; failure restored the saved
state. Switching applications also restored the state.

Variants tested through CUA on the signed installed app included:

- Empty menu, hidden application-menu root, and visible application-menu root.
- Assigning the menu before changing activation policy.
- NSApplication activation and NSRunningApplication activation from the prior app.
- LSUIElement enabled and disabled, retaining accessory policy during ordinary use.
- Registering a main menu and regular policy before entering the app run loop.
- Deactivating before requesting activation again.

The button immediately changed to Restore, but that was insufficient evidence.
A diagnostic recorded `NSApp.isActive == true`, regular policy, and NookBar as
frontmost while `NSWorkspace.menuBarOwningApplication` remained Hopper.
Independent metadata still identified Hopper as menu bar owner, with its full
menu titles. The settled ownership check restored the button to Hide. Extending
the check to three seconds did not establish successful ownership in these tests.

This establishes failure of these variants under this test setup. It does not
prove that macOS disallows application-menu replacement, or that every physical
activation path behaves identically. It does not validate automatic room
calculation, Dock behavior, or restoration after a successful replacement.

The experimental source was retained outside the public app for follow-up.
The installed app was rebuilt from the validated source with LSUIElement enabled;
its existing build, signature, diagnostics, and behavior checks passed. Existing
app sections and user settings were preserved.

## Next checks

1. Compare Ice's initial menu registration and activation lifecycle with the
   AppKit implementation, including the menu bar agent's ownership transition.
2. Verify a successful replacement with actual rendered menu titles and native
   ownership before adding a public control or automatic behavior.
3. Verify explicit restore, application switching, quit, failure, Dock visibility,
   fullscreen, and each display, then add automatic room management.

## Reference behavior required for parity

The checked-in Ice source at `Ice/MenuBar/MenuBarManager.swift:149–220`
subscribes to section-control state changes. Automatic replacement is enabled
only when its advanced setting is on, native menu bar reveal is selected, the
system menu bar is visible, the active Space is not fullscreen, and Settings is
closed. It obtains the application-menu frame on the display, excludes the
still-hidden section by its physical boundary, and compares the leftmost shown
item's minimum x coordinate with the application-menu frame's maximum x.
Overlap triggers replacement; collapsing all sections restores the menus.

The same source at lines 299–327 also exposes an explicit toggle independently
of that automatic room calculation. `AppState.swift:244–263` sets regular policy
and calls `NSRunningApplication.current.activate(from: frontmost)` to replace,
then sets accessory policy and calls `NSApp.deactivate()` to restore. These are
source requirements, not evidence that those calls succeed on macOS 27.

NookBar must implement both the explicit action/shortcut and the conditional
automatic behavior once ownership is demonstrated. It must not activate merely
because captured-strip mode opens, or treat a frontmost-process change as proof
that the visible application menus were replaced. A native test must record the
menu bar owner and rendered titles before, during, and after replacement.
